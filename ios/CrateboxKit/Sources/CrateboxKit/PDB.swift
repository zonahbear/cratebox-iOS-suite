// rekordbox USB/SD exports: export.pdb, read and (playlists only) written.
// A port of tools/rekordbox.js (RB.parsePdb, RB.writePlaylists) from the web app; the layout follows
// Deep Symmetry's crate-digger (rekordbox_pdb.ksy). The writer must give byte-for-byte the same file
// as the JS one (tests compare against files the JS writer made).
import Foundation

public enum PDBError: Error, Equatable, CustomStringConvertible {
    case notPDB, brokenChain(UInt32), noTable(UInt32), noDataPages(UInt32), noFreePage(UInt32)
    case badId(UInt32), missingParent, rowTooBig, noRoom(UInt32), readBack(String)
    public var description: String {
        switch self {
        case .notPDB: return "not an export.pdb"
        case .brokenChain(let t): return "export.pdb: broken page chain in table \(t)"
        case .noTable(let t): return "export.pdb has no table \(t)"
        case .noDataPages(let t): return "export.pdb: table \(t) has no data pages"
        case .noFreePage(let t): return "export.pdb: no free page for table \(t)"
        case .badId(let i): return "bad playlist id \(i)"
        case .missingParent: return "playlist parent missing"
        case .rowTooBig: return "row too big"
        case .noRoom(let t): return "export.pdb: no room on the page for this change (table \(t)); make it in rekordbox and export again"
        case .readBack(let s): return "export.pdb: \(s)"
        }
    }
}

public struct PDBTrack: Equatable, Codable {
    public var id: UInt32
    public var title: String, artist: String, album: String, genre: String, label: String, key: String
    public var bpm: Double, duration: Int, size: UInt32, sampleRate: UInt32, rating: Int, color: Int
    public var path: String, filename: String, anlzPath: String, comment: String, dateAdded: String
}

public struct PDBPlaylist: Equatable, Codable {
    public var id: UInt32, parent: UInt32, unk: UInt32, sort: UInt32
    public var folder: Bool
    public var name: String
    public var tracks: [UInt32]
    public init(id: UInt32, parent: UInt32 = 0, unk: UInt32 = 0, sort: UInt32 = 0, folder: Bool = false, name: String, tracks: [UInt32] = []) {
        self.id = id; self.parent = parent; self.unk = unk; self.sort = sort; self.folder = folder; self.name = name; self.tracks = tracks
    }
}

public struct PDBDatabase: Equatable {
    public var tracks: [PDBTrack]
    public var playlists: [PDBPlaylist]
}

public enum PDBPage: UInt32 { case tracks = 0, genres, artists, albums, labels, keys, colors, playlistTree, playlistEntries }

struct Bytes {
    let b: [UInt8]
    var count: Int { b.count }
    func u8(_ o: Int) -> UInt8 { b[o] }
    func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
}

public enum PDB {
    // ---- strings ----
    static func string(_ d: Bytes, _ pos: Int) -> String {
        let lk = d.u8(pos)
        if lk == 0x40 || lk == 0x90 {
            let len = Int(d.u16(pos + 1))
            let n = max(0, len - 4)
            let s = Array(d.b[(pos + 4)..<min(d.count, pos + 4 + n)])
            var out: String
            if lk == 0x40 { out = String(s.map { Character(Unicode.Scalar($0)) }) }
            else {
                var u = [UInt16]()
                var i = 0
                while i + 1 < s.count { u.append(UInt16(s[i]) | UInt16(s[i + 1]) << 8); i += 2 }
                out = String(decoding: u, as: UTF16.self)
            }
            while out.hasSuffix("\u{0}") { out.removeLast() }
            return out
        }
        let n = Int(lk >> 1) - 1
        if n <= 0 { return "" }
        return String(d.b[(pos + 1)..<min(d.count, pos + 1 + n)].map { Character(Unicode.Scalar($0)) })
    }

    /// A DeviceSQL string: short ASCII (up to 126 chars), long ASCII (0x40) or long UTF-16LE (0x90).
    public static func stringBytes(_ s: String) -> [UInt8] {
        let units = Array(s.utf16)
        let ascii = units.allSatisfy { $0 < 0x80 }
        if ascii && units.count <= 126 {
            return [UInt8(((units.count + 1) << 1) | 1)] + units.map { UInt8($0) }
        }
        let n = ascii ? units.count : units.count * 2
        var b = [UInt8](repeating: 0, count: 4 + n)
        b[0] = ascii ? 0x40 : 0x90
        b[1] = UInt8((n + 4) & 0xff); b[2] = UInt8(((n + 4) >> 8) & 0xff); b[3] = 0
        for (i, c) in units.enumerated() {
            if ascii { b[4 + i] = UInt8(c) } else { b[4 + 2 * i] = UInt8(c & 0xff); b[5 + 2 * i] = UInt8(c >> 8) }
        }
        return b
    }

