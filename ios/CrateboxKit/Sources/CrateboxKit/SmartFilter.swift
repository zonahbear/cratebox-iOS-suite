// The filter behind "ask the library" (the app's SmartSearch.swift asks Apple's on-device model to fill it in from
// a sentence). Plain code, so it's tested here; the model's answer goes through `checked` before it's used.
import Foundation

/// A library filter: every part is optional, and the model's answer is checked before it's used.
public struct SmartFilter: Equatable {
    public init() {}
    public var words: [String] = []                 // in the title or artist (any of them)
    public var bpmMin: Double?, bpmMax: Double?
    public var keys: [String] = []                  // Camelot labels, 1A...12B
    public var minMinutes: Double?, maxMinutes: Double?

    public var isEmpty: Bool { words.isEmpty && bpmMin == nil && bpmMax == nil && keys.isEmpty && minMinutes == nil && maxMinutes == nil }
    public func matches(title: String, artist: String, bpm: Double?, key: Int, duration: Double) -> Bool {
        if !words.isEmpty {
            let t = (title + " " + artist).lowercased()
            if !words.contains(where: { t.contains($0.lowercased()) }) { return false }
        }
        if bpmMin != nil || bpmMax != nil {
            guard let b = bpm, b > 0 else { return false }
            if let lo = bpmMin, b < lo - 0.05 { return false }
            if let hi = bpmMax, b > hi + 0.05 { return false }
        }
        if !keys.isEmpty { guard let c = Keys.camelot(key), keys.contains(c.label) else { return false } }
        if let m = minMinutes, duration < m * 60 { return false }
        if let m = maxMinutes, duration > m * 60 { return false }
        return true
    }
    /// shown on the chip above the list, so you can see what the model understood
    public var summary: String {
        var p = [String]()
        if !words.isEmpty { p.append(words.map { "“\($0)”" }.joined(separator: " or ")) }
        switch (bpmMin, bpmMax) {
        case let (a?, b?): p.append(a == b ? "\(fmt(a)) BPM" : "\(fmt(a))–\(fmt(b)) BPM")
        case let (a?, nil): p.append("\(fmt(a))+ BPM")
        case let (nil, b?): p.append("up to \(fmt(b)) BPM")
        default: break
        }
        if !keys.isEmpty { p.append(keys.joined(separator: " ")) }
        if let a = minMinutes { p.append("over \(fmt(a)) min") }
        if let b = maxMinutes { p.append("under \(fmt(b)) min") }
        return p.isEmpty ? "everything" : p.joined(separator: " · ")
    }
    private func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }

    /// The track playing now (the newest one), for "what mixes with this": its tempo ±6 %, and its key with the
    /// keys next to it on the Camelot wheel (same rule as the KEY column's highlight, Keys.mixes).
    public static func mixingWith(bpm: Double, key: Int) -> SmartFilter {
        var f = SmartFilter()
        if bpm > 0 { f.bpmMin = (bpm * 0.94).rounded(); f.bpmMax = (bpm * 1.06).rounded() }
        if key >= 0 { f.keys = (0..<24).filter { Keys.mixes($0, key) }.compactMap { Keys.camelot($0)?.label } }
        return f
    }

    /// The model's raw answer made safe: Camelot labels only, tempos in a DJ range (low and high swapped if
    /// need be), lengths 0-60 minutes; nonsense is dropped, not guessed at.
    public static func checked(words: [String], bpmMin: Double, bpmMax: Double, keys: [String], minMinutes: Double, maxMinutes: Double,
                        fitsPlaying: Bool, playing: (bpm: Double, key: Int)?) -> SmartFilter {
        var f = fitsPlaying ? playing.map { mixingWith(bpm: $0.bpm, key: $0.key) } ?? SmartFilter() : SmartFilter()
        f.words = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 40 }.prefix(5).map { $0 }
        let ok = { (b: Double) in b >= 40 && b <= 250 }
        var lo = ok(bpmMin) ? bpmMin : nil, hi = ok(bpmMax) ? bpmMax : nil
        if let a = lo, let b = hi, a > b { (lo, hi) = (b, a) }
        if lo != nil || hi != nil { f.bpmMin = lo; f.bpmMax = hi }
        let labels = Set((1...12).flatMap { ["\($0)A", "\($0)B"] })
        let ks = keys.map { $0.uppercased().replacingOccurrences(of: " ", with: "") }.filter { labels.contains($0) }
        var seen = Set<String>()
        if !ks.isEmpty { f.keys = ks.filter { seen.insert($0).inserted } }
        if minMinutes > 0 && minMinutes <= 60 { f.minMinutes = minMinutes }
        if maxMinutes > 0 && maxMinutes <= 60 { f.maxMinutes = maxMinutes }
        return f
    }
}

