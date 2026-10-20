// rekordbox's OneLibrary (formerly Device Library Plus) on a USB stick: PIONEER/rekordbox/exportLibrary.db,
// an SQLCipher-encrypted SQLite database. Newer players (CDJ-3000X, OPUS-QUAD, XDJ-AZ, OMNIS-DUO, …) read it
// instead of export.pdb. Tables and columns follow pyrekordbox's onelibrary models (MIT licence).
//
// Reading is complete for what Cratebox USB needs (tracks, playlists, cues). Writing playlists works on a
// decrypted copy and is checked by reading it back, but has NOT been proven on hardware yet: callers keep it
// locked (see USBWriteGate) until it has been.
import Foundation

public struct OLTrack: Equatable, Codable {
    public var id: Int64
    public var title: String, artist: String, album: String, genre: String, label: String, key: String, comment: String
    public var bpm: Double, durationMs: Int64
    public var path: String, fileName: String, fileSize: Int64, fileType: Int64
    public var bitrate: Int64, bitDepth: Int64, sampleRate: Int64
    public var anlzPath: String, rating: Int64, color: Int64
}
public struct OLPlaylist: Equatable, Codable {
    public var id: Int64, parent: Int64, seq: Int64
    public var folder: Bool, name: String
    public var tracks: [Int64]
    public var attribute: Int64
    public init(id: Int64, parent: Int64, seq: Int64, folder: Bool, name: String, tracks: [Int64], attribute: Int64) {
        self.id = id; self.parent = parent; self.seq = seq; self.folder = folder; self.name = name; self.tracks = tracks; self.attribute = attribute
    }
}
public struct OLCue: Equatable, Codable {
    public var id: Int64, track: Int64, kind: Int64
    public var inMs: Double, outMs: Double?
    public var comment: String, color: Int64
}

public struct OneLibraryDatabase: Equatable {
    public var tracks: [OLTrack] = []
    public var playlists: [OLPlaylist] = []          // tree order: by parent, then sequence
    public var cues: [OLCue] = []
    public var deviceName = ""
    public var dbVersion: Int64 = 0
    public var integrity: [String] = []              // SQLite's integrity_check ("ok" when fine)
}

public enum OneLibraryError: Error, CustomStringConvertible {
    case missingTable(String), readBack(String), cantWrite(String)
    public var description: String {
        switch self {
        case .missingTable(let t): return "OneLibrary: no \(t) table (not a OneLibrary database, or a newer layout)"
        case .readBack(let s): return "OneLibrary: \(s)"
        case .cantWrite(let s): return "OneLibrary: \(s)"
        }
    }
}

public enum OneLibrary {
    /// decrypt (or take as is, for a plain test database) and open a temporary copy
    public static func openCopy(_ data: [UInt8], passphrase: String = SQLCipherCodec.oneLibraryPassphrase, tempDir: URL = FileManager.default.temporaryDirectory) throws -> (db: SQLiteDB, codec: SQLCipherCodec?, url: URL) {
        var plain = data, codec: SQLCipherCodec?
        if !SQLCipherCodec.isPlainSQLite(data) {
            guard data.count >= 16 else { throw SQLCipherError.tooSmall }
            let c = try SQLCipherCodec(passphrase: passphrase, salt: Array(data[0..<16]))
            plain = try c.decrypt(data); codec = c
        }
        let url = tempDir.appendingPathComponent("cratebox-ol-\(UUID().uuidString).sqlite")
        try Data(plain).write(to: url)
        return (try SQLiteDB(path: url.path), codec, url)
    }

    public static func read(_ data: [UInt8], passphrase: String = SQLCipherCodec.oneLibraryPassphrase, integrity: Bool = true) throws -> OneLibraryDatabase {
        let (db, _, url) = try openCopy(data, passphrase: passphrase)
        defer { db.close(); try? FileManager.default.removeItem(at: url) }
        return try read(db, integrity: integrity)
    }

    static func names(_ db: SQLiteDB, _ table: String, _ idCol: String, _ have: Set<String>) throws -> [Int64: String] {
        guard have.contains(table) else { return [:] }
        var m = [Int64: String]()
        for r in try db.query("SELECT \(idCol) AS i, name AS n FROM \"\(table)\"") { if let i = r["i"]?.int { m[i] = r["n"]?.string ?? "" } }
        return m
    }

