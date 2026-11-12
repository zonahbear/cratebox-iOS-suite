// Apple's Music Understanding results (iOS 27+), kept in Cratebox's own Codable form so the rest of the app, the
// stored files and the tests don't need the framework or the iOS 27 SDK: the app's adapter
// (App/AppleMusic.swift) fills this in from a MusicUnderstandingSession. These sit BESIDE Cratebox's own analysis,
// rekordbox's grids and the user's grid edits; nothing here replaces them. GridCompare measures how far apart
// Apple's beats and bars are from a grid we already trust, so the two can be judged on real tracks.
import Foundation

public struct AppleFeatures: Codable, Equatable {
    /// bump when what's stored (or how it's read from the framework) changes: older files are analysed again
    public static let VER = 1
    public var ver = AppleFeatures.VER
    /// the file this came from, so a replaced file (same name, new content) isn't matched with old results
    public var size: Int64 = 0, mtime: Double = 0
    public var analysedAt: Double = 0, os = "", seconds = 0.0      // when, on which iOS, and how long it took
    // rhythm
    public var bpm: Double?
    public var beats: [Double] = [], bars: [Double] = []          // seconds; bars = the first beat of each bar
    // key over time: our key numbers (0-11 major C...B, 12-23 minor, as Keys), with their time ranges
    public var keys: [Span] = []
    // structure: Apple's three levels (sections ≈ intro/verse/chorus, segments, phrases)
    public var sections: [Span] = [], segments: [Span] = [], phrases: [Span] = []
    /// how fast the music feels (Apple: an events-per-minute rate), per range: an energy measure, not the BPM
    public var pace: [Span] = []
    /// where each instrument is heard (vocal, drum, bass, other) and how strongly, 0...1, at most two values a second
    public var present: [String: [Span]] = [:]
    public var activity: [String: [Float]] = [:], activityStep = 0.5
    // loudness (LUFS; peak in dB), short-term LUFS once a second
    public var lufs: Double?, peakDb: Double?
    public var shortTerm: [Float] = []

    public struct Span: Codable, Equatable {
        public var start: Double, end: Double, value: Double
        public init(_ start: Double, _ end: Double, _ value: Double = 0) { self.start = start; self.end = end; self.value = value }
    }
    public init() {}

    /// the key heard for longest (−1 if Apple found none)
    public var key: Int {
        var total = [Int: Double]()
        for s in keys where s.value >= 0 { total[Int(s.value), default: 0] += s.end - s.start }
        return total.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? -1
    }
    /// share of the track (0...1) where an instrument is heard; nil when Apple didn't report it
    public func share(_ instrument: String, duration: Double) -> Double? {
        guard let r = present[instrument], duration > 0 else { return nil }
        return min(1, r.reduce(0) { $0 + max(0, $1.end - $1.start) } / duration)
    }
    /// how long the analysed audio was, as near as the results say (the activity series covers all of it)
    public var length: Double { max(Double(activity.values.map { $0.count }.max() ?? 0) * activityStep, beats.last ?? 0) }
    /// share of the track with vocals, drums and bass, for comparing two tracks' sound; nil when Apple reported none
    public var shares: [Double]? {
        let d = length
        guard d > 0, !present.isEmpty else { return nil }
        return ["vocal", "drum", "bass"].map { share($0, duration: d) ?? 0 }
    }
    /// Apple's tempo, or the median beat spacing's if it gave none
    public var tempo: Double? {
        if let bpm, bpm > 0 { return bpm }
        guard beats.count > 2 else { return nil }
        let d = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let m = d[d.count / 2]
        return m > 0 ? 60 / m : nil
    }

