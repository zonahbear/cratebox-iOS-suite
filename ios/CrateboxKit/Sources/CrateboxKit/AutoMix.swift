// AI DJ (the suite's AI DJ mode, behind AI mode): the decisions, as pure functions on any thread. The app's AIDJ
// controller (App/AIDJ/AIDJ.swift) runs them on decks 1 and 2: which track goes next, where the transition starts in
// the playing track and where the next one comes in, how the faders, bass EQs and tempo move over it, and how much
// trim makes the two equally loud.
//
// - Picks: key (Camelot moves; master tempo stays on, so the key doesn't move with the tempo), energy flow, sound
//   (Apple's vocal / drum / bass shares), how cleanly the two can overlap without vocals on top of each other, and
//   tempo. Tempo is a gate (at most `maxShift`, ½× and 2× counted) and only a mild preference beyond ±4 %, so the
//   set isn't stuck at one BPM: the tempo glides to each new track's own over the transition.
// - Plans: the transition starts on a phrase line (every 8 bars from bar 1) of the playing track and the next track
//   comes in on one of its own, chosen so the vocals Apple found don't overlap where both are heard.
// - Transitions: `Transition` is the list of kinds; for now the 32-bar bass swap. A new kind adds a case and its
//   levels, and the planner and the app pick it up.
// - Loudness: ITU-R BS.1770 integrated loudness (K-weighting, 400 ms blocks, absolute and relative gates) of the
//   deck's analysis audio, and the trim that brings a track to the target.
import Foundation

public enum AutoMix {
    /// what the AI DJ knows about a track. Times are in seconds, beats count from bar 1's first beat (beat 0)
    public struct Track {
        public var id: String
        public var bpm: Double, firstBeat: Double, duration: Double
        public var key: Int
        /// where Apple heard vocals and drums (nil: not analysed, so overlaps can't be checked)
        public var vocals: [AppleFeatures.Span]?, drums: [AppleFeatures.Span]?
        /// 0...1 from Apple's loudness and drums (nil: unknown)
        public var energy: Double?
        /// share of the track with vocals, drums, bass (Apple)
        public var shares: [Double]?
        public init(id: String, bpm: Double, firstBeat: Double, duration: Double, key: Int) {
            self.id = id; self.bpm = bpm; self.firstBeat = firstBeat; self.duration = duration; self.key = key
        }
        /// with Apple's results, when there are some
        public init(id: String, bpm: Double, firstBeat: Double, duration: Double, key: Int, features f: AppleFeatures?) {
            self.init(id: id, bpm: bpm, firstBeat: firstBeat, duration: duration, key: key)
            guard let f else { return }
            if !f.present.isEmpty { vocals = f.present["vocal"] ?? []; drums = f.present["drum"] ?? [] }
            shares = f.shares
            energy = AutoMix.energy(lufs: f.lufs, drumShare: shares?[1])
        }
        public func time(ofBeat b: Double) -> Double { firstBeat + b * 60 / bpm }
        public func beat(at t: Double) -> Double { (t - firstBeat) * bpm / 60 }
        /// the last whole beat before the end
        public var lastBeat: Double { (beat(at: duration - 0.25)).rounded(.down) }
    }

    /// energy 0...1: loudness (NextTrack's mapping, untuned) with the drums' share; nil when neither is known
    public static func energy(lufs: Double?, drumShare: Double?) -> Double? {
        switch (lufs, drumShare) {
        case let (l?, d?): return 0.7 * NextTrack.energy(lufs: l) + 0.3 * d
        case let (l?, nil): return NextTrack.energy(lufs: l)
        case let (nil, d?): return d
        default: return nil
        }
    }

    // ---- transitions ----

    /// The kinds of transition. Only the bass swap for now; more go here (each with its own levels and length)
    public enum Transition: String, CaseIterable, Codable {
        /// the next track comes in with its bass cut, the basses swap halfway on a downbeat, the old track goes out
        case bassSwap
        public var name: String {
            switch self {
            case .bassSwap: return "Bass swap"
            }
        }
        /// its usual length in bars (shorter ones are used only when there isn't room)
        public var bars: Int {
            switch self {
            case .bassSwap: return 32
            }
        }
        /// faders and LOW EQs (mixer values: fader 0...1, EQ 0.5 = centre, 0 = cut) at `x` bars into a transition
        /// `n` bars long
        public func levels(atBar x: Double, of n: Int) -> Levels {
            let n = Double(max(1, n)), x = min(max(0, x), n)
            switch self {
            case .bassSwap:
                // in: the fader up over the first quarter, its bass cut. Halfway: the basses swap over one beat.
                // out: the fader down over the last quarter
                let swap = n / 2, swapLen = 0.25
                let s = min(1, max(0, (x - swap) / swapLen))
                return Levels(outFader: 1 - ramp(x, 0.75 * n, n), outLow: 0.5 * (1 - s),
                              inFader: ramp(x, 0, 0.25 * n), inLow: 0.5 * s)
            }
        }
        /// the bar where the basses swap (shown on the screen)
        public func swapBar(of n: Int) -> Double {
            switch self {
            case .bassSwap: return Double(n) / 2
            }
        }
    }
    public struct Levels: Equatable {
        public var outFader: Double, outLow: Double, inFader: Double, inLow: Double
    }
    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double { b <= a ? (x >= b ? 1 : 0) : min(1, max(0, (x - a) / (b - a))) }
    /// 0...1 eased in and out
    public static func smooth(_ p: Double) -> Double { let q = min(1, max(0, p)); return q * q * (3 - 2 * q) }

