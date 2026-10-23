// Writing rekordbox analysis files (ANLZ .DAT / .EXT): hot cues, memory cues and loops (PCOB in both files,
// PCO2 in the .EXT), and the beat grid (PQTZ). Layouts follow Deep Symmetry's crate-digger
// (rekordbox_anlz.ksy) and pyrekordbox's anlz structs (MIT); RekordboxANLZ.parse is the reader.
//
// The writer only replaces tags rekordbox already put in the file, leaves every other tag byte for byte as
// it was, and reads its own output back before returning it. What hasn't been confirmed on a player (and is
// why these writes stay locked behind USBWriteGate until they are):
//  - PCPT `status` (crate-digger: 1 = enabled; pyrekordbox: 4 = enabled; rekordcrate: 0, 4 = active loop) and `order_first` / `order_last` (read here as
//    the previous / next entry in time order). Players are known to read hot_cue, type, time and loop_time.
//  - PCPT / PCP2 `type`: 1 = point, 2 = loop (crate-digger, pyrekordbox); rekordcrate says 0 = point.
//  - PCP2's 20 bytes after the colour (rekordcrate's five unknown words) are written as zeros.
//  - PCOB carries hot cues A-C only (the older players' three); PCO2 carries A-H.
//  - PQT2 (the .EXT's second beat grid) can't be rebuilt (its entries aren't decoded anywhere), so a grid
//    write drops it rather than leave a grid that disagrees with PQTZ.
import Foundation

/// one cue as written to the analysis files. hot: 0 = memory cue, 1...8 = hot cue A-H.
public struct ANLZCuePoint: Equatable, Codable {
    public var hot: Int
    public var ms: UInt32
    public var loopMs: UInt32?
    public var comment: String
    /// PCP2's colour bytes: memory cues use colorId (the colours table), hot cues colorCode + RGB. nil = none.
    public var colorId: UInt8?
    public var color: ANLZHotCueColor?
    public init(hot: Int, ms: UInt32, loopMs: UInt32? = nil, comment: String = "", colorId: UInt8? = nil, color: ANLZHotCueColor? = nil) {
        self.hot = hot; self.ms = ms; self.loopMs = loopMs; self.comment = comment; self.colorId = colorId; self.color = color
    }
}
public struct ANLZHotCueColor: Equatable, Codable {
    public var code: UInt8, r: UInt8, g: UInt8, b: UInt8
    public init(code: UInt8, r: UInt8, g: UInt8, b: UInt8) { self.code = code; self.r = r; self.g = g; self.b = b }
}

public enum ANLZWriteError: Error, Equatable, CustomStringConvertible {
    case notANLZ, missingTag(String), badCue(String), badGrid(String), readBack(String)
    public var description: String {
        switch self {
        case .notANLZ: return "not a rekordbox analysis file"
        case .missingTag(let t): return "the analysis file has no \(t) tag (re-analyse the track in rekordbox and export again)"
        case .badCue(let s): return "cue: \(s)"
        case .badGrid(let s): return "beat grid: \(s)"
        case .readBack(let s): return "analysis file: \(s)"
        }
    }
}