    /// averages a dense series of (time, value) into fixed steps, so a whole track's activity stays small on disk
    public static func bin(_ pts: [(Double, Float)], step: Double, duration: Double) -> [Float] {
        guard step > 0, duration > 0 else { return [] }
        let n = Int((duration / step).rounded(.up))
        var sum = [Float](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
        for (t, v) in pts where t >= 0 {
            let i = min(n - 1, Int(t / step))
            sum[i] += v; cnt[i] += 1
        }
        // a step with no value of its own keeps the last one (Apple's series can be sparser than the step)
        var out = [Float](repeating: 0, count: n), last: Float = 0
        for i in 0..<n { if cnt[i] > 0 { last = sum[i] / Float(cnt[i]) }; out[i] = last }
        return out
    }
}

extension AppleFeatures {
    /// A beat grid (BPM + bar 1's first beat) from Apple's beats and bars, for a track whose tempo holds steady;
    /// nil when there are too few beats or they don't sit on one even grid (a live recording, a tempo change).
    /// Apple often counts half time (70 for 140) and sometimes double: `near` (the BPM we already have, if any)
    /// says which octave to use; without it the tempo is folded into `range` (Settings → Decks → BPM range).
    public func grid(near ref: Double? = nil, range: (Double, Double) = (80, 160)) -> (bpm: Double, firstBeat: Double)? {
        guard beats.count >= 16 else { return nil }
        let d = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let p0 = d[d.count / 2]
        guard p0 > 0.15, p0 < 3 else { return nil }
        // each beat's place on an even grid, then the straight line through them (least squares)
        // (counted from one beat to the next, so a rough first guess of the spacing can't drift over a whole track,
        // and a beat Apple missed leaves a gap of two)
        var k = [0.0]
        for i in 1..<beats.count { k.append(k[i - 1] + max(1, ((beats[i] - beats[i - 1]) / p0).rounded())) }
        let n = Double(beats.count)
        let mk = k.reduce(0, +) / n, mt = beats.reduce(0, +) / n
        var skk = 0.0, skt = 0.0
        for i in beats.indices { skk += (k[i] - mk) * (k[i] - mk); skt += (k[i] - mk) * (beats[i] - mt) }
        guard skk > 0 else { return nil }
        let p = skt / skk, a = mt - p * mk
        guard p > 0 else { return nil }
        // steady enough? at least 85% of the beats within 6% of a beat of the line
        var good = 0
        for i in beats.indices where abs(beats[i] - (a + p * k[i])) < 0.06 * p { good += 1 }
        guard Double(good) >= 0.85 * n else { return nil }
        var bpm = 60 / p
        // the octave
        if let ref, ref > 0 {
            var best = 1.0
            for m in [0.5, 2.0] where abs(log(bpm * m / ref)) < abs(log(bpm * best / ref)) { best = m }
            bpm *= best
        } else {
            let lo = max(30, range.0), hi = max(lo * 1.5, range.1)
            while bpm < lo { bpm *= 2 }
            while bpm > hi { bpm /= 2 }
        }
        if abs(bpm - bpm.rounded()) < 0.01 { bpm = bpm.rounded() }      // 139.997 is 140
        // bar 1: where Apple's bars start on its own beats (0-3), by majority; then the first such beat, pulled
        // back to the first bar line at or after 0
        var votes = [0, 0, 0, 0]
        for b in bars { let i = Int(((b - a) / p).rounded()); votes[((i % 4) + 4) % 4] += 1 }
        let shift = bars.isEmpty ? 0 : votes.indices.max { votes[$0] != votes[$1] ? votes[$0] < votes[$1] : $0 > $1 }!
        let anchor = a + p * Double(shift)
        let bar = 4 * 60 / bpm
        let first = anchor - (anchor / bar).rounded(.down) * bar
        return (bpm, first)
    }
}

/// Where to bring a track in and where to start taking it out, from Apple's drums and vocals, on the bar lines of
/// the grid the deck uses. Suggestions only: nothing is cued, looped or moved.
public enum MixPoints {
    public struct Result: Equatable {
        /// mix in: the first phrase with drums and no vocals over it. mix out: the start of the last stretch
        /// without vocals. Seconds; nil when Apple's results don't say
        public var mixIn: Double?, mixOut: Double?
        /// how long the clean stretch after `mixIn` and from `mixOut` is, in bars (8, 16 or 32; 0 = a cut)
        public var inBars = 0, outBars = 0
        public init() {}
    }
    /// share of [a, b) covered by the spans
    static func cover(_ spans: [AppleFeatures.Span]?, _ a: Double, _ b: Double) -> Double {
        guard let spans, b > a else { return 0 }
        var s = 0.0
        for x in spans { s += max(0, min(b, x.end) - max(a, x.start)) }
        return min(1, s / (b - a))
    }
    static func blend(_ bars: Int) -> Int { bars >= 32 ? 32 : bars >= 16 ? 16 : bars >= 8 ? 8 : 0 }