    /// the playing track's speed (rate) `x` bars into the transition: from where it was to the rate that leaves the
    /// next track at its own tempo, eased
    public static func rate(atBar x: Double, _ p: Plan) -> Double {
        p.fromRate + (p.toRate - p.fromRate) * smooth(x / Double(max(1, p.bars)))
    }

    // ---- plans ----

    public struct Plan: Equatable {
        /// beat of the playing track (from its bar 1) where the transition starts; beat of the next one it starts from
        public var outStart: Double, inStart: Double
        public var bars: Int
        public var kind: Transition
        /// the next track runs at `mult` × the playing track's beats (½, 1 or 2: half or double time)
        public var mult: Double
        /// the playing track's rate when the transition starts and when it ends (the next track is then at its own tempo)
        public var fromRate: Double, toRate: Double
        /// seconds where both tracks' vocals are heard, weighted by how loud each is; nil when either wasn't analysed
        public var clash: Double?
        public var outEnd: Double { outStart + Double(bars * 4) }
        /// the tempo change over the transition, in %
        public var tempoChange: Double { (toRate / fromRate - 1) * 100 }
    }

    /// is time t inside one of the spans
    static func on(_ spans: [AppleFeatures.Span], _ t: Double) -> Bool {
        for s in spans where t >= s.start && t < s.end { return true }
        return false
    }

    /// The transition from `a` (playing at `aRate`, its playhead not before beat `after`) to `b`. Starts on a line
    /// every `step` beats from a's bar 1 (32 = 8-bar phrases; 4 = the next bar, for "mix now"), brings b in on one
    /// of its own 8-bar phrases in its first 64 bars, and picks the pair with the least vocal overlap, then the one
    /// that plays more of a and starts b nearer its top. Falls back to shorter transitions (16, 8, 4 bars) when a
    /// hasn't room left; nil when even that won't fit, or the tempos can't meet within ±`maxShift`.
    public static func plan(from a: Track, aRate: Double, to b: Track, after: Double, step: Double = 32,
                            kind: Transition = .bassSwap, maxShift: Double = 0.12) -> Plan? {
        guard a.bpm > 0, b.bpm > 0, aRate > 0, let fit = NextTrack.tempoFit(a.bpm * aRate, b.bpm, range: 100) else { return nil }
        let k = fit.mult
        let toRate = b.bpm / (k * a.bpm)
        guard abs(toRate / aRate - 1) <= maxShift + 1e-9 else { return nil }
        let last = a.lastBeat, lastB = b.lastBeat
        let st = max(1, step)
        for bars in [kind.bars, 16, 8, 4] where bars <= kind.bars {
            let len = Double(bars * 4)
            // a's starts: lines at or after `after`, ending before a does
            var starts = [Double]()
            var s = (max(0, after) / st).rounded(.up) * st
            while s + len <= last { starts.append(s); s += st }
            guard !starts.isEmpty else { continue }
            // b's starts: its 8-bar phrase lines over its first 64 bars, leaving the transition room in b
            var ins = [Double]()
            var u = 0.0
            while u <= 256 && u + len * k <= lastB { ins.append(u); u += 32 }
            guard !ins.isEmpty else { continue }
            var best: (cost: Double, plan: Plan)?
            for s in starts {
                for u in ins {
                    let c = clash(a, s, b, u, bars: bars, mult: k, kind: kind, rate: aRate)
                    // a little for every bar of a left unplayed after the transition, and for every phrase of b skipped
                    let left = max(0, (last - (s + len)) / 4)
                    let cost = (c ?? 0) * 4 + left * 0.05 + (u / 32) * 0.6
                    if best == nil || cost < best!.cost - 1e-9 {
                        best = (cost, Plan(outStart: s, inStart: u, bars: bars, kind: kind, mult: k, fromRate: aRate, toRate: toRate, clash: c))
                    }
                }
            }
            if let best { return best.plan }
        }
        return nil
    }

