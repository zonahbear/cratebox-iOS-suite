// export.pdb: writing track info (title, artist, album, genre, comment, rating, BPM) into the track rows.
// Row layouts follow crate-digger (rekordbox_pdb.ksy). Fixed-size fields (rating, BPM, the artist / album /
// genre ids) are patched in place; a changed title or comment rebuilds that track row (the other strings are
// copied byte for byte, ISRC's odd encoding included) and repacks the track table the way writePlaylists
// repacks the playlist tables, keeping each page's flags. A new artist, album or genre name gets a new row.
// Read back before returning: the edits as asked, every other track, playlist and file format as it was.
// Not proven on a player yet: callers keep it locked (USBWriteGate, .metadata / .beatgrid).
import Foundation

public struct PDBTrackEdit: Equatable {
    public var title: String?, artist: String?, album: String?, genre: String?, comment: String?
    public var rating: Int?, bpm: Double?
    public init(title: String? = nil, artist: String? = nil, album: String? = nil, genre: String? = nil, comment: String? = nil, rating: Int? = nil, bpm: Double? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.genre = genre; self.comment = comment; self.rating = rating; self.bpm = bpm
    }
    public var isEmpty: Bool { self == PDBTrackEdit() }
}

extension PDB {
    static let trackRowHeader = 0x5e + 2 * 21