    public static func read(_ db: SQLiteDB, integrity: Bool = true) throws -> OneLibraryDatabase {
        let have = try db.tables()
        for t in ["content", "playlist", "playlist_content"] where !have.contains(t) { throw OneLibraryError.missingTable(t) }
        var out = OneLibraryDatabase()
        let artists = try names(db, "artist", "artist_id", have), albums = try names(db, "album", "album_id", have)
        let genres = try names(db, "genre", "genre_id", have), keys = try names(db, "key", "key_id", have)
        let labels = try names(db, "label", "label_id", have)
        let cols = try db.columns("content")
        func col(_ c: String, _ fallback: String = "NULL") -> String { cols.contains(c) ? "\"\(c)\"" : fallback }
        let sql = """
        SELECT content_id, \(col("title")) AS title, \(col("artist_id_artist")) AS artist, \(col("album_id")) AS album, \(col("genre_id")) AS genre,
               \(col("label_id")) AS label, \(col("key_id")) AS key, \(col("djComment")) AS comment, \(col("bpmx100")) AS bpm, \(col("length")) AS length,
               \(col("path")) AS path, \(col("fileName")) AS fileName, \(col("fileSize")) AS fileSize, \(col("fileType")) AS fileType,
               \(col("bitrate")) AS bitrate, \(col("bitDepth")) AS bitDepth, \(col("samplingRate")) AS samplingRate,
               \(col("analysisDataFilePath")) AS anlz, \(col("rating")) AS rating, \(col("color_id")) AS color
        FROM content ORDER BY content_id
        """
        for r in try db.query(sql) {
            out.tracks.append(OLTrack(
                id: r["content_id"]?.int ?? 0, title: r["title"]?.string ?? "",
                artist: artists[r["artist"]?.int ?? -1] ?? "", album: albums[r["album"]?.int ?? -1] ?? "",
                genre: genres[r["genre"]?.int ?? -1] ?? "", label: labels[r["label"]?.int ?? -1] ?? "",
                key: keys[r["key"]?.int ?? -1] ?? "", comment: r["comment"]?.string ?? "",
                bpm: Double(r["bpm"]?.int ?? 0) / 100, durationMs: r["length"]?.int ?? 0,
                path: r["path"]?.string ?? "", fileName: r["fileName"]?.string ?? "", fileSize: r["fileSize"]?.int ?? 0,
                fileType: r["fileType"]?.int ?? 0, bitrate: r["bitrate"]?.int ?? 0, bitDepth: r["bitDepth"]?.int ?? 0,
                sampleRate: r["samplingRate"]?.int ?? 0, anlzPath: r["anlz"]?.string ?? "",
                rating: r["rating"]?.int ?? 0, color: r["color"]?.int ?? 0))
        }
        var entries = [Int64: [(Int64, Int64)]]()
        for r in try db.query("SELECT playlist_id, content_id, sequenceNo FROM playlist_content") {
            entries[r["playlist_id"]?.int ?? 0, default: []].append((r["sequenceNo"]?.int ?? 0, r["content_id"]?.int ?? 0))
        }
        for r in try db.query("SELECT playlist_id, sequenceNo, name, attribute, playlist_id_parent FROM playlist") {
            let id = r["playlist_id"]?.int ?? 0, attr = r["attribute"]?.int ?? 0
            out.playlists.append(OLPlaylist(id: id, parent: r["playlist_id_parent"]?.int ?? 0, seq: r["sequenceNo"]?.int ?? 0,
                                            folder: attr == 1, name: r["name"]?.string ?? "",
                                            tracks: (entries[id] ?? []).sorted { $0.0 < $1.0 }.map { $0.1 }, attribute: attr))
        }
        out.playlists = out.playlists.enumerated().sorted { ($0.element.parent, $0.element.seq, $0.offset) < ($1.element.parent, $1.element.seq, $1.offset) }.map { $0.element }
        if have.contains("cue") {
            let cc = try db.columns("cue")
            let comment = cc.contains("cueComment") ? "cueComment" : "NULL", color = cc.contains("colorTableIndex") ? "colorTableIndex" : "0"
            for r in try db.query("SELECT cue_id, content_id, kind, inUsec, outUsec, \(comment) AS cm, \(color) AS col FROM cue") {
                let o = r["outUsec"]?.int ?? -1
                out.cues.append(OLCue(id: r["cue_id"]?.int ?? 0, track: r["content_id"]?.int ?? 0, kind: r["kind"]?.int ?? 0,
                                      inMs: Double(r["inUsec"]?.int ?? 0) / 1000, outMs: o > 0 ? Double(o) / 1000 : nil,
                                      comment: r["cm"]?.string ?? "", color: r["col"]?.int ?? 0))
            }
        }
        if have.contains("property"), let p = try db.query("SELECT * FROM property LIMIT 1").first {
            out.deviceName = p["deviceName"]?.string ?? ""; out.dbVersion = p["dbVersion"]?.int ?? 0
        }
        if integrity { out.integrity = (try? db.integrityCheck()) ?? ["integrity check couldn't run"] }
        return out
    }