    /// seconds of vocal on vocal over a transition (each beat counted at the quieter of the two levels); nil if
    /// either track's vocals are unknown
    public static func clash(_ a: Track, _ s: Double, _ b: Track, _ u: Double, bars: Int, mult: Double, kind: Transition, rate: Double) -> Double? {
        guard let va = a.vocals, let vb = b.vocals else { return nil }
        let beats = bars * 4, spb = 60 / (a.bpm * max(0.01, rate))
        var sum = 0.0
        for x in 0..<beats {
            let xd = Double(x) + 0.5
            let ta = a.time(ofBeat: s + xd), tb = b.time(ofBeat: u + xd * mult)
            guard on(va, ta), on(vb, tb) else { continue }
            let l = kind.levels(atBar: xd / 4, of: bars)
            sum += min(l.outFader, l.inFader) * spb
        }
        return sum
    }

    // ---- picks ----

    public struct Choice {
        public let track: Track
        public let score: Double
        public let plan: Plan?
        /// "+2.4%", "+1", "energy ↑", "no vocal overlap" …
        public let why: [String]
    }
    public struct PickOptions {
        /// the most the tempo may glide over one transition (0.10 = 10 %)
        public var maxShift = 0.10
        /// energy: -1 cool down, 0 hold, +1 build
        public var flow = 0
        public var played: Set<String> = []
        /// where the playing track's next transition could start at the earliest (its beat)
        public var after = 0.0
        public init() {}
    }
    static let weights: [String: Double] = ["key": 0.35, "tempo": 0.15, "energy": 0.2, "sound": 0.1, "mix": 0.2]

    /// tempo: no preference within ±4 %, then down to 0.2 at the limit; ½× / 2× costs 15 %
    static func tempoScore(shift: Double, mult: Double, max m: Double) -> Double {
        let s = abs(shift)
        let v = s <= 0.04 ? 1 : max(0.2, 1 - 0.8 * (s - 0.04) / max(1e-9, m - 0.04))
        return v * (mult == 1 ? 1 : 0.85)
    }

    /// The tracks that can follow `a` (playing at `aRate`), best first. Scored in two rounds: everything on key,
    /// tempo, energy and sound; then the best `deep` again with their full details (`detail`, e.g. Apple's vocals,
    /// read from disk only for these) and a planned transition, whose vocal overlap counts too.
    public static func choose(after a: Track, aRate: Double, pool: [Track], _ o: PickOptions,
                              deep: Int = 12, detail: (String) -> Track? = { _ in nil }) -> [Choice] {
        let aEff = a.bpm * aRate
        var first = [(Track, Double, Double, [String: Double])]()       // track, score, shift, parts
        for t in pool where t.id != a.id && !o.played.contains(t.id) && t.bpm > 0 {
            guard let fit = NextTrack.tempoFit(aEff, t.bpm, range: 100) else { continue }
            let shift = t.bpm / (fit.mult * aEff) - 1
            guard abs(shift) <= o.maxShift + 1e-9 else { continue }
            var parts: [String: Double] = ["tempo": tempoScore(shift: shift, mult: fit.mult, max: o.maxShift),
                                           "key": NextTrack.keyScore(a.key, t.key).s]
            if let x = a.energy, let y = t.energy { parts["energy"] = NextTrack.energyScore(x, y, flow: o.flow) }
            if let x = a.shares, let y = t.shares, x.count == y.count, !x.isEmpty { parts["sound"] = NextTrack.shareScore(x, y) }
            first.append((t, total(parts), shift, parts))
        }
        first.sort { $0.1 > $1.1 }
        var out = [Choice]()
        for (i, c) in first.enumerated() {
            var t = c.0, parts = c.3
            var plan: Plan?
            if i < deep {
                if let d = detail(t.id) { t = d }
                plan = AutoMix.plan(from: a, aRate: aRate, to: t, after: o.after, maxShift: o.maxShift + 0.02)
                if let p = plan, let cl = p.clash { parts["mix"] = max(0, 1 - cl / 8) }
                if plan == nil { parts["mix"] = 0 }
            }
            var why = [String(format: "%@%.1f%%", c.2 >= 0 ? "+" : "", c.2 * 100)]
            if let fit = NextTrack.tempoFit(aEff, t.bpm, range: 100), fit.mult != 1 { why[0] = (fit.mult == 0.5 ? "½× " : "2× ") + why[0] }
            why.append(NextTrack.keyScore(a.key, t.key).why)
            if let x = a.energy, let y = t.energy { why.append(abs(y - x) < 0.04 ? "energy =" : y > x ? "energy ↑" : "energy ↓") }
            if let p = plan {
                if let cl = p.clash { why.append(cl < 0.5 ? "no vocal overlap" : String(format: "vocals overlap %.0f s", cl)) }
                else { why.append("vocals unknown") }
            }
            out.append(Choice(track: t, score: total(parts) * 100, plan: plan, why: why))
        }
        // the planned ones were scored again: best first, ties in the first round's order
        return out.enumerated().sorted { x, y in
            abs(x.element.score - y.element.score) > 1e-9 ? x.element.score > y.element.score : x.offset < y.offset
        }.map { $0.element }
    }
    static func total(_ parts: [String: Double]) -> Double {
        var s = 0.0, w = 0.0
        for (k, v) in parts { if let wt = weights[k] { s += v * wt; w += wt } }
        var r = w > 0 ? s / w : 0
        if (parts["key"] ?? 1) <= 0.1 { r *= 0.6 }            // a key clash shouldn't outrank a harmonic move
        if let m = parts["mix"], m == 0 { r *= 0.5 }        // no room for a transition
        return r
    }
}