    // ---- rows ----
    /// Every present row of one table: calls fn(rowOffsetInFile).
    static func rows(_ d: Bytes, _ type: UInt32, _ fn: (Int) -> Void) {
        guard d.count >= 28 else { return }
        let lenPage = Int(d.u32(4)), numTables = Int(d.u32(8))
        guard lenPage > 0 else { return }
        for t in 0..<numTables {
            let tp = 28 + t * 16
            guard tp + 16 <= d.count, d.u32(tp) == type else { continue }
            var page = Int(d.u32(tp + 8))
            let last = Int(d.u32(tp + 12))
            var seen = Set<Int>()
            while !seen.contains(page) && (page + 1) * lenPage <= d.count {
                seen.insert(page)
                let p = page * lenPage
                if d.u32(p + 8) != type { break }
                let packed = Int(d.u8(p + 24)) | Int(d.u8(p + 25)) << 8 | Int(d.u8(p + 26)) << 16
                let numOffsets = packed & 0x1fff, flags = d.u8(p + 27)
                if flags & 0x40 == 0 && numOffsets > 0 {
                    let groups = (numOffsets - 1) / 16 + 1
                    for g in 0..<groups {
                        let base = p + lenPage - g * 0x24
                        let present = d.u16(base - 4)
                        var r = 0
                        while r < 16 && g * 16 + r < numOffsets {
                            if (present >> r) & 1 == 1 {
                                let ofs = Int(d.u16(base - (6 + 2 * r)))
                                let at = p + 40 + ofs
                                if at < d.count { fn(at) }
                            }
                            r += 1
                        }
                    }
                }
                if page == last { break }
                page = Int(d.u32(p + 12))
            }
        }
    }

    public static func parse(_ data: [UInt8]) -> PDBDatabase {
        let d = Bytes(b: data)
        func named(_ type: PDBPage, _ idAt: Int, _ name: (Int) -> String) -> [UInt32: String] {
            var m = [UInt32: String]()
            rows(d, type.rawValue) { o in if o + idAt + 4 <= d.count { m[d.u32(o + idAt)] = name(o) } }
            return m
        }
        func nearFar(_ nearAt: Int, _ farAt: Int) -> (Int) -> String {
            return { o in
                let sub = d.u16(o)
                return string(d, o + ((sub & 0x04) != 0 ? Int(d.u16(o + farAt)) : Int(d.u8(o + nearAt))))
            }
        }
        let artists = named(.artists, 4, nearFar(9, 0x0a))
        let albums = named(.albums, 12, nearFar(21, 0x16))
        let genres = named(.genres, 0) { string(d, $0 + 4) }
        let keys = named(.keys, 0) { string(d, $0 + 8) }
        let labels = named(.labels, 0) { string(d, $0 + 4) }
        var tracks = [PDBTrack]()
        rows(d, PDBPage.tracks.rawValue) { o in
            guard o + 94 + 2 * 21 <= d.count else { return }
            let str = { (k: Int) -> String in string(d, o + Int(d.u16(o + 94 + 2 * k))) }
            tracks.append(PDBTrack(
                id: d.u32(o + 72), title: str(17), artist: artists[d.u32(o + 68)] ?? "", album: albums[d.u32(o + 64)] ?? "",
                genre: genres[d.u32(o + 60)] ?? "", label: labels[d.u32(o + 40)] ?? "", key: keys[d.u32(o + 32)] ?? "",
                bpm: Double(d.u32(o + 56)) / 100, duration: Int(d.u16(o + 84)), size: d.u32(o + 16), sampleRate: d.u32(o + 8),
                rating: Int(d.u8(o + 89)), color: Int(d.u8(o + 88)),
                path: str(20), filename: str(19), anlzPath: str(14), comment: str(16), dateAdded: str(10)))
        }
        var tree = [PDBPlaylist]()
        rows(d, PDBPage.playlistTree.rawValue) { o in
            guard o + 21 <= d.count else { return }
            tree.append(PDBPlaylist(id: d.u32(o + 12), parent: d.u32(o), unk: d.u32(o + 4), sort: d.u32(o + 8),
                                    folder: d.u32(o + 16) != 0, name: string(d, o + 20)))
        }
        var byList = [UInt32: [(index: UInt32, track: UInt32)]]()
        rows(d, PDBPage.playlistEntries.rawValue) { o in
            guard o + 12 <= d.count else { return }
            byList[d.u32(o + 8), default: []].append((d.u32(o), d.u32(o + 4)))
        }
        for i in tree.indices where !tree[i].folder {
            // stable sort by entry index, like the JS Array.sort
            tree[i].tracks = (byList[tree[i].id] ?? []).enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map { $0.element.track }
        }
        tree = tree.enumerated().sorted { a, b in
            (a.element.parent, a.element.sort, a.offset) < (b.element.parent, b.element.sort, b.offset)
        }.map { $0.element }
        return PDBDatabase(tracks: tracks, playlists: tree)
    }

