// rekordbox analysis files on a stick (ANLZ .DAT / .EXT): beat grid, hot and memory cues, rekordbox's own
// phrase analysis. A port of RB.parseAnlz / gridFromBeats / phrasesFrom (tools/rekordbox.js). Big-endian.
import Foundation

public struct ANLZBeat: Equatable { public var n: Int; public var bpm: Double; public var ms: UInt32 }
public struct ANLZCue: Equatable { public var hot: Int; public var ms: UInt32; public var loopMs: UInt32? }
public struct ANLZ {
    public var beats: [ANLZBeat] = [], hot: [ANLZCue] = [], memory: [ANLZCue] = []
    public var phrases: (mood: Int, endBeat: Int, list: [(beat: Int, kind: Int)])?
}

public enum RekordboxANLZ {
    public static func parse(_ b: [UInt8]) -> ANLZ {
        var out = ANLZ()
        func u32(_ o: Int) -> UInt32 { o + 4 <= b.count ? UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) : 0 }
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        func tag(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        guard b.count >= 12, u32(0) == tag("PMAI") else { return out }
        var pos = Int(u32(4))
        var cues2Hot = [ANLZCue](), cues2Mem = [ANLZCue]()
        while pos + 12 <= b.count {
            let four = u32(pos), lenTag = Int(u32(pos + 8)), s = pos + 12
            if lenTag < 12 { break }
            if four == tag("PQTZ") {
                let n = Int(u32(s + 8))
                for i in 0..<n { let e = s + 12 + i * 8; if e + 8 > b.count { break }; out.beats.append(ANLZBeat(n: u16(e), bpm: Double(u16(e + 2)) / 100, ms: u32(e + 4))) }
            } else if four == tag("PCOB") || four == tag("PCO2") {
                let ob = four == tag("PCOB")
                let n = u16(s + (ob ? 6 : 4))
                var e = s + (ob ? 12 : 8)
                var i = 0
                while i < n && e + 12 <= pos + lenTag && e + 40 <= b.count {
                    let lenEntry = Int(u32(e + 8)), hot = Int(u32(e + 12))
                    let typ = Int(b[e + (ob ? 28 : 16)])
                    let ms = u32(e + (ob ? 32 : 20)), loopMs = u32(e + (ob ? 36 : 24))
                    let cue = ANLZCue(hot: hot, ms: ms, loopMs: typ == 2 ? loopMs : nil)
                    if ob { if hot != 0 { out.hot.append(cue) } else { out.memory.append(cue) } }
                    else { if hot != 0 { cues2Hot.append(cue) } else { cues2Mem.append(cue) } }
                    e += lenEntry != 0 ? lenEntry : 56; i += 1
                }
            } else if four == tag("PSSI") {
                let lenEntries = u16(s + 4), bodyLen = lenTag - 12 - 6
                if s + 6 + bodyLen <= b.count && bodyLen >= 14 {
                    var body = Array(b[(s + 6)..<(s + 6 + bodyLen)])
                    let raw = Int(body[0]) << 8 | Int(body[1])
                    if raw > 20 {
                        let m: [Int] = [0xcb, 0xe1, 0xee, 0xfa, 0xe5, 0xee, 0xad, 0xee, 0xe9, 0xd2, 0xe9, 0xeb, 0xe1, 0xe9, 0xf3, 0xe8, 0xe9, 0xf4, 0xe1]
                        for i in body.indices { body[i] ^= UInt8((m[i % m.count] + lenEntries) & 0xff) }
                    }
                    func bu16(_ o: Int) -> Int { o + 2 <= body.count ? Int(body[o]) << 8 | Int(body[o + 1]) : 0 }
                    var list = [(beat: Int, kind: Int)]()
                    for i in 0..<lenEntries { let e = 14 + i * 24; if e + 6 > body.count { break }; list.append((bu16(e + 2), bu16(e + 4))) }
                    out.phrases = (bu16(0), bu16(8), list)
                }
            }
            pos += lenTag
        }
        // the extended (.EXT) cue lists hold all eight hot cues: prefer them when present
        if !cues2Hot.isEmpty { out.hot = cues2Hot }
        if !cues2Mem.isEmpty { out.memory = cues2Mem }
        return out
    }
    public static func phraseLabel(_ mood: Int, _ kind: Int) -> String {
        if mood == 1 { return [1: "Intro", 2: "Build", 3: "Breakdown", 5: "Drop", 6: "Outro"][kind] ?? "Groove" }
        return [1: "Intro", 8: "Breakdown", 9: "Drop", 10: "Outro"][kind] ?? "Groove"
    }
    /// constant tempo: the most common BPM and the first downbeat
    public static func grid(_ beats: [ANLZBeat]) -> (bpm: Double, firstBeat: Double)? {
        guard beats.count >= 2 else { return nil }
        var count = [Double: Int](), order = [Double]()
        for b in beats { if count[b.bpm] == nil { order.append(b.bpm) }; count[b.bpm, default: 0] += 1 }
        let bpm = order.stableSorted { count[$0]! > count[$1]! }[0]
        let down = beats.first { $0.n == 1 } ?? beats[0]
        return (bpm, Double(down.ms) / 1000)
    }
    public static func phrases(_ a: ANLZ) -> [Phrase]? {
        guard let p = a.phrases, !p.list.isEmpty, !a.beats.isEmpty else { return nil }
        let at = { (beat: Int) in Double(a.beats[max(0, min(a.beats.count - 1, beat - 1))].ms) / 1000 }
        return p.list.enumerated().map { i, e in
            let next = i + 1 < p.list.count ? p.list[i + 1].beat : (p.endBeat != 0 ? p.endBeat : e.beat + 32)
            return Phrase(start: at(e.beat), bars: max(1, Int(jsRound(Double(next - e.beat) / 4))), label: phraseLabel(p.mood, e.kind))
        }
    }
    /// rekordbox hot cues A-H and the first memory cue, in seconds
    public static func cues(_ a: ANLZ) -> (cue: Double?, hot: [Double?]) {
        var hot = [Double?](repeating: nil, count: 8)
        for q in a.hot where q.hot >= 1 && q.hot <= 8 { hot[q.hot - 1] = Double(q.ms) / 1000 }
        let mem = a.memory.min { $0.ms < $1.ms }
        return (mem.map { Double($0.ms) / 1000 }, hot)
    }
    public static func keyIndex(_ s: String) -> Int {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return -1 }
        if let m = t.range(of: "^(\\d{1,2})\\s*([ABab])$", options: .regularExpression) {
            let str = String(t[m]), num = Int(str.prefix { $0.isNumber }) ?? 0, minor = str.last!.uppercased() == "A"
            for k in 0..<24 { if let c = Keys.camelot(k), c.num == num, (c.letter == "A") == minor { return k } }
            return -1
        }
        var u = t.replacingOccurrences(of: "maj(or)?$", with: "", options: [.regularExpression, .caseInsensitive])
        let minor = u.range(of: "(m|min|minor)$", options: [.regularExpression, .caseInsensitive]) != nil
        u = u.replacingOccurrences(of: "(m|min|minor)$", with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        guard let first = u.first, var pc = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first).uppercased()] else { return -1 }
        let acc = u.dropFirst()
        if acc == "#" || acc == "♯" { pc += 1 } else if acc == "b" || acc == "♭" { pc -= 1 } else if !acc.isEmpty { return -1 }
        return (minor ? 12 : 0) + (pc + 12) % 12
    }
}
