// OneLibrary (exportLibrary.db): writing track info into `content` and cues into `cue`, the same way
// writePlaylists works: one transaction on a decrypted copy, read back, re-encrypted with the file's salt.
// Columns as in pyrekordbox's onelibrary models (MIT). Only columns the file has are touched.
// Not proven on a player yet, and these parts are guesses until they are (callers keep it locked):
//  - cue.kind: 0 = memory cue, 1-8 = hot cue A-H (pyrekordbox only says 0 = memory, > 0 = hot cue)
//  - cue.colorTableIndex: the ANLZ colour (hot cue colour code / memory cue colour id)
//  - the MPEG frame / decoding position columns are left empty; inUsec / outUsec / in150FramePerSec are set
//  - *ForSearch columns get the name as typed; the *UpdateCount columns are left alone
import Foundation

public struct OLTrackEdit: Equatable {
    public var title: String?, artist: String?, album: String?, genre: String?, comment: String?
    public var rating: Int?, bpm: Double?
    public init(title: String? = nil, artist: String? = nil, album: String? = nil, genre: String? = nil, comment: String? = nil, rating: Int? = nil, bpm: Double? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.genre = genre; self.comment = comment; self.rating = rating; self.bpm = bpm
    }
    public var isEmpty: Bool { self == OLTrackEdit() }
}

extension OneLibrary {
    /// Writes `edits` (by content_id). Throws, writing nothing, if a track isn't there or anything doesn't
    /// read back as asked.
    public static func writeTracks(_ data: [UInt8], _ edits: [Int64: OLTrackEdit], passphrase: String = SQLCipherCodec.oneLibraryPassphrase) throws -> [UInt8] {
        let (db, codec, url) = try openCopy(data, passphrase: passphrase)
        defer { db.close(); try? FileManager.default.removeItem(at: url) }
        let before = try read(db, integrity: false)
        let known = Set(before.tracks.map { $0.id })
        for id in edits.keys where !known.contains(id) { throw OneLibraryError.cantWrite("track \(id) isn't in this library") }
        for (id, e) in edits {
            if let r = e.rating, r < 0 || r > 5 { throw OneLibraryError.cantWrite("track \(id): rating \(r)") }
            if let b = e.bpm, !(b > 0 && b < 10000) { throw OneLibraryError.cantWrite("track \(id): BPM \(b)") }
        }
        let have = try db.tables()
        let cols = try db.columns("content")
        func need(_ c: String) throws { if !cols.contains(c) { throw OneLibraryError.cantWrite("content has no \(c) column") } }
        /// the id for a name in artist / album / genre, adding a row when there's none
        func nameId(_ table: String, _ idCol: String, _ name: String, extra: [String: SQLValue] = [:]) throws -> SQLValue {
            if name.isEmpty { return .null }
            guard have.contains(table) else { throw OneLibraryError.missingTable(table) }
            var whereSql = "name = ?", args: [SQLValue] = [.text(name)]
            for (k, v) in extra.sorted(by: { $0.key < $1.key }) { whereSql += " AND \"\(k)\" IS ?"; args.append(v) }
            if let r = try db.query("SELECT \(idCol) AS i FROM \"\(table)\" WHERE \(whereSql) ORDER BY \(idCol) LIMIT 1", args).first, let i = r["i"] { return i }
            let tc = try db.columns(table)
            let next = (try db.query("SELECT COALESCE(MAX(\(idCol)), 0) + 1 AS n FROM \"\(table)\"").first?["n"]?.int) ?? 1
            var names = [idCol, "name"], vals: [SQLValue] = [.int(next), .text(name)]
            if tc.contains("nameForSearch") { names.append("nameForSearch"); vals.append(.text(name)) }
            for (k, v) in extra.sorted(by: { $0.key < $1.key }) where tc.contains(k) { names.append(k); vals.append(v) }
            try db.run("INSERT INTO \"\(table)\" (\(names.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))", vals)
            return .int(next)
        }
        try db.transaction {
            for (id, e) in edits.sorted(by: { $0.key < $1.key }) where !e.isEmpty {
                var set = [(String, SQLValue)]()
                if let t = e.title { try need("title"); set.append(("title", .text(t))); if cols.contains("titleForSearch") { set.append(("titleForSearch", .text(t))) } }
                var artist: SQLValue?
                if let a = e.artist { try need("artist_id_artist"); let v = try nameId("artist", "artist_id", a); artist = v; set.append(("artist_id_artist", v)) }
                if let al = e.album {
                    try need("album_id")
                    let a = try artist ?? (db.query("SELECT artist_id_artist AS a FROM content WHERE content_id = ?", [.int(id)]).first?["a"] ?? .null)
                    set.append(("album_id", try nameId("album", "album_id", al, extra: ["artist_id": a])))
                }
                if let g = e.genre { try need("genre_id"); set.append(("genre_id", try nameId("genre", "genre_id", g))) }
                if let c = e.comment { try need("djComment"); set.append(("djComment", .text(c))) }
                if let r = e.rating { try need("rating"); set.append(("rating", .int(Int64(r)))) }
                if let b = e.bpm { try need("bpmx100"); set.append(("bpmx100", .int(Int64((b * 100).rounded())))) }
                try db.run("UPDATE content SET \(set.map { "\"\($0.0)\" = ?" }.joined(separator: ", ")) WHERE content_id = ?", set.map { $0.1 } + [.int(id)])
            }
        }
        let after = try read(db, integrity: true)
        if after.integrity != ["ok"] { throw OneLibraryError.readBack("integrity check: \(after.integrity.prefix(3).joined(separator: "; "))") }
        if after.playlists != before.playlists { throw OneLibraryError.readBack("playlists changed") }
        if after.cues != before.cues { throw OneLibraryError.readBack("cues changed") }
        let got = Dictionary(after.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if got.count != before.tracks.count { throw OneLibraryError.readBack("track count changed") }
        for t in before.tracks {
            guard var g = got[t.id] else { throw OneLibraryError.readBack("track \(t.id) went missing") }
            if let e = edits[t.id] {
                if let x = e.title, g.title != x { throw OneLibraryError.readBack("title didn't read back: \(x)") }
                if let x = e.artist, g.artist != x { throw OneLibraryError.readBack("artist didn't read back: \(x)") }
                if let x = e.album, g.album != x { throw OneLibraryError.readBack("album didn't read back: \(x)") }
                if let x = e.genre, g.genre != x { throw OneLibraryError.readBack("genre didn't read back: \(x)") }
                if let x = e.comment, g.comment != x { throw OneLibraryError.readBack("comment didn't read back") }
                if let x = e.rating, g.rating != Int64(x) { throw OneLibraryError.readBack("rating didn't read back") }
                if let x = e.bpm, abs(g.bpm - (x * 100).rounded() / 100) > 1e-9 { throw OneLibraryError.readBack("BPM didn't read back") }
                g.title = t.title; g.artist = t.artist; g.album = t.album; g.genre = t.genre; g.comment = t.comment; g.rating = t.rating; g.bpm = t.bpm
            }
            if g != t { throw OneLibraryError.readBack("track \(t.id) changed in a field that wasn't edited") }
        }
        return try seal(db, codec, url)
    }

