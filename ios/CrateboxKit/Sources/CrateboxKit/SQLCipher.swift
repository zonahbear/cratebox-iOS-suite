// SQLCipher 4 page codec (default settings: 4096-byte pages, PBKDF2-HMAC-SHA512 with 256 000 rounds,
// AES-256-CBC, a 16-byte IV and a 64-byte HMAC-SHA512 in each page's reserved 80 bytes).
//
// rekordbox's OneLibrary database on a USB stick (PIONEER/rekordbox/exportLibrary.db) is a SQLite file
// encrypted this way, with one key for every stick (pyrekordbox, MIT licence, documents it). iOS ships plain
// SQLite only, so Cratebox decrypts the whole file to a temporary plain SQLite database, reads (or edits) that,
// and encrypts it again page by page. Checked against a real rekordbox database: decrypting and re-encrypting
// with the same salt and IVs gives back the identical file (see tools/sqlcipher_ref.py and the tests).
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public enum SQLCipherError: Error, CustomStringConvertible, Equatable {
    case tooSmall, badHMAC(page: Int), crypto(Int32), unavailable, notSQLite
    public var description: String {
        switch self {
        case .tooSmall: return "the database file is too small to be SQLCipher"
        case .badHMAC(let p): return "page \(p) failed its integrity check (wrong key, or the file is damaged)"
        case .crypto(let c): return "encryption error \(c)"
        case .unavailable: return "encryption isn't available on this platform"
        case .notSQLite: return "the decrypted data isn't a SQLite database"
        }
    }
}

public struct SQLCipherCodec {
    public static let pageSize = 4096, reserve = 80, saltLen = 16, ivLen = 16, hmacLen = 64
    static let header: [UInt8] = Array("SQLite format 3\u{0}".utf8)

    public let key: [UInt8], hmacKey: [UInt8], salt: [UInt8]

