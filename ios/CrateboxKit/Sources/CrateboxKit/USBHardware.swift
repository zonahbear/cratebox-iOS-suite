// What each player can read off a USB stick: which library (Device Library = export.pdb, OneLibrary =
// exportLibrary.db), which audio formats up to which sample rate / bit depth, which file systems, how many
// hot cues it shows. From AlphaTheta / Pioneer DJ manuals and support pages, as of October 2026. Where a
// detail wasn't confirmed it errs on the strict side (and `confirmed` is false). "Unknown player" is the
// strictest of all: what every listed player can read.
import Foundation

public enum AudioCodec: String, Codable, CaseIterable { case mp3, aac, wav, aiff, flac, alac, other }

public struct PlayerProfile: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let family: String
    public let readsDeviceLibrary: Bool
    public let readsOneLibrary: Bool
    public let codecs: Set<AudioCodec>
    public let maxSampleRate: Int            // Hz, for uncompressed / lossless files
    public let maxBitDepth: Int
    public let fileSystems: Set<String>      // "FAT32", "exFAT", "HFS+", "FAT16"
    public let hotCues: Int                  // hot cues it shows (A, B, C… )
    public let confirmed: Bool
}

public enum PlayerProfiles {
    static let all6: Set<AudioCodec> = [.mp3, .aac, .wav, .aiff, .flac, .alac]
    static let basic4: Set<AudioCodec> = [.mp3, .aac, .wav, .aiff]
    public static let all: [PlayerProfile] = [
        PlayerProfile(id: "cdj3000x", name: "CDJ-3000X", family: "CDJ", readsDeviceLibrary: false, readsOneLibrary: true, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT", "HFS+"], hotCues: 8, confirmed: true),
        PlayerProfile(id: "cdj3000", name: "CDJ-3000", family: "CDJ", readsDeviceLibrary: true, readsOneLibrary: true, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT", "HFS+"], hotCues: 8, confirmed: true),
        PlayerProfile(id: "cdj2000nxs2", name: "CDJ-2000NXS2", family: "CDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "HFS+"], hotCues: 8, confirmed: true),
        PlayerProfile(id: "cdj2000nxs", name: "CDJ-2000NXS", family: "CDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: basic4, maxSampleRate: 48000, maxBitDepth: 24, fileSystems: ["FAT32", "HFS+"], hotCues: 3, confirmed: false),
        PlayerProfile(id: "cdj900nxs", name: "CDJ-900NXS", family: "CDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: basic4, maxSampleRate: 48000, maxBitDepth: 24, fileSystems: ["FAT32", "HFS+"], hotCues: 3, confirmed: false),
        PlayerProfile(id: "xdj1000mk2", name: "XDJ-1000MK2", family: "XDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "HFS+"], hotCues: 8, confirmed: false),
        PlayerProfile(id: "xdj700", name: "XDJ-700", family: "XDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: basic4, maxSampleRate: 48000, maxBitDepth: 24, fileSystems: ["FAT32", "HFS+"], hotCues: 4, confirmed: false),
        PlayerProfile(id: "xdjxz", name: "XDJ-XZ", family: "XDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT", "HFS+"], hotCues: 8, confirmed: false),
        PlayerProfile(id: "xdjrx3", name: "XDJ-RX3", family: "XDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT", "HFS+"], hotCues: 8, confirmed: false),
        PlayerProfile(id: "xdjrx2", name: "XDJ-RX2", family: "XDJ", readsDeviceLibrary: true, readsOneLibrary: false, codecs: all6, maxSampleRate: 48000, maxBitDepth: 24, fileSystems: ["FAT32", "HFS+"], hotCues: 8, confirmed: false),
        PlayerProfile(id: "xdjaz", name: "XDJ-AZ", family: "XDJ", readsDeviceLibrary: false, readsOneLibrary: true, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT"], hotCues: 8, confirmed: true),
        PlayerProfile(id: "opusquad", name: "OPUS-QUAD", family: "All-in-one", readsDeviceLibrary: false, readsOneLibrary: true, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT"], hotCues: 8, confirmed: true),
        PlayerProfile(id: "omnisduo", name: "OMNIS-DUO", family: "All-in-one", readsDeviceLibrary: false, readsOneLibrary: true, codecs: all6, maxSampleRate: 96000, maxBitDepth: 24, fileSystems: ["FAT32", "exFAT"], hotCues: 8, confirmed: true),
    ]
    /// a player we know nothing about: needs both libraries and what every player reads
    public static let unknown = PlayerProfile(id: "unknown", name: "Unknown player", family: "?", readsDeviceLibrary: true, readsOneLibrary: true,
                                              codecs: basic4, maxSampleRate: 48000, maxBitDepth: 16, fileSystems: ["FAT32"], hotCues: 3, confirmed: false)
    public static func byId(_ id: String) -> PlayerProfile? { id == "unknown" ? unknown : all.first { $0.id == id } }

    /// what a mix of players needs, all at once
    public struct Requirement: Equatable {
        public var deviceLibrary = false, oneLibrary = false
        public var codecs: Set<AudioCodec> = Set(AudioCodec.allCases)
        public var maxSampleRate = Int.max, maxBitDepth = Int.max
        public var fileSystems: Set<String>? = nil
        public var hotCues = 8
        public var players: [PlayerProfile] = []
        public var unknownIncluded: Bool { players.contains { $0.id == "unknown" } }
    }
    public static func requirement(_ ids: [String]) -> Requirement {
        var r = Requirement()
        let ps = ids.compactMap(byId)
        r.players = ps.isEmpty ? [unknown] : ps
        for p in r.players {
            // "unknown" covers both libraries: with an unknown player, either may be the one it reads
            if p.readsDeviceLibrary && !p.readsOneLibrary || p.id == "unknown" { r.deviceLibrary = true }
            if p.readsOneLibrary && !p.readsDeviceLibrary || p.id == "unknown" { r.oneLibrary = true }
            r.codecs.formIntersection(p.codecs)
            r.maxSampleRate = min(r.maxSampleRate, p.maxSampleRate); r.maxBitDepth = min(r.maxBitDepth, p.maxBitDepth)
            r.fileSystems = r.fileSystems.map { $0.intersection(p.fileSystems) } ?? p.fileSystems
            r.hotCues = min(r.hotCues, p.hotCues)
        }
        // a player that reads both (CDJ-3000) is happy with either; it adds no library need of its own
        // unless it's the only kind present
        if !r.deviceLibrary && !r.oneLibrary { r.deviceLibrary = true }
        return r
    }
    public static func codec(ext: String) -> AudioCodec {
        switch ext.lowercased() {
        case "mp3": return .mp3
        case "m4a", "aac", "mp4": return .aac            // could be ALAC inside; the header check tells
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "flac": return .flac
        case "alac": return .alac
        default: return .other
        }
    }
}

/// What a file's own header says (read from its first bytes, without decoding)
public struct AudioFacts: Equatable {
    public var codec: AudioCodec
    public var sampleRate: Int, bitDepth: Int, channels: Int
    public var floatingPoint = false
    public init(codec: AudioCodec, sampleRate: Int = 0, bitDepth: Int = 0, channels: Int = 0, floatingPoint: Bool = false) {
        self.codec = codec; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.channels = channels; self.floatingPoint = floatingPoint
    }
}

public enum AudioSniffer {
    public static func sniff(_ b: [UInt8]) -> AudioFacts? {
        func be32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }
        func le32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : 0 }
        func le16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func be16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        func tag(_ o: Int) -> String { o + 4 <= b.count ? String(decoding: b[o..<(o + 4)], as: UTF8.self) : "" }
        guard b.count >= 12 else { return nil }
        // WAV: RIFF ... WAVE, chunks until "fmt "
        if tag(0) == "RIFF" || tag(0) == "RF64", tag(8) == "WAVE" {
            var o = 12
            while o + 8 <= b.count {
                let id = tag(o), len = le32(o + 4)
                if id == "fmt " {
                    var fmt = le16(o + 8)
                    if fmt == 0xFFFE && len >= 40 { fmt = le16(o + 8 + 24) }             // extensible: the sub-format GUID's first two bytes
                    return AudioFacts(codec: .wav, sampleRate: le32(o + 12), bitDepth: le16(o + 22), channels: le16(o + 10), floatingPoint: fmt == 3)
                }
                o += 8 + len + (len & 1)
            }
            return AudioFacts(codec: .wav)
        }
        // AIFF / AIFC: FORM ... AIFF, COMM chunk (sample rate as an 80-bit float)
        if tag(0) == "FORM", tag(8) == "AIFF" || tag(8) == "AIFC" {
            var o = 12
            while o + 8 <= b.count {
                let id = tag(o), len = be32(o + 4)
                if id == "COMM" && o + 26 <= b.count {
                    let exp = be16(o + 16) & 0x7fff
                    let mant = UInt64(be32(o + 18)) << 32 | UInt64(be32(o + 22))
                    let rate = exp == 0 ? 0 : Int(Double(mant) * pow(2, Double(exp - 16383 - 63)))
                    let comp = tag(8) == "AIFC" && o + 30 <= b.count ? tag(o + 26) : "NONE"
                    return AudioFacts(codec: .aiff, sampleRate: rate, bitDepth: be16(o + 14), channels: be16(o + 8), floatingPoint: comp == "fl32" || comp == "fl64")
                }
                o += 8 + len + (len & 1)
            }
            return AudioFacts(codec: .aiff)
        }
        // FLAC: "fLaC", then STREAMINFO
        if tag(0) == "fLaC", b.count >= 8 + 18 {
            let s = 8 + 10
            let rate = Int(b[s]) << 12 | Int(b[s + 1]) << 4 | Int(b[s + 2]) >> 4
            let ch = (Int(b[s + 2]) >> 1 & 0x7) + 1
            let bps = ((Int(b[s + 2]) & 1) << 4 | Int(b[s + 3]) >> 4) + 1
            return AudioFacts(codec: .flac, sampleRate: rate, bitDepth: bps, channels: ch)
        }
        // MP4 / M4A: an ALAC or AAC sample entry somewhere in the first bytes (moov first in most files)
        if tag(4) == "ftyp" {
            func find(_ t: String) -> Int? {
                let n = Array(t.utf8)
                guard b.count >= n.count else { return nil }
                for i in 0...(b.count - n.count) where b[i] == n[0] && b[i + 1] == n[1] && b[i + 2] == n[2] && b[i + 3] == n[3] { return i }
                return nil
            }
            // sample entry: size(4) 'alac'/'mp4a'(4) reserved(6) dataRef(2) version(2) rev(2) vendor(4) channels(2) bits(2) comp(2) packet(2) rate(4, 16.16)
            if let i = find("alac") ?? find("mp4a") {
                let isAlac = tag(i) == "alac"
                let e = i + 4
                return AudioFacts(codec: isAlac ? .alac : .aac, sampleRate: be32(e + 24) >> 16, bitDepth: isAlac ? be16(e + 18) : 0, channels: be16(e + 16))
            }
            return AudioFacts(codec: .aac)
        }
        // MP3: skip an ID3v2 tag, then a frame header
        var o = 0
        if tag(0).hasPrefix("ID3"), b.count >= 10 {
            o = 10 + (Int(b[6] & 0x7f) << 21 | Int(b[7] & 0x7f) << 14 | Int(b[8] & 0x7f) << 7 | Int(b[9] & 0x7f))
        }
        while o + 4 <= b.count {
            if b[o] == 0xff && b[o + 1] & 0xe0 == 0xe0 {
                let ver = Int(b[o + 1] >> 3 & 3), layer = Int(b[o + 1] >> 1 & 3), ri = Int(b[o + 2] >> 2 & 3)
                if layer == 1 && ri != 3 && ver != 1 {                 // layer III
                    let base = [44100, 48000, 32000][ri]
                    let rate = ver == 3 ? base : ver == 2 ? base / 2 : base / 4
                    return AudioFacts(codec: .mp3, sampleRate: rate, bitDepth: 16, channels: (b[o + 3] >> 6) == 3 ? 1 : 2)
                }
            }
            o += 1
            if o > 65536 { break }
        }
        return nil
    }
}