extension RekordboxANLZ {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func fourcc(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// the file header and each tag's bytes (header included), in file order
    static func split(_ b: [UInt8]) throws -> (header: [UInt8], tags: [(name: String, bytes: [UInt8])]) {
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        guard b.count >= 12, Array(b[0..<4]) == fourcc("PMAI") else { throw ANLZWriteError.notANLZ }
        let lenHeader = u32(4)
        guard lenHeader >= 12, lenHeader <= b.count, u32(8) == b.count else { throw ANLZWriteError.notANLZ }
        var tags = [(name: String, bytes: [UInt8])]()
        var pos = lenHeader
        while pos < b.count {
            guard pos + 12 <= b.count else { throw ANLZWriteError.readBack("a tag is cut off at the end of the file") }
            let lenTag = u32(pos + 8), lenTagHeader = u32(pos + 4)
            guard lenTag >= 12, lenTagHeader >= 12, lenTagHeader <= lenTag, pos + lenTag <= b.count else { throw ANLZWriteError.readBack("a tag runs past the end of the file") }
            tags.append((String(decoding: b[pos..<(pos + 4)], as: UTF8.self), Array(b[pos..<(pos + lenTag)])))
            pos += lenTag
        }
        return (Array(b[0..<lenHeader]), tags)
    }
    static func join(_ header: [UInt8], _ tags: [[UInt8]]) -> [UInt8] {
        var out = header + tags.flatMap { $0 }
        let n = be32(UInt32(out.count))
        for i in 0..<4 { out[8 + i] = n[i] }
        return out
    }
    static func tag(_ name: String, header: [UInt8], body: [UInt8]) -> [UInt8] {
        fourcc(name) + be32(UInt32(12 + header.count)) + be32(UInt32(12 + header.count + body.count)) + header + body
    }

    // ---- cues ----
    static func pcpt(_ c: ANLZCuePoint, prev: Int?, next: Int?) -> [UInt8] {
        var e = fourcc("PCPT") + be32(0x1c) + be32(0x38)
        e += be32(UInt32(c.hot)) + be32(1) + be32(0x10000)
        e += be16(prev.map { UInt16($0) } ?? 0xffff) + be16(next.map { UInt16($0) } ?? 0xffff)
        e += [c.loopMs == nil ? 1 : 2, 0] + be16(1000)
        e += be32(c.ms) + be32(c.loopMs ?? 0xffffffff)
        e += [UInt8](repeating: 0, count: 16)
        return e
    }
    static func pcp2(_ c: ANLZCuePoint) -> [UInt8] {
        var comment = [UInt8]()
        for u in c.comment.utf16 { comment += be16(u) }
        comment += [0, 0]                                       // NUL-terminated, also when empty (rekordcrate)
        var e = [UInt8]()
        e += be32(UInt32(c.hot))
        e += [c.loopMs == nil ? 1 : 2, 0] + be16(1000)
        e += be32(c.ms) + be32(c.loopMs ?? 0xffffffff)
        e += [c.colorId ?? 0] + [UInt8](repeating: 0, count: 7)
        e += be16(0) + be16(0)                                  // loop length in beats: not quantised
        e += be32(UInt32(comment.count)) + comment
        let col = c.color ?? ANLZHotCueColor(code: 0, r: 0, g: 0, b: 0)
        e += [col.code, col.r, col.g, col.b]
        e += [UInt8](repeating: 0, count: 20)                   // the five unknown words rekordcrate reads after the colour
        return fourcc("PCP2") + be32(0x10) + be32(UInt32(12 + e.count)) + e
    }
    /// PCOB: type, 2 unknown bytes, count, memory_count (-1 when empty, as rekordbox writes it), entries
    static func pcob(hot: Bool, _ cues: [ANLZCuePoint]) -> [UInt8] {
        let body = cues.enumerated().flatMap { i, c in pcpt(c, prev: i > 0 ? i - 1 : nil, next: i + 1 < cues.count ? i + 1 : nil) }
        return tag("PCOB", header: be32(hot ? 1 : 0) + be16(0) + be16(UInt16(cues.count)) + be32(cues.isEmpty ? 0xffffffff : UInt32(cues.count)), body: body)
    }
    static func pco2(hot: Bool, _ cues: [ANLZCuePoint]) -> [UInt8] {
        tag("PCO2", header: be32(hot ? 1 : 0) + be16(UInt16(cues.count)) + be16(0), body: cues.flatMap(pcp2))
    }

    /// every cue in a file, with the comments and colours from its PCO2 entries where it has them
    public static func cuePoints(_ b: [UInt8]) -> [ANLZCuePoint] {
        guard let (_, tags) = try? split(b) else { return [] }
        func u32(_ t: [UInt8], _ o: Int) -> UInt32 { o + 4 <= t.count ? UInt32(t[o]) << 24 | UInt32(t[o + 1]) << 16 | UInt32(t[o + 2]) << 8 | UInt32(t[o + 3]) : 0 }
        func u16(_ t: [UInt8], _ o: Int) -> Int { o + 2 <= t.count ? Int(t[o]) << 8 | Int(t[o + 1]) : 0 }
        var ob = [ANLZCuePoint](), o2 = [ANLZCuePoint]()
        for (name, t) in tags {
            if name == "PCOB" {
                var e = 24
                for _ in 0..<u16(t, 18) where e + 0x38 <= t.count {
                    ob.append(ANLZCuePoint(hot: Int(u32(t, e + 12)), ms: u32(t, e + 32), loopMs: t[e + 28] == 2 ? u32(t, e + 36) : nil))
                    e += max(0x38, Int(u32(t, e + 8)))
                }
            } else if name == "PCO2" {
                var e = 20
                for _ in 0..<u16(t, 16) where e + 44 <= t.count {
                    let len = Int(u32(t, e + 8)), lc = Int(u32(t, e + 40))
                    var c = ANLZCuePoint(hot: Int(u32(t, e + 12)), ms: u32(t, e + 20), loopMs: t[e + 16] == 2 ? u32(t, e + 24) : nil)
                    c.colorId = t[e + 28] == 0 ? nil : t[e + 28]
                    if lc >= 2 && e + 44 + lc <= t.count {
                        var u = [UInt16]()
                        var i = e + 44
                        while i + 1 < e + 44 + lc { u.append(UInt16(t[i]) << 8 | UInt16(t[i + 1])); i += 2 }
                        while u.last == 0 { u.removeLast() }
                        c.comment = String(decoding: u, as: UTF16.self)
                    }
                    if len - lc >= 48 && e + 48 + lc <= t.count {
                        let k = e + 44 + lc
                        let col = ANLZHotCueColor(code: t[k], r: t[k + 1], g: t[k + 2], b: t[k + 3])
                        if col != ANLZHotCueColor(code: 0, r: 0, g: 0, b: 0) { c.color = col }
                    }
                    o2.append(c)
                    e += max(44, len)
                }
            }
        }
        return o2.isEmpty ? ob : o2
    }

    /// Replaces the cue lists in one analysis file (.DAT or .EXT) with `cues` (hot cues A-H and memory cues /
    /// loops, any order). Both PCOB lists must already be in the file; the PCO2 lists are replaced when the
    /// file has them (the .EXT). Everything else is left as it was.
    public static func writeCues(_ file: [UInt8], _ cues: [ANLZCuePoint]) throws -> [UInt8] {
        var hotSeen = Set<Int>()
        for c in cues {
            if c.hot < 0 || c.hot > 8 { throw ANLZWriteError.badCue("hot cue \(c.hot) (only A-H)") }
            if c.hot > 0 && !hotSeen.insert(c.hot).inserted { throw ANLZWriteError.badCue("two hot cues in slot \(c.hot)") }
            if let l = c.loopMs, l <= c.ms { throw ANLZWriteError.badCue("a loop has to end after it starts") }
            if c.ms == 0xffffffff { throw ANLZWriteError.badCue("cue time") }
        }
        let hot = cues.filter { $0.hot > 0 }.sorted { $0.hot < $1.hot }
        let memory = cues.filter { $0.hot == 0 }.enumerated().sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }.map { $0.element }
        let legacyHot = hot.filter { $0.hot <= 3 }
        let (header, tags) = try split(file)
        func listType(_ t: [UInt8]) -> UInt32 { UInt32(t[12]) << 24 | UInt32(t[13]) << 16 | UInt32(t[14]) << 8 | UInt32(t[15]) }
        let pcobs = tags.filter { $0.name == "PCOB" }.map { listType($0.bytes) }
        guard pcobs.contains(1), pcobs.contains(0) else { throw ANLZWriteError.missingTag("PCOB") }
        let pco2s = tags.filter { $0.name == "PCO2" }.map { listType($0.bytes) }
        if !pco2s.isEmpty && !(pco2s.contains(1) && pco2s.contains(0)) { throw ANLZWriteError.missingTag("PCO2 (both lists)") }
        let hasExtended = !pco2s.isEmpty                       // a .DAT only carries A-C; D-H go in the .EXT
        var out = [[UInt8]]()
        for (name, t) in tags {
            if name == "PCOB" { out.append(listType(t) == 1 ? pcob(hot: true, legacyHot) : pcob(hot: false, memory)) }
            else if name == "PCO2" { out.append(listType(t) == 1 ? pco2(hot: true, hot) : pco2(hot: false, memory)) }
            else { out.append(t) }
        }
        let result = join(header, out)
        // read back with the player-side parser and with our own
        let a = parse(result)
        let wantHot = hasExtended ? hot : legacyHot
        func key(_ c: ANLZCue) -> String { "\(c.hot)|\(c.ms)|\(c.loopMs.map(String.init) ?? "-")" }
        func key(_ c: ANLZCuePoint) -> String { "\(c.hot)|\(c.ms)|\(c.loopMs.map(String.init) ?? "-")" }
        if a.hot.map(key) != wantHot.map(key) { throw ANLZWriteError.readBack("hot cues didn't read back") }
        if a.memory.map(key) != memory.map(key) { throw ANLZWriteError.readBack("memory cues didn't read back") }
        if hasExtended {
            let back = cuePoints(result).map { key($0) + "|" + $0.comment }.sorted()
            if back != (hot + memory).map({ key($0) + "|" + $0.comment }).sorted() { throw ANLZWriteError.readBack("cue comments didn't read back") }
        }
        let (_, newTags) = try split(result)
        if newTags.map({ $0.name }) != tags.map({ $0.name }) { throw ANLZWriteError.readBack("tag order changed") }
        for (x, y) in zip(tags, newTags) where x.name != "PCOB" && x.name != "PCO2" && x.bytes != y.bytes { throw ANLZWriteError.readBack("\(x.name) changed") }
        return result
    }