    /// Replaces the cue rows of each track in `cues` (by content_id) with the given cues; other tracks' cues
    /// stay as they are.
    public static func writeCues(_ data: [UInt8], _ cues: [Int64: [ANLZCuePoint]], passphrase: String = SQLCipherCodec.oneLibraryPassphrase) throws -> [UInt8] {
        let (db, codec, url) = try openCopy(data, passphrase: passphrase)
        defer { db.close(); try? FileManager.default.removeItem(at: url) }
        let before = try read(db, integrity: false)
        guard try db.tables().contains("cue") else { throw OneLibraryError.missingTable("cue") }
        let known = Set(before.tracks.map { $0.id })
        for id in cues.keys where !known.contains(id) { throw OneLibraryError.cantWrite("track \(id) isn't in this library") }
        for (_, list) in cues { for c in list where c.hot < 0 || c.hot > 8 || (c.loopMs.map { $0 <= c.ms } ?? false) { throw OneLibraryError.cantWrite("bad cue at \(c.ms) ms") } }
        let cc = try db.columns("cue")
        for c in ["cue_id", "content_id", "kind", "inUsec", "outUsec"] where !cc.contains(c) { throw OneLibraryError.cantWrite("cue has no \(c) column") }
        try db.transaction {
            var next = (try db.query("SELECT COALESCE(MAX(cue_id), 0) + 1 AS n FROM cue").first?["n"]?.int) ?? 1
            for (id, list) in cues.sorted(by: { $0.key < $1.key }) {
                try db.run("DELETE FROM cue WHERE content_id = ?", [.int(id)])
                for c in list.sorted(by: { ($0.hot == 0 ? 1 : 0, $0.hot, $0.ms) < ($1.hot == 0 ? 1 : 0, $1.hot, $1.ms) }) {
                    var row: [(String, SQLValue)] = [("cue_id", .int(next)), ("content_id", .int(id)), ("kind", .int(Int64(c.hot))),
                                                     ("inUsec", .int(Int64(c.ms) * 1000)), ("outUsec", .int(c.loopMs.map { Int64($0) * 1000 } ?? -1))]
                    let optional: [(String, SQLValue)] = [
                        ("colorTableIndex", .int(Int64(c.hot > 0 ? c.color?.code ?? 0 : c.colorId ?? 0))),
                        ("cueComment", .text(c.comment)), ("isActiveLoop", .int(0)),
                        ("beatLoopNumerator", .int(0)), ("beatLoopDenominator", .int(0)),
                        ("in150FramePerSec", .int(Int64((Double(c.ms) * 0.15).rounded()))),
                        ("out150FramePerSec", .int(c.loopMs.map { Int64((Double($0) * 0.15).rounded()) } ?? -1)),
                    ]
                    row += optional.filter { cc.contains($0.0) }
                    try db.run("INSERT INTO cue (\(row.map { "\"\($0.0)\"" }.joined(separator: ", "))) VALUES (\(row.map { _ in "?" }.joined(separator: ", ")))", row.map { $0.1 })
                    next += 1
                }
            }
        }
        let after = try read(db, integrity: true)
        if after.integrity != ["ok"] { throw OneLibraryError.readBack("integrity check: \(after.integrity.prefix(3).joined(separator: "; "))") }
        if after.tracks != before.tracks { throw OneLibraryError.readBack("tracks changed") }
        if after.playlists != before.playlists { throw OneLibraryError.readBack("playlists changed") }
        func key(_ c: OLCue) -> String { "\(c.track)|\(c.kind)|\(Int64(c.inMs.rounded()))|\(c.outMs.map { String(Int64($0.rounded())) } ?? "-")|\(c.comment)" }
        let untouched = { (c: OLCue) in cues[c.track] == nil }
        if after.cues.filter(untouched) != before.cues.filter(untouched) { throw OneLibraryError.readBack("another track's cues changed") }
        let want = cues.flatMap { id, list in list.map { "\(id)|\($0.hot)|\($0.ms)|\($0.loopMs.map(String.init) ?? "-")|\($0.comment)" } }.sorted()
        if after.cues.filter({ !untouched($0) }).map(key).sorted() != want { throw OneLibraryError.readBack("cues didn't read back") }
        return try seal(db, codec, url)
    }
}
