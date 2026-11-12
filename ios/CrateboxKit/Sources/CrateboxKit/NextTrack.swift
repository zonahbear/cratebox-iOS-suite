// Next-track suggestions (the library's MATCH sort, behind AI mode): scores library tracks against what's playing now on
// tempo (½× / 1× / 2× within the target deck's range, like SYNC's pickMult), key (Camelot moves, after the pitch
// change when master tempo is off), energy flow, sound (low/mid/high split) and genre. Pure functions, any thread.
// A line-by-line port of tools/next_track.js (run `node tools/next_track.js` for the reference checks).
import Foundation

public enum NextTrack {
    /// what's known about a track for matching. bpm/key as heard for the playing track, its own for a candidate
    public struct Item {
        public var id: String, bpm: Double, key: Int
        public var energy: Double?, bands: [Double]?, genre: String?
        /// from Apple's analysis: how much of the track has vocals, drums and bass (each 0...1). Used for "sound"
        /// instead of the waveform's band split when both tracks have it
        public var shares: [Double]?
        public init(id: String, bpm: Double, key: Int, energy: Double? = nil, bands: [Double]? = nil, genre: String? = nil, shares: [Double]? = nil) {
            self.id = id; self.bpm = bpm; self.key = key; self.energy = energy; self.bands = bands; self.genre = genre; self.shares = shares
        }
    }
    public struct Options {
        public var range: Double              // the target deck's ± range in % (100 = WIDE)
        public var keylock: Bool              // the target deck's master tempo
        public var flow: Int                  // energy: -1 drop, 0 hold, +1 build
        public var played: Set<String>        // already played this session
        public init(range: Double, keylock: Bool, flow: Int = 0, played: Set<String> = []) {
            self.range = range; self.keylock = keylock; self.flow = flow; self.played = played
        }
    }
    public struct Fit: Equatable { public let mult: Double, rate: Double, pct: Double }
    public struct Result {
        public let id: String, score: Double, fit: Fit, keyAfter: Int
        public let parts: [String: Double], why: [String]
    }

    public static let weights: [String: Double] = ["tempo": 0.35, "key": 0.3, "energy": 0.15, "sound": 0.12, "genre": 0.08]
    static let order = ["tempo", "key", "energy", "sound", "genre"]

    // ---- key ----
    /// how well key b follows key a, 0...1, and a short name for the move
    public static func keyScore(_ a: Int, _ b: Int) -> (s: Double, why: String) {
        guard let x = Keys.camelot(a), let y = Keys.camelot(b) else { return (0.5, "key ?") }   // unknown: neutral
        let xm = x.letter == "A", ym = y.letter == "A"
        let d = ((y.num - x.num) % 12 + 12) % 12                  // steps clockwise round the wheel
        let step = min(d, 12 - d)
        if xm == ym {
            if d == 0 { return (1, "same key") }
            if step == 1 { return (0.9, d == 1 ? "+1" : "−1") }
            if step == 2 { return (0.6, d == 2 ? "+2" : "−2") }
            if d == 7 { return (0.55, "+1 semitone") }             // the "energy boost" key change
            if d == 5 { return (0.45, "−1 semitone") }
        } else {
            if d == 0 { return (0.85, "relative") }
            // diagonal: minor → major one step up (8A → 9B), major → minor one step down (9B → 8A)
            if (!xm && d == 11) || (xm && d == 1) { return (0.6, "diagonal") }
        }
        return (0.1, "clash")
    }

    // ---- tempo ----
    /// ½× / 1× / 2× of the playing tempo `ref` that the candidate's `bpm` reaches within `range`; nil if none
    public static func tempoFit(_ ref: Double, _ bpm: Double, range: Double) -> Fit? {
        guard ref > 0, bpm > 0 else { return nil }
        let r = ref / bpm
        let mults: [Double] = [1, 0.5, 2]
        let fits = mults.filter { (k: Double) -> Bool in range >= 100 || abs(r * k - 1) <= range / 100 + 1e-9 }
        guard var k = fits.first else { return nil }
        for b in fits.dropFirst() where abs(log(r * b)) < abs(log(r * k)) { k = b }
        return Fit(mult: k, rate: r * k, pct: (r * k - 1) * 100)
    }
    /// 1 at no change, 0 at the comfort edge (the range, never wider than 8% even on WIDE); ½×/2× costs 15%
    public static func tempoScore(_ f: Fit, range: Double) -> Double {
        let comfort = min(range, 8)
        return max(0, 1 - abs(f.pct) / comfort) * (f.mult == 1 ? 1 : 0.85)
    }

