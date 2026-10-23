// export.pdb: writing track info (title, artist, album, genre, comment, rating, BPM) into the track rows.
// Row layouts follow crate-digger (rekordbox_pdb.ksy). Fixed-size fields (rating, BPM, the artist / album /
// genre ids) are patched in place; a changed title or comment rebuilds that track row (the other strings are
// copied byte for byte, ISRC's odd encoding included). A new artist, album or genre name gets a new row.
// No row ever moves to another page or slot: each table's first page is an index page that points at its
// data pages, and repacking the track table left it stale (rekordbox 7.2.19 crashed reading such a stick,
// dividing by zero on a string read from where a row used to be). A rebuilt row goes after the used part of
// its own page, as rekordbox's own updates do, and a new row goes in a new slot on the table's last data
// page; if the page has no room, the write is refused.
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
    /// bytes the row at `o` takes, its strings included
    static func rowLength(_ d: Bytes, _ type: PDBPage, _ o: Int) -> Int {
        let end: Int
        switch type {
        case .tracks: end = o + (0..<21).map { k -> Int in let s = Int(d.u16(o + 0x5e + 2 * k)); return s + stringLength(d, o + s) }.max()!
        case .artists: let far = d.u16(o) & 0x04 != 0; let s = far ? Int(d.u16(o + 0x0a)) : Int(d.u8(o + 9)); end = o + s + stringLength(d, o + s)
        case .albums: let far = d.u16(o) & 0x04 != 0; let s = far ? Int(d.u16(o + 0x16)) : Int(d.u8(o + 21)); end = o + s + stringLength(d, o + s)
        case .genres: end = o + 4 + stringLength(d, o + 4)
        default: end = o
        }
        return min(d.count, max(end, o)) - o
    }
    /// every present row of a table, in reading order, as its own bytes
    static func rowBytes(_ d: Bytes, _ type: PDBPage) -> [(at: Int, bytes: [UInt8])] {
        var out = [(at: Int, bytes: [UInt8])]()
        rows(d, type.rawValue) { o in out.append((o, Array(d.b[o..<(o + rowLength(d, type, o))]))) }
        return out
    }
    /// the page and slot holding the row that starts at `at`
    static func slot(_ d: Bytes, at: Int) -> (page: Int, slot: Int)? {
        let PS = Int(d.u32(4)), page = at / PS, o = page * PS
        let nofs = (Int(d.u8(o + 0x18)) | Int(d.u8(o + 0x19)) << 8) & 0x1fff
        for i in 0..<nofs {
            let base = o + PS - (i / 16) * 0x24
            if (d.u16(base - 4) >> (i % 16)) & 1 == 1 && o + 0x28 + Int(d.u16(base - 6 - 2 * (i % 16))) == at { return (page, i) }
        }
        return nil
    }
    /// the last data page in a table's chain
    static func lastDataPage(_ d: Bytes, _ type: PDBPage) -> Int? {
        let PS = Int(d.u32(4)), NT = Int(d.u32(8))
        guard let t = (0..<NT).first(where: { d.u32(28 + $0 * 16) == type.rawValue }) else { return nil }
        var page = Int(d.u32(28 + t * 16 + 8)), found: Int?, seen = Set<Int>()
        let last = Int(d.u32(28 + t * 16 + 12))
        while !seen.contains(page) && (page + 1) * PS <= d.count && d.u32(page * PS + 8) == type.rawValue {
            seen.insert(page)
            if d.u8(page * PS + 27) & 0x40 == 0 { found = page }
            if page == last { break }
            page = Int(d.u32(page * PS + 12))
        }
        return found
    }

    /// Puts `row` in `slot` of `page` (a new slot after the last one when nil), without moving any row to
    /// another page or slot. The bytes go after the page's used heap; when they don't fit there, the page's
    /// rows are packed tighter within the page, each keeping its slot. Marks the page the way rekordbox marks
    /// the row it changed last. Throws noRoom when the page can't hold it.
    static func placeRow(_ out: inout [UInt8], _ type: PDBPage, page: Int, slot: Int?, _ row: [UInt8], indexShift: Bool) throws {
        let PS = Int(Bytes(b: out).u32(4)), o = page * PS, HEAP = 0x28
        func r16(_ a: Int) -> Int { Int(out[a]) | Int(out[a + 1]) << 8 }
        func w16(_ a: Int, _ v: Int) { out[a] = UInt8(v & 0xff); out[a + 1] = UInt8((v >> 8) & 0xff) }
        func w32(_ a: Int, _ v: UInt32) { for (k, x) in le32(v).enumerated() { out[a + k] = x } }
        func base(_ i: Int) -> Int { o + PS - (i / 16) * 0x24 }
        func ofsAt(_ i: Int) -> Int { base(i) - 6 - 2 * (i % 16) }
        func present(_ i: Int) -> Bool { (r16(base(i) - 4) >> (i % 16)) & 1 == 1 }
        func idxSize(_ m: Int) -> Int { (m / 16) * 36 + (m % 16 != 0 ? 4 + 2 * (m % 16) : 0) }
        let packed = Int(out[o + 0x18]) | Int(out[o + 0x19]) << 8 | Int(out[o + 0x1a]) << 16
        var nofs = packed & 0x1fff, nrows = packed >> 13
        if let s = slot, s >= nofs || !present(s) { throw PDBError.readBack("row slot \(s) on page \(page) isn't there") }
        let slots = slot == nil ? nofs + 1 : nofs
        if slots > 0x1fff { throw PDBError.noRoom(type.rawValue) }
        let len = (row.count + 3) & ~3
        var used = r16(o + 0x1e)
        if HEAP + used + len + idxSize(slots) > PS {
            // pack the other rows tighter, slots kept
            let d = Bytes(b: out)
            let others = (0..<nofs).filter { present($0) && $0 != slot }.map { i -> (Int, [UInt8]) in
                let a = o + HEAP + r16(ofsAt(i)); return (i, Array(out[a..<(a + rowLength(d, type, a))]))
            }
            let heapEnd = PS - idxSize(nofs)
            for i in (o + HEAP)..<(o + heapEnd) { out[i] = 0 }
            used = 0
            for (i, b) in others {
                for (k, x) in b.enumerated() { out[o + HEAP + used + k] = x }
                w16(ofsAt(i), used); used += (b.count + 3) & ~3
            }
            if HEAP + used + len + idxSize(slots) > PS { throw PDBError.noRoom(type.rawValue) }
        }
        let s = slot ?? nofs
        if slot == nil {
            if s % 16 == 0 { for a in (base(s) - 6)..<base(s) { out[a] = 0 } }   // a new group's flags and first offset
            nofs += 1; nrows += 1
            let p = nofs | nrows << 13
            out[o + 0x18] = UInt8(p & 0xff); out[o + 0x19] = UInt8((p >> 8) & 0xff); out[o + 0x1a] = UInt8((p >> 16) & 0xff)
            w16(base(s) - 4, r16(base(s) - 4) | 1 << (s % 16))
        }
        for i in 0..<len { out[o + HEAP + used + i] = i < row.count ? row[i] : 0 }
        if indexShift { w16(o + HEAP + used + 2, (s * 0x20) & 0xffff) }
        w16(ofsAt(s), used)
        used += len
        w16(o + 0x1c, PS - HEAP - used - idxSize(nofs)); w16(o + 0x1e, used)
        // the last change on this page: one row, this slot (rekordbox's own pages carry the same marks)
        w16(o + 0x20, 1); w16(o + 0x22, s)
        for g in 0..<((nofs + 15) / 16) { w16(o + PS - g * 0x24 - 2, g == s / 16 ? 1 << (s % 16) : 0) }
        let seq = Bytes(b: out).u32(20)
        w32(o + 0x10, seq); w32(20, seq &+ 1)
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

        var resized = [Int]()
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
                if nr.count != trackRows[i].bytes.count { resized.append(i) }
                r = nr
            }
            trackRows[i].bytes = r
        }

        var out = input
        // the same size: in place. Then the rebuilt rows, each in its own page and slot (found before anything
        // moves, since packing a page tighter moves the rows within it)
        let places = try resized.map { i -> (page: Int, slot: Int, bytes: [UInt8]) in
            guard let p = slot(d, at: trackRows[i].at) else { throw PDBError.readBack("couldn't find a track row's slot") }
            return (p.page, p.slot, trackRows[i].bytes)
        }
        for (i, (at, bytes)) in trackRows.enumerated() where !resized.contains(i) && Array(input[at..<(at + bytes.count)]) != bytes {
            for (k, x) in bytes.enumerated() { out[at + k] = x }
        }
        for p in places { try placeRow(&out, .tracks, page: p.page, slot: p.slot, p.bytes, indexShift: false) }
        for (type, list, from) in [(PDBPage.artists, artistRows, addedFrom.artists), (.albums, albumRows, addedFrom.albums), (.genres, genreRows, addedFrom.genres)] where list.count > from {
            for (_, row) in list[from...] {
                guard let page = lastDataPage(Bytes(b: out), type) else { throw PDBError.noDataPages(type.rawValue) }
                try placeRow(&out, type, page: page, slot: nil, row, indexShift: type != .genres)
            }
        }

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