/// Loudness: ITU-R BS.1770-4 integrated loudness, and the trim that matches tracks to a target.
public enum Loudness {
    /// integrated loudness (LUFS) of one channel of audio at `fs`; nil for silence or under 0.4 s.
    /// K-weighting from the standard's two filters, worked out for any sample rate (as libebur128 does), so the
    /// app's 11 025 Hz analysis audio can be measured. One channel: a stereo track with both sides alike reads
    /// 3 dB louder than its mono mix, which `stereoOffset` adds back.
    public static func integrated(_ x: [Float], fs: Double) -> Double? {
        guard fs > 0, x.count >= Int(0.4 * fs) else { return nil }
        // stage 1: high shelf (+4 dB above ~1.7 kHz)
        var (b, a) = shelf(fs)
        var y = biquad(x, b, a)
        // stage 2: high pass (~38 Hz)
        (b, a) = highpass(fs)
        y = biquad(y, b, a)
        // mean square per 100 ms, then 400 ms blocks overlapping by 75 %
        let hop = max(1, Int((0.1 * fs).rounded()))
        let nHop = y.count / hop
        guard nHop >= 4 else { return nil }
        var sq = [Double](repeating: 0, count: nHop)
        for h in 0..<nHop {
            var s = 0.0
            let base = h * hop
            for i in base..<(base + hop) { let v = Double(y[i]); s += v * v }
            sq[h] = s
        }
        var blocks = [Double]()
        blocks.reserveCapacity(nHop)
        for j in 0...(nHop - 4) { blocks.append((sq[j] + sq[j + 1] + sq[j + 2] + sq[j + 3]) / Double(4 * hop)) }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let heard = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !heard.isEmpty else { return nil }
        let rel = lufs(heard.reduce(0, +) / Double(heard.count)) - 10
        let gated = heard.filter { lufs($0) > rel }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
    /// what a one-channel (mono mix) measurement adds to read like a stereo track's: two equal channels = +3.01 dB
    public static let stereoOffset = 10 * log10(2.0)
    /// the highest sample (dBFS), for keeping a boost under the limiter
    public static func peakDb(_ x: [Float]) -> Double? {
        var m: Float = 0
        for v in x { m = max(m, abs(v)) }
        return m > 0 ? 20 * log10(Double(m)) : nil
    }

    static func shelf(_ fs: Double) -> ([Double], [Double]) {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return ([(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
                [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
    }
    static func highpass(_ fs: Double) -> ([Double], [Double]) {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        return ([1, -2, 1], [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
    }
    static func biquad(_ x: [Float], _ b: [Double], _ a: [Double]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let x0 = Double(x[i])
            let y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            y[i] = Float(y0)
        }
        return y
    }

    /// the gain (dB) that brings a track at `lufs` to `target`: at most `maxBoost` up (and never so far that its
    /// peak goes over +1 dBFS into the limiter) and `maxCut` down
    public static func gainDb(lufs: Double, peakDb: Double?, target: Double = -9, maxBoost: Double = 6, maxCut: Double = 12) -> Double {
        var g = target - lufs
        if let p = peakDb { g = min(g, max(0, 1 - p)) }
        return min(maxBoost, max(-maxCut, g))
    }
    /// the mixer's TRIM knob (0...1, 0.5 = 0 dB) for a gain in dB: the inverse of MixerCurves.trimGain
    public static func trimValue(db: Double) -> Double {
        let d = min(9, max(-24, db))
        return d >= 0 ? 0.5 + d / 18 : (d + 24) / 48
    }
}