    // ---- energy and sound, from the analyser's waveform ----
    /// energy 0...1 (body loudness, 10%-90%, plus bass weight) and the low/mid/high split (sums to 1)
    public static func profile(_ w: Waveform) -> (energy: Double, bands: [Double]) {
        let n = w.rms.count, a = Int(Double(n) * 0.1), b = max(a + 1, Int(Double(n) * 0.9))
        var rms = 0.0, lo = 0.0, mi = 0.0, hi = 0.0
        for i in a..<min(b, n) { rms += Double(w.rms[i]); lo += Double(w.low[i]); mi += Double(w.mid[i]); hi += Double(w.high[i]) }
        let m = Double(b - a), tot = lo + mi + hi > 0 ? lo + mi + hi : 1
        let bands = [lo / tot, mi / tot, hi / tot]
        let energy = min(1, max(0, (rms / m / 255) * 0.75 + bands[0] * 0.25 / 0.5))
        return (energy, bands)
    }
    public static func energyScore(_ now: Double, _ cand: Double, flow: Int) -> Double {
        let want = now + 0.08 * Double(flow)
        return max(0, 1 - abs(cand - want) / 0.4)
    }
    public static func soundScore(_ a: [Double], _ b: [Double]) -> Double {
        1 - 0.5 * (abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]))
    }

    /// 1 when two tracks have the same amount of vocals, drums and bass, 0 when they're opposites
    public static func shareScore(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0.5 }
        var d = 0.0
        for i in 0..<n { d += abs(a[i] - b[i]) }
        return max(0, 1 - d / Double(n))
    }
    /// energy 0...1 from Apple's loudness: -16 LUFS and quieter = 0, -4 and louder = 1 (a first guess, not tuned)
    public static func energy(lufs: Double) -> Double { min(1, max(0, (lufs + 16) / 12)) }

    // ---- score ----
    /// 0-100 with the reasons, or nil when the candidate can't follow on this deck at all (or is the same track)
    public static func score(now: Item, cand: Item, _ o: Options) -> Result? {
        if cand.id == now.id { return nil }
        guard let fit = tempoFit(now.bpm, cand.bpm, range: o.range) else { return nil }
        let keyAfter = o.keylock || cand.key < 0 ? cand.key : Keys.shift(cand.key, Int(jsRound(12 * log2(fit.rate))))
        let k = keyScore(now.key, keyAfter)
        var parts: [String: Double] = ["tempo": tempoScore(fit, range: o.range), "key": k.s]
        if let a = now.energy, let b = cand.energy { parts["energy"] = energyScore(a, b, flow: o.flow) }
        if let a = now.shares, let b = cand.shares, !a.isEmpty, a.count == b.count { parts["sound"] = shareScore(a, b) }
        else if let a = now.bands, let b = cand.bands, a.count == 3, b.count == 3 { parts["sound"] = soundScore(a, b) }
        if let a = now.genre, let b = cand.genre, !a.isEmpty, !b.isEmpty { parts["genre"] = a.lowercased() == b.lowercased() ? 1 : 0 }
        var sum = 0.0, w = 0.0
        for p in order { if let v = parts[p], let wt = weights[p] { sum += v * wt; w += wt } }
        var s = sum / w * 100
        if k.why == "clash" { s *= 0.6 }                          // a known clash shouldn't outrank a harmonic move
        if o.played.contains(cand.id) { s *= 0.3 }               // played this session: sinks, still findable
        var why = [(fit.mult == 0.5 ? "½× " : fit.mult == 2 ? "2× " : "") + String(format: "%@%.1f%%", fit.pct >= 0 ? "+" : "", fit.pct),
                   k.why + (keyAfter != cand.key ? " (pitched)" : "")]
        if parts["energy"] != nil, let a = now.energy, let b = cand.energy {
            let d = b - a
            why.append(abs(d) < 0.04 ? "energy =" : d > 0 ? "energy ↑" : "energy ↓")
        }
        return Result(id: cand.id, score: s, fit: fit, keyAfter: keyAfter, parts: parts, why: why)
    }
    /// best first; ties keep the library's order
    public static func suggest(now: Item, _ tracks: [Item], _ o: Options, limit: Int? = nil) -> [Result] {
        let scored = tracks.compactMap { score(now: now, cand: $0, o) }.enumerated()
        let sorted = scored.sorted { a, b in a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset }.map { $0.element }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }
}