    /// the OneLibrary key (kept masked so it doesn't sit in the binary as plain text)
    public static var oneLibraryPassphrase: String {
        let masked: [UInt8] = [0x31, 0x4a, 0x06, 0x10, 0x01, 0x0c, 0x1d, 0x4c, 0x4b, 0x6d, 0x67, 0x75, 0x18, 0x1c, 0x1f, 0x22, 0x00, 0x57, 0x17, 0x14, 0x18, 0x0d, 0x13, 0x4b, 0x65, 0x36, 0x2e, 0x16, 0x5e, 0x56, 0x37, 0x1f,
                               0x03, 0x47, 0x11, 0x10, 0x0d, 0x1a, 0x58, 0x6d, 0x63, 0x77, 0x4a, 0x42, 0x18, 0x77, 0x04, 0x04, 0x0e, 0x53, 0x56, 0x06, 0x4d, 0x4f, 0x6d, 0x35, 0x2c, 0x52, 0x5e, 0x5d, 0x3a, 0x03, 0x0d, 0x07]
        let mask = Array("Cratebox USB //".utf8)
        return String(decoding: masked.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }, as: UTF8.self)
    }

    /// keys for a file, from its passphrase and the salt in its first 16 bytes (slow: 256 000 rounds)
    public init(passphrase: String, salt: [UInt8]) throws {
        self.salt = salt
        key = try SQLCipherCodec.pbkdf2(Array(passphrase.utf8), salt, rounds: 256_000, length: 32)
        hmacKey = try SQLCipherCodec.pbkdf2(key, salt.map { $0 ^ 0x3a }, rounds: 2, length: 32)
    }

    public static func isPlainSQLite(_ b: [UInt8]) -> Bool { b.count >= 16 && Array(b[0..<16]) == header }

    /// the encrypted file → a plain SQLite database (same size: each page's reserved bytes come back as zeros,
    /// which SQLite ignores since the header still says 80 reserved bytes)
    public func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        let P = SQLCipherCodec.pageSize, R = SQLCipherCodec.reserve
        guard data.count >= P, data.count % P == 0 else { throw SQLCipherError.tooSmall }
        var out = [UInt8](repeating: 0, count: data.count)
        for p in 0..<(data.count / P) {
            let o = p * P, start = p == 0 ? SQLCipherCodec.saltLen : 0
            let body = Array(data[(o + start)..<(o + P - R + SQLCipherCodec.ivLen)])
            let mac = Array(data[(o + P - R + SQLCipherCodec.ivLen)..<(o + P)])
            let calc = try SQLCipherCodec.hmac(hmacKey, body + SQLCipherCodec.le32(UInt32(p + 1)))
            guard calc == mac else { throw SQLCipherError.badHMAC(page: p + 1) }
            let iv = Array(data[(o + P - R)..<(o + P - R + SQLCipherCodec.ivLen)])
            let plain = try SQLCipherCodec.aes(encrypt: false, key, iv, Array(data[(o + start)..<(o + P - R)]))
            if p == 0 { for i in 0..<16 { out[i] = SQLCipherCodec.header[i] } }
            for (i, v) in plain.enumerated() { out[o + start + i] = v }
        }
        guard SQLCipherCodec.isPlainSQLite(out) else { throw SQLCipherError.notSQLite }
        return out
    }

    /// a plain SQLite database (with 80 reserved bytes per page) → the encrypted file. `ivs` only for tests
    /// (to compare against a known file); normally every page gets a fresh random IV.
    public func encrypt(_ plain: [UInt8], ivs: [[UInt8]]? = nil) throws -> [UInt8] {
        let P = SQLCipherCodec.pageSize, R = SQLCipherCodec.reserve
        guard plain.count >= P, plain.count % P == 0 else { throw SQLCipherError.tooSmall }
        guard plain[20] == UInt8(R) else { throw SQLCipherError.notSQLite }          // the header's reserved bytes
        var out = [UInt8]()
        out.reserveCapacity(plain.count)
        for p in 0..<(plain.count / P) {
            let o = p * P, start = p == 0 ? SQLCipherCodec.saltLen : 0
            let iv = ivs?[p] ?? SQLCipherCodec.random(SQLCipherCodec.ivLen)
            let enc = try SQLCipherCodec.aes(encrypt: true, key, iv, Array(plain[(o + start)..<(o + P - R)]))
            let body = enc + iv
            let mac = try SQLCipherCodec.hmac(hmacKey, body + SQLCipherCodec.le32(UInt32(p + 1)))
            if p == 0 { out += salt }
            out += body + mac
        }
        return out
    }

    // ---- primitives ----
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    static func random(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
    #if canImport(CommonCrypto)
    static func pbkdf2(_ pass: [UInt8], _ salt: [UInt8], rounds: Int, length: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let st = pass.withUnsafeBufferPointer { pp in
            pp.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pass.count) { pc in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pc, pass.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(rounds), &out, length)
            }
        }
        if st != kCCSuccess { throw SQLCipherError.crypto(st) }
        return out
    }
    static func hmac(_ key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), key, key.count, data, data.count, &out)
        return out
    }
    static func aes(encrypt: Bool, _ key: [UInt8], _ iv: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        // no padding: every page's encrypted part is a whole number of AES blocks
        let st = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                         key, key.count, iv, input, input.count, &out, out.count, &moved)
        if st != kCCSuccess { throw SQLCipherError.crypto(st) }
        return Array(out[0..<moved])
    }
    #else
    static func pbkdf2(_ pass: [UInt8], _ salt: [UInt8], rounds: Int, length: Int) throws -> [UInt8] { throw SQLCipherError.unavailable }
    static func hmac(_ key: [UInt8], _ data: [UInt8]) throws -> [UInt8] { throw SQLCipherError.unavailable }
    static func aes(encrypt: Bool, _ key: [UInt8], _ iv: [UInt8], _ input: [UInt8]) throws -> [UInt8] { throw SQLCipherError.unavailable }
    #endif
}