    // ---- writing ----
    /// Rewrites the playlist tree and playlist entry tables (see RB.writePlaylists in tools/rekordbox.js).
    /// nodes in the order they should show; siblings are numbered in that order.
    public static func writePlaylists(_ input: [UInt8], _ nodes: [PDBPlaylist]) throws -> [UInt8] {
        guard input.count >= 28 else { throw PDBError.notPDB }
        let src = Bytes(b: input)
        let PS = Int(src.u32(4)), NT = Int(src.u32(8))
        if PS < 512 || PS > 65536 || NT < 9 || NT > 64 { throw PDBError.notPDB }
        var ids = Set<UInt32>()
        for n in nodes {
            if n.id == 0 || ids.contains(n.id) { throw PDBError.badId(n.id) }
            ids.insert(n.id)
        }
        for n in nodes where n.parent != 0 && !ids.contains(n.parent) { throw PDBError.missingParent }
        var sortOf = [UInt32: UInt32](), seenParent = [UInt32: UInt32]()
        for n in nodes { let c = seenParent[n.parent] ?? 0; sortOf[n.id] = c; seenParent[n.parent] = c + 1 }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
        let treeRows: [[UInt8]] = nodes.map { n in
            le32(n.parent) + le32(n.unk) + le32(sortOf[n.id]!) + le32(n.id) + le32(n.folder ? 1 : 0) + stringBytes(n.name)
        }
        var entryRows = [[UInt8]]()
        for n in nodes where !n.folder {
            for (i, tid) in n.tracks.enumerated() { entryRows.append(le32(UInt32(i + 1)) + le32(tid) + le32(n.id)) }
        }
        var out = input
        try pack(&out, PDBPage.playlistTree.rawValue, treeRows)
        try pack(&out, PDBPage.playlistEntries.rawValue, entryRows)
        // read it back: the playlists must come out as asked and the tracks as they were
        let before = parse(input), after = parse(out)
        let got = Dictionary(after.playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for n in nodes {
            guard let g = got[n.id], g.parent == n.parent, g.folder == n.folder, g.name == n.name, g.tracks == (n.folder ? [] : n.tracks)
            else { throw PDBError.readBack("playlist didn't read back: \(n.name)") }
        }
        if after.playlists.count != nodes.count { throw PDBError.readBack("playlist count didn't read back") }
        if after.tracks != before.tracks { throw PDBError.readBack("tracks changed") }
        return out
    }

    /// Rewrites every data page of one table with `rows` (in order), allocating pages from the table's
    /// empty-page candidate when they don't fit. keepFlags: keep each page's flags byte (else 0x24, as the
    /// web app's playlist writer does); indexShift: set each row's index_shift (bytes 2-3) to 0x20 × its slot,
    /// as rekordbox numbers track, artist and album rows.
    static func pack(_ out: inout [UInt8], _ type: UInt32, _ rows: [[UInt8]], keepFlags: Bool = false, indexShift: Bool = false) throws {
        let PS = Int(Bytes(b: out).u32(4)), NT = Int(Bytes(b: out).u32(8))
        let HEAP = 0x28
        func r32(_ o: Int) -> UInt32 { UInt32(out[o]) | UInt32(out[o + 1]) << 8 | UInt32(out[o + 2]) << 16 | UInt32(out[o + 3]) << 24 }
        func w32(_ o: Int, _ v: UInt32) { out[o] = UInt8(v & 0xff); out[o + 1] = UInt8((v >> 8) & 0xff); out[o + 2] = UInt8((v >> 16) & 0xff); out[o + 3] = UInt8(v >> 24) }
        func r16(_ o: Int) -> UInt16 { UInt16(out[o]) | UInt16(out[o + 1]) << 8 }
        func w16(_ o: Int, _ v: UInt16) { out[o] = UInt8(v & 0xff); out[o + 1] = UInt8(v >> 8) }
        func grow(_ pages: Int) { if pages * PS > out.count { out += [UInt8](repeating: 0, count: pages * PS - out.count) } }
        func seq() -> UInt32 { let s = r32(20); w32(20, s &+ 1); return s }
        var tp = -1
        for t in 0..<NT where r32(28 + t * 16) == type { tp = 28 + t * 16 }
        if tp < 0 { throw PDBError.noTable(type) }
        var pages = [Int](), seen = Set<Int>()
        var page = Int(r32(tp + 8))
        let last = Int(r32(tp + 12))
        while true {
            if seen.contains(page) || (page + 1) * PS > out.count || r32(page * PS + 8) != type { throw PDBError.brokenChain(type) }
            seen.insert(page)
            if out[page * PS + 27] & 0x40 == 0 { pages.append(page) }
            if page == last { break }
            page = Int(r32(page * PS + 12))
        }
        // an empty table (only its header page) gets its first data page from the empty-page candidate below
        // (the track info writer's tables; the playlist writer keeps the web app's behaviour and refuses)
        if pages.isEmpty && !keepFlags { throw PDBError.noDataPages(type) }
        if pages.isEmpty && rows.isEmpty { return }
        let chainLast = page
        let flagsOf = Dictionary(uniqueKeysWithValues: pages.map { ($0, out[$0 * PS + 27]) })
        func idxSize(_ m: Int) -> Int { (m / 16) * 36 + (m % 16 != 0 ? 4 + 2 * (m % 16) : 0) }
        func fits(_ used: Int, _ n: Int, _ len: Int) -> Bool { HEAP + used + ((len + 3) & ~3) + idxSize(n + 1) <= PS }
        var plan: [[[UInt8]]] = [[]]
        var used = 0
        for r in rows {
            if r.count + HEAP + 6 > PS { throw PDBError.rowTooBig }
            if !fits(used, plan[plan.count - 1].count, r.count) { plan.append([]); used = 0 }
            plan[plan.count - 1].append(r); used += (r.count + 3) & ~3
        }
        while plan.count > pages.count {
            let cand = Int(r32(tp + 4)), nextU = r32(12)
            if seen.contains(cand) || cand <= 0 || UInt32(cand) >= nextU { throw PDBError.noFreePage(type) }
            grow(cand + 1)
            let prev = pages.last ?? chainLast
            w32(prev * PS + 12, UInt32(cand))
            for i in (cand * PS)..<((cand + 1) * PS) { out[i] = 0 }
            w32(cand * PS + 4, UInt32(cand)); w32(cand * PS + 8, type); w32(cand * PS + 12, nextU)
            w32(tp + 4, nextU); w32(tp + 12, UInt32(cand)); w32(12, nextU + 1)
            pages.append(cand); seen.insert(cand)
        }
        for (k, pg) in pages.enumerated() {
            let o = pg * PS
            let list = k < plan.count ? plan[k] : []
            let n = list.count
            for i in (o + 0x10)..<(o + PS) { out[i] = 0 }
            w32(o + 0x10, seq())
            let packed = n | (n << 13)
            out[o + 0x18] = UInt8(packed & 0xff); out[o + 0x19] = UInt8((packed >> 8) & 0xff); out[o + 0x1a] = UInt8((packed >> 16) & 0xff)
            out[o + 0x1b] = keepFlags ? flagsOf[pg] ?? flagsOf.values.first ?? 0x24 : 0x24
            var at = 0
            for (i, r) in list.enumerated() {
                for (j, byte) in r.enumerated() { out[o + HEAP + at + j] = byte }
                if indexShift { w16(o + HEAP + at + 2, UInt16(i * 0x20)) }
                let g = i / 16, j = i % 16, base = o + PS - g * 36
                w16(base - 6 - 2 * j, UInt16(at))
                let bit = r16(base - 4) | UInt16(1 << j)
                w16(base - 4, bit); w16(base - 2, bit)
                at += (r.count + 3) & ~3
            }
            w16(o + 0x1c, UInt16(PS - HEAP - at - idxSize(n))); w16(o + 0x1e, UInt16(at))
            w16(o + 0x20, n > 0 ? UInt16(n) : 0x1fff); w16(o + 0x22, n > 0 ? 0 : 0x1fff)
        }
    }
}