    public static func suggest(_ f: AppleFeatures, bpm: Double, firstBeat: Double, duration: Double) -> Result {
        var r = Result()
        guard bpm > 0, duration > 30 else { return r }
        let drums = f.present["drum"], vocals = f.present["vocal"]
        guard drums != nil || vocals != nil else { return r }
        let bar = 4 * 60 / bpm, step = 8 * bar                   // phrases of 8 bars from bar 1
        var lines = [Double](), t = firstBeat
        while t < duration - bar { lines.append(t); t += step }
        guard lines.count >= 4 else { return r }
        // in: the first phrase in the first half with drums most of the time and next to no vocals
        func clean(_ a: Double, needDrums: Bool) -> Bool {
            cover(vocals, a, a + step) <= 0.2 && (!needDrums || drums == nil || cover(drums, a, a + step) >= 0.6)
        }
        let firstHalf = lines.filter { $0 < duration * 0.5 }
        if let i = firstHalf.firstIndex(where: { clean($0, needDrums: true) }) {
            r.mixIn = lines[i]
            var n = 1
            while i + n < lines.count, n < 4, clean(lines[i + n], needDrums: false) { n += 1 }
            r.inBars = blend(n * 8)
        }
        // out: walk back from the end over phrases without vocals (the last line may be a short tail)
        var j = lines.count - 1, n = 0
        while j > lines.count / 2, cover(vocals, lines[j], min(duration, lines[j] + step)) <= 0.2 { j -= 1; n += 1 }
        if n > 0 {
            let start = lines.count - min(n, 4)
            r.mixOut = lines[start]
            r.outBars = blend(Int(((duration - lines[start]) / bar).rounded(.down)))
        }
        return r
    }
}

/// How Apple's beats and bars sit against a grid Cratebox already has (its own, rekordbox's or a hand-fixed one).
/// Assumes 4/4, as the rest of the app does.
public enum GridCompare {
    /// a grid: BPM + where bar 1's first beat is, or rekordbox's beat-by-beat list (`beats`, bar 1 at `beat0`)
    public struct Grid {
        public var bpm: Double, firstBeat: Double
        public var beats: [Double]? = nil, beat0 = 0
        public init(bpm: Double, firstBeat: Double, beats: [Double]? = nil, beat0: Int = 0) {
            self.bpm = bpm; self.firstBeat = firstBeat; self.beats = beats; self.beat0 = beat0
        }
        /// where time t falls on the grid, in beats from bar 1's first beat (fractional)
        public func position(_ t: Double) -> Double {
            if let b = beats, b.count > 1 {
                var lo = 0, hi = b.count - 1
                if t <= b[0] { return Double(-beat0) + (t - b[0]) / (b[1] - b[0]) }
                if t >= b[hi] { return Double(hi - beat0) + (t - b[hi]) / (b[hi] - b[hi - 1]) }
                while hi - lo > 1 { let m = (lo + hi) / 2; if b[m] <= t { lo = m } else { hi = m } }
                return Double(lo - beat0) + (t - b[lo]) / (b[hi] - b[lo])
            }
            return (t - firstBeat) * bpm / 60
        }
    }
    public struct Result: Equatable {
        /// Apple's tempo over ours (1 = same; 2 or 0.5 = it counted double or half time)
        public var tempoRatio: Double?
        /// 1, 0.5 or 2 when Apple's tempo is ours, half or double (within 2%): the cases whose beats can be compared.
        /// Half time is the usual one for 140-ish bass music: Apple counts 70
        public var tempoMult: Double?
        /// median offset of Apple's beats from ours, in our beats and in ms; nil if the tempos can't be compared
        public var beatOffset: Double?, beatOffsetMs: Double?
        /// share of Apple's beats within 1/8 beat of ours
        public var beatsOnGrid: Double?
        /// which of our beats (0-3, 0 = our bar 1) Apple's bars start on most often, and how often (0...1).
        /// At double time Apple's bar is two of our beats, so only 0 or 1
        public var barShift: Int?, barShare: Double?
        public var sameTempo: Bool { tempoRatio.map { abs($0 - 1) < 0.02 } ?? false }
        public var comparable: Bool { tempoMult != nil }
        /// same tempo (or half / double), beats within 1/8 beat, bars on our bar 1
        public var agrees: Bool { comparable && abs(beatOffset ?? 1) < 0.125 && barShift == 0 }
        public init() {}
    }

    public static func compare(_ ref: Grid, apple a: AppleFeatures) -> Result {
        var r = Result()
        guard ref.bpm > 0, let tempo = a.tempo else { return r }
        r.tempoRatio = tempo / ref.bpm
        r.tempoMult = [1.0, 0.5, 2.0].first { abs(r.tempoRatio! / $0 - 1) < 0.02 }
        guard let mult = r.tempoMult, !a.beats.isEmpty else { return r }
        // beat phase: wrapped to the nearest beat of ours (half time: Apple's beats are every second one of ours, which
        // still land on our beats; double time: every second one of Apple's falls between ours, so wrap to half beats)
        let k = mult == 2 ? 2.0 : 1.0
        let ph = a.beats.map { p -> Double in let x = ref.position(p) * k; return (x - x.rounded()) / k }
        let off = median(ph)
        r.beatOffset = off
        r.beatOffsetMs = off * 60 / ref.bpm * 1000
        r.beatsOnGrid = Double(ph.filter { abs($0) < 0.125 }.count) / Double(ph.count)
        // bar phase, after taking the beat offset out, so a grid that's a little early doesn't split the vote
        guard !a.bars.isEmpty else { return r }
        let n = mult == 2 ? 2 : 4
        var votes = [Int](repeating: 0, count: n)
        for b in a.bars {
            let i = Int((ref.position(b) - off).rounded())
            votes[((i % n) + n) % n] += 1
        }
        let best = votes.indices.max { votes[$0] != votes[$1] ? votes[$0] < votes[$1] : $0 > $1 }!
        r.barShift = best
        r.barShare = Double(votes[best]) / Double(a.bars.count)
        return r
    }
    static func median(_ x: [Double]) -> Double {
        let s = x.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