    // ---- beat grid ----
    /// A constant-tempo grid: `firstBeat` (seconds) is a downbeat; beats run from the first one at or after
    /// 0 s to `duration`, numbered 1-4 within the bar, times rounded to the millisecond.
    public static func constantGrid(bpm: Double, firstBeat: Double, duration: Double) throws -> [ANLZBeat] {
        guard bpm >= 20, bpm <= 999, bpm.isFinite else { throw ANLZWriteError.badGrid("BPM \(bpm)") }
        guard duration > 0, duration.isFinite, firstBeat.isFinite, firstBeat >= 0, firstBeat < duration else { throw ANLZWriteError.badGrid("first beat \(firstBeat) s in a \(duration) s track") }
        let period = 60 / bpm
        let before = Int((firstBeat / period).rounded(.down))   // whole beats before the downbeat
        var out = [ANLZBeat]()
        var i = -before
        let tempo = UInt16(min(Double(UInt16.max), (bpm * 100).rounded()))
        while true {
            let t = firstBeat + Double(i) * period
            if t >= duration { break }
            if t >= 0 { out.append(ANLZBeat(n: ((i % 4) + 4) % 4 + 1, bpm: Double(tempo) / 100, ms: UInt32((t * 1000).rounded()))) }
            i += 1
        }
        if out.count < 2 { throw ANLZWriteError.badGrid("fewer than two beats") }
        return out
    }