    /// Rewrites the playlist and playlist_content tables to `nodes` (in tree order, siblings numbered from 1
    /// in that order), in one transaction on a decrypted copy, then reads it back and re-encrypts it with the
    /// file's own salt. Returns the new file. Throws (writing nothing) if anything doesn't read back as asked.
    public static func writePlaylists(_ data: [UInt8], _ nodes: [OLPlaylist], passphrase: String = SQLCipherCodec.oneLibraryPassphrase) throws -> [UInt8] {
        let (db, codec, url) = try openCopy(data, passphrase: passphrase)
        defer { db.close(); try? FileManager.default.removeItem(at: url) }
        let before = try read(db, integrity: false)
        let known = Set(before.tracks.map { $0.id })
        var ids = Set<Int64>()
        for n in nodes {
            if n.id <= 0 || ids.contains(n.id) { throw OneLibraryError.cantWrite("bad playlist id \(n.id)") }
            ids.insert(n.id)
        }
        for n in nodes where n.parent != 0 && !ids.contains(n.parent) { throw OneLibraryError.cantWrite("playlist parent missing") }
        for n in nodes where !n.folder { for t in n.tracks where !known.contains(t) { throw OneLibraryError.cantWrite("track \(t) isn't in this library") } }
        // keep each existing playlist's image and attribute; new ones get 0 (playlist) / 1 (folder)
        let old = Dictionary(before.playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pcols = try db.columns("playlist")
        var images = [Int64: SQLValue]()
        if pcols.contains("image_id") { for r in try db.query("SELECT playlist_id, image_id FROM playlist") { images[r["playlist_id"]?.int ?? 0] = r["image_id"] ?? .null } }
        var seq = [Int64: Int64]()
        try db.transaction {
            try db.run("DELETE FROM playlist_content")
            try db.run("DELETE FROM playlist")
            for n in nodes {
                let s = (seq[n.parent] ?? 0) + 1; seq[n.parent] = s
                let attr: Int64 = n.folder ? 1 : (old[n.id].map { $0.folder ? 0 : $0.attribute } ?? 0)
                if pcols.contains("image_id") {
                    try db.run("INSERT INTO playlist (playlist_id, sequenceNo, name, image_id, attribute, playlist_id_parent) VALUES (?, ?, ?, ?, ?, ?)",
                               [.int(n.id), .int(s), .text(n.name), images[n.id] ?? .null, .int(attr), n.parent == 0 ? .null : .int(n.parent)])
                } else {
                    try db.run("INSERT INTO playlist (playlist_id, sequenceNo, name, attribute, playlist_id_parent) VALUES (?, ?, ?, ?, ?)",
                               [.int(n.id), .int(s), .text(n.name), .int(attr), n.parent == 0 ? .null : .int(n.parent)])
                }
                if !n.folder {
                    for (i, t) in n.tracks.enumerated() {
                        try db.run("INSERT INTO playlist_content (playlist_id, content_id, sequenceNo) VALUES (?, ?, ?)", [.int(n.id), .int(t), .int(Int64(i + 1))])
                    }
                }
            }
        }
        // read back: the playlists as asked, the tracks untouched, SQLite happy
        let after = try read(db, integrity: true)
        if after.integrity != ["ok"] { throw OneLibraryError.readBack("integrity check: \(after.integrity.prefix(3).joined(separator: "; "))") }
        if after.tracks != before.tracks { throw OneLibraryError.readBack("tracks changed") }
        let got = Dictionary(after.playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if got.count != nodes.count { throw OneLibraryError.readBack("playlist count didn't read back") }
        for n in nodes {
            guard let g = got[n.id], g.parent == n.parent, g.folder == n.folder, g.name == n.name, g.tracks == (n.folder ? [] : n.tracks)
            else { throw OneLibraryError.readBack("playlist didn't read back: \(n.name)") }
        }
        db.close()
        var plain = [UInt8](try Data(contentsOf: url))
        // SQLite may have grown the file by whole pages; a plain test database stays plain
        guard let c = codec else { return plain }
        if plain.count % SQLCipherCodec.pageSize != 0 { plain += [UInt8](repeating: 0, count: SQLCipherCodec.pageSize - plain.count % SQLCipherCodec.pageSize) }
        let enc = try c.encrypt(plain)
        // and the encrypted file must decrypt to exactly what was checked
        if try c.decrypt(enc) != plain { throw OneLibraryError.readBack("re-encrypted file didn't decrypt back") }
        return enc
    }
}