    /// bytes a DeviceSQL string takes at `pos`, its header included
    static func stringLength(_ d: Bytes, _ pos: Int) -> Int {
        guard pos < d.count else { return 0 }
        let lk = d.u8(pos)
        if lk == 0x40 || lk == 0x90 { return pos + 3 <= d.count ? Int(d.u16(pos + 1)) : 0 }
        return lk & 1 == 1 ? Int(lk >> 1) : 0
    }
    /// every present row of a table, in reading order, as its own bytes
    static func rowBytes(_ d: Bytes, _ type: PDBPage) -> [(at: Int, bytes: [UInt8])] {
        var out = [(at: Int, bytes: [UInt8])]()
        rows(d, type.rawValue) { o in
            let end: Int
            switch type {
            case .tracks: end = o + (0..<21).map { k -> Int in let s = Int(d.u16(o + 0x5e + 2 * k)); return s + stringLength(d, o + s) }.max()!
            case .artists: let far = d.u16(o) & 0x04 != 0; let s = far ? Int(d.u16(o + 0x0a)) : Int(d.u8(o + 9)); end = o + s + stringLength(d, o + s)
            case .albums: let far = d.u16(o) & 0x04 != 0; let s = far ? Int(d.u16(o + 0x16)) : Int(d.u8(o + 21)); end = o + s + stringLength(d, o + s)
            case .genres: end = o + 4 + stringLength(d, o + 4)
            default: end = o
            }
            out.append((o, Array(d.b[o..<min(d.count, max(end, o))])))
        }
        return out
    }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }

    /// Writes `edits` (by track id) into a copy of export.pdb. Throws, writing nothing, when a track isn't
    /// there or the result doesn't read back as asked.
    public static func writeTracks(_ input: [UInt8], _ edits: [UInt32: PDBTrackEdit]) throws -> [UInt8] {
        guard input.count >= 28 else { throw PDBError.notPDB }
        let d = Bytes(b: input)
        let PS = Int(d.u32(4)), NT = Int(d.u32(8))
        if PS < 512 || PS > 65536 || NT < 9 || NT > 64 { throw PDBError.notPDB }
        let before = parse(input)
        var trackRows = rowBytes(d, .tracks)
        guard trackRows.count == before.tracks.count else { throw PDBError.readBack("couldn't read every track row") }
        let index = Dictionary(trackRows.enumerated().map { (d.u32($0.element.at + 72), $0.offset) }, uniquingKeysWith: { a, _ in a })
        for id in edits.keys where index[id] == nil { throw PDBError.readBack("track \(id) isn't in the Device Library") }
        for (id, e) in edits {
            if let r = e.rating, r < 0 || r > 5 { throw PDBError.readBack("track \(id): rating \(r)") }
            if let b = e.bpm, !(b > 0 && b * 100 < Double(UInt32.max)) { throw PDBError.readBack("track \(id): BPM \(b)") }
        }

        // names → ids, adding rows for names the library doesn't have yet
        var artistRows = rowBytes(d, .artists), albumRows = rowBytes(d, .albums), genreRows = rowBytes(d, .genres)
        func artistName(_ r: [UInt8]) -> String { let b = Bytes(b: r); return string(b, (b.u16(0) & 0x04) != 0 ? Int(b.u16(0x0a)) : Int(b.u8(9))) }
        func albumName(_ r: [UInt8]) -> String { let b = Bytes(b: r); return string(b, (b.u16(0) & 0x04) != 0 ? Int(b.u16(0x16)) : Int(b.u8(21))) }
        var artists = [String: UInt32](), albums = [String: UInt32](), genres = [String: UInt32]()
        var maxArtist: UInt32 = 0, maxAlbum: UInt32 = 0, maxGenre: UInt32 = 0
        for (_, r) in artistRows { let id = Bytes(b: r).u32(4); maxArtist = max(maxArtist, id); if artists[artistName(r)] == nil { artists[artistName(r)] = id } }
        for (_, r) in albumRows { let b = Bytes(b: r), id = b.u32(12); maxAlbum = max(maxAlbum, id); let k = albumName(r) + "\u{1f}\(b.u32(8))"; if albums[k] == nil { albums[k] = id } }
        for (_, r) in genreRows { let b = Bytes(b: r), id = b.u32(0); maxGenre = max(maxGenre, id); let n = string(b, 4); if genres[n] == nil { genres[n] = id } }
        let addedFrom = (artists: artistRows.count, albums: albumRows.count, genres: genreRows.count)
        func artistId(_ name: String) -> UInt32 {
            if name.isEmpty { return 0 }
            if let i = artists[name] { return i }
            maxArtist += 1; artists[name] = maxArtist
            var row: [UInt8] = [0x60, 0x00, 0x00, 0x00]
            row += le32(maxArtist); row += [0x03, 0x0a]; row += stringBytes(name)
            artistRows.append((-1, row))
            return maxArtist
        }
        func albumId(_ name: String, artist: UInt32) -> UInt32 {
            if name.isEmpty { return 0 }
            let k = name + "\u{1f}\(artist)"
            if let i = albums[k] { return i }
            maxAlbum += 1; albums[k] = maxAlbum
            var row: [UInt8] = [0x80, 0x00, 0x00, 0x00]
            row += le32(0); row += le32(artist); row += le32(maxAlbum); row += le32(0)
            row += [0x03, 0x16]; row += stringBytes(name)
            albumRows.append((-1, row))
            return maxAlbum
        }
        func genreId(_ name: String) -> UInt32 {
            if name.isEmpty { return 0 }
            if let i = genres[name] { return i }
            maxGenre += 1; genres[name] = maxGenre
            genreRows.append((-1, le32(maxGenre) + stringBytes(name)))
            return maxGenre
        }

        var resized = false
        for (id, e) in edits.sorted(by: { $0.key < $1.key }) where !e.isEmpty {
            let i = index[id]!
            var r = trackRows[i].bytes
            func put32(_ o: Int, _ v: UInt32) { for (k, x) in le32(v).enumerated() { r[o + k] = x } }
            let row = Bytes(b: r)
            if let a = e.artist { put32(68, artistId(a)) }
            if let al = e.album { put32(64, albumId(al, artist: Bytes(b: r).u32(68))) }
            if let g = e.genre { put32(60, genreId(g)) }
            if let rt = e.rating { r[89] = UInt8(rt) }
            if let b = e.bpm { put32(56, UInt32((b * 100).rounded())) }
            if e.title != nil || e.comment != nil {
                // rebuild: the fixed part, then the 21 strings in their order, offsets pointing at them
                var strings = (0..<21).map { k -> [UInt8] in
                    let s = Int(row.u16(0x5e + 2 * k))
                    return Array(row.b[s..<(s + stringLength(row, s))])
                }
                if let t = e.title { strings[17] = stringBytes(t) }
                if let c = e.comment { strings[16] = stringBytes(c) }
                let order = (0..<21).sorted { (row.u16(0x5e + 2 * $0), $0) < (row.u16(0x5e + 2 * $1), $1) }
                var nr = Array(r[0..<trackRowHeader])
                var ofs = [Int](repeating: 0, count: 21)
                for k in order { ofs[k] = nr.count; nr += strings[k] }
                for k in 0..<21 { nr[0x5e + 2 * k] = UInt8(ofs[k] & 0xff); nr[0x5f + 2 * k] = UInt8(ofs[k] >> 8) }
                if nr.count > 0xffff { throw PDBError.rowTooBig }
                if nr.count != trackRows[i].bytes.count { resized = true }
                r = nr
            }
            trackRows[i].bytes = r
        }

        var out = input
        if resized {
            try pack(&out, PDBPage.tracks.rawValue, trackRows.map { $0.bytes }, keepFlags: true, indexShift: true)
        } else {
            for (at, bytes) in trackRows { for (k, x) in bytes.enumerated() { out[at + k] = x } }
        }
        if artistRows.count > addedFrom.artists { try pack(&out, PDBPage.artists.rawValue, artistRows.map { $0.bytes }, keepFlags: true, indexShift: true) }
        if albumRows.count > addedFrom.albums { try pack(&out, PDBPage.albums.rawValue, albumRows.map { $0.bytes }, keepFlags: true, indexShift: true) }
        if genreRows.count > addedFrom.genres { try pack(&out, PDBPage.genres.rawValue, genreRows.map { $0.bytes }, keepFlags: true) }

        // read back
        let after = parse(out)
        let problems = PDB.problems(out)
        if !problems.isEmpty { throw PDBError.readBack(problems[0]) }
        if after.playlists != before.playlists { throw PDBError.readBack("playlists changed") }
        if after.tracks.count != before.tracks.count { throw PDBError.readBack("track count changed") }
        let got = Dictionary(after.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in before.tracks {
            guard var g = got[t.id] else { throw PDBError.readBack("track \(t.id) went missing") }
            if let e = edits[t.id] {
                if let x = e.title, g.title != x { throw PDBError.readBack("title didn't read back: \(x)") }
                if let x = e.artist, g.artist != x { throw PDBError.readBack("artist didn't read back: \(x)") }
                if let x = e.album, g.album != x { throw PDBError.readBack("album didn't read back: \(x)") }
                if let x = e.genre, g.genre != x { throw PDBError.readBack("genre didn't read back: \(x)") }
                if let x = e.comment, g.comment != x { throw PDBError.readBack("comment didn't read back") }
                if let x = e.rating, g.rating != x { throw PDBError.readBack("rating didn't read back") }
                if let x = e.bpm, abs(g.bpm - (x * 100).rounded() / 100) > 1e-9 { throw PDBError.readBack("BPM didn't read back") }
                // the rest of the row as it was
                g.title = t.title; g.artist = t.artist; g.album = t.album; g.genre = t.genre; g.comment = t.comment; g.rating = t.rating; g.bpm = t.bpm
            }
            if g != t { throw PDBError.readBack("track \(t.id) changed in a field that wasn't edited") }
        }
        if trackFormats(out) != trackFormats(input) { throw PDBError.readBack("file formats changed") }
        return out
    }
}