    /// Replaces the beat grid (PQTZ) in an analysis file. A file without PQTZ (the .EXT usually) keeps its
    /// grid tags as they are, except PQT2, which is dropped (see the top of this file). Returns the file
    /// unchanged when there's nothing to do.
    public static func writeGrid(_ file: [UInt8], _ beats: [ANLZBeat]) throws -> [UInt8] {
        guard beats.count >= 2 else { throw ANLZWriteError.badGrid("fewer than two beats") }
        for (a, b) in zip(beats, beats.dropFirst()) where b.ms <= a.ms { throw ANLZWriteError.badGrid("beats out of order at \(b.ms) ms") }
        for b in beats where b.n < 1 || b.n > 4 || b.bpm <= 0 || b.bpm * 100 > Double(UInt16.max) { throw ANLZWriteError.badGrid("beat at \(b.ms) ms") }
        let (header, tags) = try split(file)
        var out = [[UInt8]]()
        for (name, t) in tags {
            if name == "PQTZ" {
                let body = beats.flatMap { be16(UInt16($0.n)) + be16(UInt16(($0.bpm * 100).rounded())) + be32($0.ms) }
                // the two header words rekordbox writes (0, 0x80000) are kept from the file
                out.append(tag("PQTZ", header: Array(t[12..<20]) + be32(UInt32(beats.count)), body: body))
            } else if name == "PQT2" {
                continue
            } else { out.append(t) }
        }
        let result = join(header, out)
        if tags.contains(where: { $0.name == "PQTZ" }) {
            let back = parse(result).beats
            if back != beats.map({ ANLZBeat(n: $0.n, bpm: Double(UInt16(($0.bpm * 100).rounded())) / 100, ms: $0.ms) }) { throw ANLZWriteError.readBack("beat grid didn't read back") }
        }
        let (_, newTags) = try split(result)
        let kept = tags.filter { $0.name != "PQT2" }
        if newTags.map({ $0.name }) != kept.map({ $0.name }) { throw ANLZWriteError.readBack("tag order changed") }
        for (x, y) in zip(kept, newTags) where x.name != "PQTZ" && x.bytes != y.bytes { throw ANLZWriteError.readBack("\(x.name) changed") }
        return result
    }
}
