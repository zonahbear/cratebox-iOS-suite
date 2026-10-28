// The app's brain: decks (cue, hot cues, loops, beat jump, sync and beat lock, grid editing, tempo), the
// mixer and Beat FX / Pad FX state, on top of the audio engine. A port of the web app's Deck class and the
// mixer/FX functions around it (cratebox.html), kept close to the original so the two behave alike.
// UI-free: the SwiftUI app observes it, the controller drives it, the tests run it offline.
import Foundation
import Combine

public let RANGES: [Double] = [6, 10, 16, 100]
public let LOOP_SIZES: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]
public let JUMPS: [Double] = [-1, 1, -2, 2, -4, 4, -8, 8]
@inline(__always) func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, v)) }

/// What the decks need to know about a track
public final class TrackInfo: Identifiable, Equatable {
    public let id: String
    public var title: String, artist: String
    public var bpm: Double?, firstBeat: Double?, key: Int, duration: Double
    public var phrases: [Phrase]
    public var gridManual = false, autoBpm: Double?, autoFirst: Double?
    public var keyFromRekordbox = false
    public var rbCues: (cue: Double?, hot: [Double?])?
    /// rekordbox's own beat grid, beat by beat (seconds), and which beat is bar 1's first
    public var rbBeats: [Double]?
    public var rbBeat0 = 0
    public var rbGrid = false            // the grid came from rekordbox
    public init(id: String, title: String, artist: String = "", bpm: Double? = nil, firstBeat: Double? = nil, key: Int = -1, duration: Double = 0, phrases: [Phrase] = []) {
        self.id = id; self.title = title; self.artist = artist; self.bpm = bpm; self.firstBeat = firstBeat; self.key = key; self.duration = duration; self.phrases = phrases
    }
    public static func == (a: TrackInfo, b: TrackInfo) -> Bool { a === b }
}

/// A deck's analysis (the web app's `ana`)
public struct DeckAnalysis {
    public var bpm: Double, firstBeat: Double, key: Int, phrases: [Phrase], wave: Waveform?, duration: Double
    /// a beat-by-beat grid (rekordbox's): followed exactly instead of bpm + firstBeat, so a track whose
    /// tempo isn't a perfectly even number (or changes) stays locked. beat0: the index of bar 1's first beat
    public var beats: [Double]? = nil, beat0 = 0
    public init(bpm: Double, firstBeat: Double, key: Int, phrases: [Phrase], wave: Waveform?, duration: Double) {
        self.bpm = bpm; self.firstBeat = firstBeat; self.key = key; self.phrases = phrases; self.wave = wave; self.duration = duration
    }
}

/// Saved cue points per track (CUE and hot cues A-H)
public protocol CueStore: AnyObject {
    func load(_ id: String) -> (cue: Double?, hot: [Double?])?
    func save(_ id: String, cue: Double?, hot: [Double?])
}
public final class MemoryCueStore: CueStore {
    var m = [String: (Double?, [Double?])]()
    public init() {}
    public func load(_ id: String) -> (cue: Double?, hot: [Double?])? { m[id].map { ($0.0, $0.1) } }
    public func save(_ id: String, cue: Double?, hot: [Double?]) { m[id] = (cue, hot) }
}

public struct Loop: Equatable { public var on = false; public var a: Double? = nil; public var b: Double? = nil }
public enum PadMode: String, CaseIterable { case hotcue, beatloop, beatjump, padfx, padfx2 }

public final class DeckModel: ObservableObject, Identifiable {
    public let i: Int
    unowned let core: Core
    public var id: Int { i }
    @Published public private(set) var track: TrackInfo?
    @Published public private(set) var ana: DeckAnalysis?
    @Published public private(set) var loading = false
    public private(set) var duration = 0.0
    var sr = 44100.0
    // position: from the engine's reports, moved on by the clock in between
    // the engine's position (frames) at audio-clock time posT: reports are stamped with the audio clock, so the
    // guesses made here between reports are too (core.clock() + core.lag(), not the heard clock)
    var pos = 0.0, posT = 0.0, speed = 0.0
    var audioNow: Double { core.clock() + core.lag() }
    /// a new speed from now on: restamp the engine's position first, so the time since the last report isn't lost
    func rebase(speed v: Double) { pos = (heard() + core.lag() * speed) * sr; posT = audioNow; speed = v }
    @Published public private(set) var playing = false
    @Published public private(set) var pitch = 0.0          // -1...1 from the tempo fader (top = negative, Pioneer style)
    @Published public private(set) var rangeIdx = 0
    @Published public private(set) var sync = false
    var syncSince = 0.0, syncRate = 1.0
    public private(set) var syncMult = 1.0
    var syncTrim = 0.0
    public private(set) var phaseErr: Double?
    @Published public private(set) var cue = 0.0
    @Published public private(set) var hot = [Double?](repeating: nil, count: 8)
    @Published public private(set) var loop = Loop()
    @Published public var quant = true
    @Published public var padMode: PadMode = .hotcue
    @Published public private(set) var previewing = false
    public private(set) var touch = false
    var loopInDown = 0.0
    var sentRate: Double?
    var coasting = false, coastHold = 0.0
    public private(set) var startedAt = 0.0
    @Published public private(set) var mt = true
    var seekSeq = 0
    var syncWith: DeckModel?
    var syncTrack: TrackInfo?
    var taps = [Double]()
    /// the analysis audio, kept to redo the phrases after a grid edit
    public var mono: (x: [Float], fs: Double)?

    init(_ i: Int, core: Core) {
        self.i = i; self.core = core
        mt = core.prefs.bool("cb.mt\(i)", true)
    }
    func post(_ m: DeckMessage) { core.engine.post(.deck(i, m)) }
    public var loaded: Bool { track != nil && !loading && duration > 0 }
    public var range: Double { RANGES[rangeIdx] }
    public var bpm: Double { ana?.bpm ?? 0 }
    /// seconds per beat where the playhead is (a beat-by-beat grid's tempo varies along the track)
    public var spb: Double {
        if let b = grid { return windowSpb(b, now()) }
        return bpm > 0 ? 60 / bpm : 0.5
    }
    /// seconds per beat over the 16 beats around t. rekordbox stores beat times in whole milliseconds, so one
    /// beat at 140 BPM is 428 or 429 ms (140.19 / 139.86 BPM): tempo comes from the span, not single beats
    func windowSpb(_ b: [Double], _ t: Double) -> Double {
        let i = seg(b, t), lo = max(0, i - 8), hi = min(b.count - 1, i + 9)
        return max(0.05, (b[hi] - b[lo]) / Double(hi - lo))
    }
    /// the tempo at the playhead, from the grid
    public func tempoNow() -> Double { if let b = grid { return 60 / windowSpb(b, now()) }; return bpm }
    var grid: [Double]? { if let b = ana?.beats, b.count >= 2 { return b }; return nil }
    /// index of the beat segment holding t, and the segment's length
    func seg(_ b: [Double], _ t: Double) -> Int {
        if t <= b[0] { return 0 }
        if t >= b[b.count - 1] { return b.count - 2 }
        var lo = 0, hi = b.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if b[m] <= t { lo = m } else { hi = m } }
        return lo
    }
    func segment(_ b: [Double], _ t: Double) -> Double { let i = seg(b, t); return max(0.05, b[i + 1] - b[i]) }
    var active: Bool { core.deckActive(i) }

    public func setMT(_ on: Bool) {
        mt = on; core.prefs.set("cb.mt\(i)", on)
        post(.mt(on))
        core.status("Deck \(i + 1): master tempo \(on ? "on (tempo changes keep the key)" : "off (vinyl: tempo changes the pitch)")")
    }

    // ---- beat grid editing: every edit keeps the beat under the playhead, and firstBeat on a bar line ----
    public func setGrid(_ bpm: Double, _ firstBeat0: Double, _ why: String? = nil) {
        guard var a = ana, bpm > 20, bpm < 400 else { return }
        if let t = track, !t.gridManual { t.autoBpm = a.bpm; t.autoFirst = a.firstBeat }
        let bar = 4 * 60 / bpm
        let firstBeat = firstBeat0 - jsFloor(firstBeat0 / bar) * bar
        a.bpm = bpm; a.firstBeat = firstBeat; a.beats = nil; ana = a
        if let t = track { t.bpm = bpm; t.firstBeat = firstBeat; t.gridManual = true; core.trackChanged(t) }
        rephrase()
        if sync { syncTick() }
        for d in core.decks where d !== self && d.sync { d.syncTick() }
        sentRate = nil; sendRate()
        if let why { core.status("Deck \(i + 1) grid: \(why) · \(String(format: "%.2f", bpm)) BPM") }
    }
    public func setBpm(_ b: Double, _ why: String? = nil) {
        guard ana != nil else { return }
        let bpm = jsRound(b * 1000) / 1000
        let t = now(), beat = beatAt(t)
        setGrid(bpm, t - beat * (60 / bpm), why ?? "BPM set")
    }
    public func nudgeGrid(_ sec: Double) { if let a = ana { setGrid(a.bpm, a.firstBeat + sec, "moved \(sec > 0 ? "later" : "earlier") \(Int(jsRound(abs(sec * 1000)))) ms") } }
    public func downbeatHere() { if let a = ana { setGrid(a.bpm, now(), "bar 1 set at the playhead") } }
    public func beatHere() {
        guard let a = ana else { return }
        let t = now(), b = jsRound(beatAt(t))
        setGrid(a.bpm, t - b * spb, "beat set at the playhead")
    }
    public func tap() {
        let nowMs = core.wallMs()
        if taps.isEmpty || nowMs - taps[taps.count - 1] > 2000 { taps = [] }
        taps.append(nowMs)
        if taps.count > 16 { taps.removeFirst() }
        let n = Double(taps.count)
        if taps.count < 4 { core.status("Tap \(taps.count)… keep tapping on the beat"); return }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (x, y) in taps.enumerated() { let xd = Double(x); sx += xd; sy += y; sxx += xd * xd; sxy += xd * y }
        let ms = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        setBpm(jsRound(60000 / ms * 100) / 100, "tapped (\(taps.count) taps)")
    }
    var rephraseWork: DispatchWorkItem?
    func rephrase() {
        rephraseWork?.cancel()
        guard let m = mono, let a = ana else { return }
        let t = track, bpm = a.bpm, fb = a.firstBeat
        let w = DispatchWorkItem { [weak self] in
            let ph = Analysis.phraseAnalysis(m.x, m.fs, bpm, fb)
            DispatchQueue.main.async {
                guard let self, var cur = self.ana, cur.bpm == bpm, cur.firstBeat == fb else { return }
                cur.phrases = ph; self.ana = cur
                if let t { t.phrases = ph; self.core.trackChanged(t) }
            }
        }
        rephraseWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    public func resetGrid() {
        guard let t = track, var a = ana else { return }
        if let ab = t.autoBpm, let af = t.autoFirst { a.bpm = ab; a.firstBeat = af; t.bpm = ab; t.firstBeat = af; ana = a }
        t.gridManual = false
        core.trackChanged(t)
        if t.autoBpm == nil { core.reanalyse(t) }
        rephrase()
        core.status("Deck \(i + 1): grid back to the analysis")
    }

    // ---- tempo ----
    /// the deck to follow when synced. A playing deck only ever follows the playing deck it already follows:
    /// it never picks up a new master mid-mix (a track loaded on another deck, a deck pressed into play), and
    /// when its master stops or loads it keeps its tempo and leads (see syncTick).
    public func master() -> DeckModel? {
        if sync && playing {
            guard let w = syncWith, w.playing, w.track === syncTrack, followable(w) else { return nil }
            return w
        }
        return pickMaster()
    }
    func followable(_ o: DeckModel) -> Bool {
        o !== self && core.deckActive(o.i) && o.loaded && o.bpm > 0 && !(o.sync && sync && o.syncSince > syncSince)
    }
    func pickMaster() -> DeckModel? {
        // Two decks: the other one, unless it synced after us (then we lead). A playing deck only takes a playing one.
        // Four decks: prefer one that isn't synced itself, then one that's playing, then the one playing longest.
        let c = core.decks.filter { o in followable(o) && (o.playing || !playing) }
        if c.isEmpty { return nil }
        let score = { (o: DeckModel) in (o.sync ? 0 : 4) + (o.playing ? 2 : 0) }
        return c.sorted { a, b in
            if score(a) != score(b) { return score(a) > score(b) }
            let sa = a.startedAt > 0 ? a.startedAt : .infinity, sb = b.startedAt > 0 ? b.startedAt : .infinity
            if sa != sb { return sa < sb }
            return a.i < b.i
        }[0]
    }
    public func rate() -> Double {
        if sync, bpm > 0 { return syncRate * (1 + syncTrim) }     // synced with no master: holds its tempo
        return 1 + pitch * range / 100
    }
    public func effBpm() -> Double { tempoNow() * rate() / (sync ? 1 + syncTrim : 1) }
    /// with master tempo off, speeding up raises the key: 6% is about a semitone
    public func keyNow() -> Int {
        guard let a = ana, a.key >= 0 else { return -1 }
        return mt ? a.key : Keys.shift(a.key, Int(jsRound(12 * log2(rate()))))
    }
    func onReport(_ d: DeckReport, time: Double) {
        if d.seq < seekSeq { return }          // a report from before our latest seek would undo it
        pos = d.pos; posT = time; speed = d.speed
        if core.wallMs() > coastHold { coasting = d.coast }
        if playing && !d.playing && d.ended { playing = false }
    }
    public func now() -> Double { clamp(heard(), 0, duration) }
    func heard() -> Double { pos / sr + (core.clock() - posT) * speed }
    /// where the engine is playing now: `now()` is what you hear, `core.lag()` seconds behind it (a lot, on
    /// Bluetooth). Jumps by a distance and phase matching start from here, or they'd land that much short.
    public func playhead() -> Double { clamp(heard() + core.lag() * speed, 0, duration) }     // not clamped twice: exact near the ends
    public func beatAt(_ t: Double) -> Double {
        if let b = grid, let a = ana {
            let i = seg(b, t)
            return Double(i) + (t - b[i]) / max(0.05, b[i + 1] - b[i]) - Double(a.beat0)
        }
        return ana.map { (t - $0.firstBeat) / (bpm > 0 ? 60 / bpm : 0.5) } ?? 0
    }
    public func timeOfBeat(_ x: Double) -> Double {
        if let b = grid, let a = ana {
            let j = x + Double(a.beat0), n = b.count
            let i = Int(max(0, min(Double(n - 2), j.rounded(.down))))
            return b[i] + (j - Double(i)) * (b[i + 1] - b[i])
        }
        return ana.map { $0.firstBeat + x * (bpm > 0 ? 60 / bpm : 0.5) } ?? 0
    }
    public func snap(_ t: Double) -> Double { quant && ana != nil ? timeOfBeat(jsRound(beatAt(t))) : t }
    func sendRate() { let r = rate(); if r != sentRate { sentRate = r; post(.rate(r)) } }

    // ---- loading: the app decodes and analyses, then hands the deck the result ----
    public func canLoad() -> String? {
        if !active { return "Deck \(i + 1) is hidden: turn on 4 DECKS first" }
        if playing && core.loadLock { return "Deck \(i + 1) is playing. Stop it before loading (or turn off Settings → Decks → Load lock)." }
        return nil
    }
    public func beginLoad(_ t: TrackInfo) {
        if playing { previewing = false; setPlaying(false) }
        loading = true; track = t; ana = nil; mono = nil
        // a new track: sync starts over (master and half/double time picked again), from the fader's tempo
        syncWith = nil; syncTrack = nil; syncTrim = 0; syncRate = 1 + pitch * range / 100
        core.engine.post([.deck(i, .unload), .track(i, nil)])
    }
    public func failLoad(_ t: TrackInfo, _ err: String) {
        guard track === t else { return }
        loading = false; track = nil; ana = nil; duration = 0
        core.status("Couldn't load that file: \(err)", 8)
    }
    /// empty the deck (its drive is being ejected): stopped, and the audio let go
    public func unload() {
        if playing { setPlaying(false) }
        loading = false; track = nil; ana = nil; mono = nil; duration = 0
        loop = Loop(); previewing = false
        core.engine.post([.deck(i, .unload), .track(i, nil)])
    }
    public func finishLoad(_ t: TrackInfo, pcm: PCMTrack, analysis a: DeckAnalysis, mono: (x: [Float], fs: Double)?) {
        guard track === t else { return }
        sr = pcm.sampleRate; duration = Double(pcm.count) / pcm.sampleRate
        core.engine.post([.track(i, pcm), .deck(i, .load(mt: mt, spin: core.spinSecs))])
        pos = 0; posT = audioNow; speed = 0
        loop = Loop(); previewing = false
        self.mono = mono
        ana = a
        if a.phrases.isEmpty { rephrase() }
        t.bpm = a.bpm; t.duration = duration; t.firstBeat = a.firstBeat; t.key = a.key; t.phrases = a.phrases
        core.trackChanged(t)
        var saved = core.cues.load(t.id) ?? (nil, [Double?](repeating: nil, count: 8))
        if core.cues.load(t.id) == nil, let rc = t.rbCues { saved = rc }
        hot = Array((saved.hot + [Double?](repeating: nil, count: 8)).prefix(8))
        cue = saved.cue ?? a.firstBeat
        seek(cue)
        sentRate = nil; sendRate()
        loading = false
        core.status("Deck \(i + 1): \(t.title) · \(String(format: "%.2f", a.bpm)) BPM")
    }

    // jump somewhere: with Q on while playing, land on the same beat phase so a mix stays locked
    public func seekTo(_ t0: Double) {
        guard loaded else { return }
        var t = t0
        if playing && quant && bpm > 0 { let n = playhead(); t = n + jsRound((t - n) / spb) * spb }
        seek(t)
    }
    public func seek(_ t0: Double) {
        if !loaded && duration == 0 { return }
        let t = clamp(t0, 0, max(0, duration - 0.01))
        seekSeq += 1
        post(.seek(t * sr, seq: seekSeq))
        pos = t * sr; posT = audioNow
    }
    public func setPlaying(_ on: Bool) {
        guard loaded else { return }
        if on && !playing && sync { syncTick() }     // follow the master it would pick now, before it counts as playing
        if on, sync, let m = master(), m.playing { alignPhase() }
        if on && !playing { startedAt = core.wallMs(); core.playStarted() }
        playing = on
        previewing = false
        sendRate()
        post(.play(on))
        rebase(speed: on ? rate() : 0)
    }
    public func togglePlay() { setPlaying(!playing) }

    // CDJ-style CUE: while playing, back to the cue point and stop; while stopped, set it, or if already
    // on it, play for as long as it's held.
    public func cueDown() {
        guard loaded else { return }
        if playing { setPlaying(false); seek(cue) }
        else if abs(now() - cue) < 0.02 {
            previewing = true; playing = true
            sendRate(); post(.play(true)); rebase(speed: rate())
        } else {
            cue = snap(now()); seek(cue); saveCues()
        }
    }
    public func cueUp() {
        if previewing { previewing = false; playing = false; post(.play(false)); seek(cue) }
    }

    // ---- sync ----
    static func pickMult(_ r: Double) -> Double {
        [0.5, 1, 2].reduce(1.0) { best, k in abs(log(r * k)) < abs(log(r * best)) ? k : best }
    }
    public func setSync(_ on: Bool) {
        if on && (!loaded || bpm == 0) { return }
        sync = on
        if on {
            syncSince = core.wallMs()
            let m = pickMaster()
            syncWith = m; syncTrack = m?.track
            syncRate = 1 + pitch * range / 100          // with nothing to follow: stay at the fader's tempo
            if let m {
                // halftime / double time: of 1/2x, 1x and 2x the master's tempo, take the one nearest our own
                let r = m.effBpm() / tempoNow()
                syncMult = DeckModel.pickMult(r)
                syncRate = clamp(r * syncMult, 0.5, 2)
                syncTrim = 0
                sendRate()
                if playing && m.playing { alignPhase() }
                if syncMult != 1 { core.status("Deck \(i + 1) synced at \(syncMult < 1 ? "half" : "double") time: \(String(format: "%.2f", bpm * syncRate)) against \(String(format: "%.2f", m.effBpm()))") }
            } else { core.status(playing ? "Deck \(i + 1) leads: no other deck is playing, so it keeps its tempo and the next deck you sync follows it." : "Deck \(i + 1): load a track on another deck to sync to") }
        } else { syncTrim = 0; phaseErr = nil }
        sendRate()
    }
    func alignPhase() {
        guard let m = master(), m.bpm > 0, bpm > 0 else { return }
        let mb = m.beatAt(m.playhead()) * syncMult
        let frac = mb - jsFloor(mb)
        let myB = beatAt(playhead())
        var target = jsFloor(myB) + frac
        if target - myB > 0.5 { target -= 1 }
        if myB - target > 0.5 { target += 1 }
        seek(timeOfBeat(target))
    }
    func syncTick() {
        guard sync, bpm > 0 else { return }
        guard let m = master() else {
            // the master stopped, loaded a new track or went away: keep this tempo and lead from here on (the
            // oldest sync, so a deck that syncs now follows us, not the other way round)
            if syncWith != nil {
                syncWith = nil; syncTrack = nil
                if playing { syncSince = (core.decks.map(\.syncSince).min() ?? 0) - 1 }
            }
            if syncTrim != 0 { syncTrim = 0; sendRate() }
            phaseErr = nil
            return
        }
        // a different master, or a new track on it: pick half/normal/double time again
        if m !== syncWith || m.track !== syncTrack { syncMult = DeckModel.pickMult(m.effBpm() / tempoNow()) }
        syncWith = m; syncTrack = m.track
        let r = clamp(m.effBpm() * syncMult / tempoNow(), 0.5, 2)
        if abs(r - syncRate) > 1e-7 { syncRate = r; sendRate() }
        lockPhase(m)
    }
    // Beat lock: while both decks play, measure how far our beats are from the master's and correct with a
    // tiny speed change. A deliberate offset of more than a quarter beat is left alone.
    func lockPhase(_ m: DeckModel) {
        let live = playing && m.playing && !touch && !m.touch && !coasting && !m.coasting && !previewing && loaded && m.loaded
        if !live { if syncTrim != 0 { syncTrim = 0; sendRate() }; phaseErr = nil; return }
        var err = beatAt(now()) - m.beatAt(m.now()) * syncMult
        err -= jsRound(err)
        let errSec = err * spb / max(0.05, rate())
        phaseErr = errSec
        var want = 0.0
        if abs(err) < 0.25 && abs(errSec) > 0.0015 { want = clamp(-errSec / 1.5, -0.006, 0.006) }
        let trim = syncTrim + (want - syncTrim) * 0.2
        if abs(trim - syncTrim) > 1e-6 || (want == 0 && syncTrim != 0) { syncTrim = abs(trim) < 1e-5 ? 0 : trim; sendRate() }
    }
    public func cycleRange() {
        rangeIdx = (rangeIdx + 1) % RANGES.count
        sendRate()
        core.status("Deck \(i + 1) tempo range ±\(range == 100 ? "WIDE" : "\(Int(range))%")")
    }
    public func setPitch(_ v: Double) {
        let p = clamp(v, -1, 1)
        // a synced deck that leads (nothing to follow) holds its own tempo: the fader moves it from there
        if sync, bpm > 0, master() == nil { syncRate = clamp(syncRate + (p - pitch) * range / 100, 0.5, 2) }
        pitch = p; sendRate()
    }

    // ---- jog ----
    public func jogTouch(_ on: Bool, noCoast: Bool = false) {
        guard loaded else { return }
        touch = on
        if !on && !noCoast { coasting = true; coastHold = core.wallMs() + 120 } else { coasting = false }
        post(.scratch(on, noCoast: noCoast))
    }
    public enum JogKind { case scratch, bend, search }
    public func jogTicks(_ t0: Double, _ kind: JogKind, raw: Bool = false) {
        guard loaded else { return }
        let ticks = raw ? t0 : t0 * core.jogSens
        let tickSec = 1.8 / 720                 // 33 1/3 RPM platter, 720 ticks per turn
        if kind == .scratch && touch { post(.jog(ticks * tickSec * sr)) }
        else if coasting { return }
        else if kind == .search { seek(now() + ticks * 0.08) }
        else if playing { post(.bend(ticks * 0.004)) }
        else { seek(now() + ticks * tickSec) }
    }

    // ---- loops ----
    func sendLoop() {
        let on = loop.on && loop.a != nil && loop.b != nil
        post(.loop(on: on, a: (loop.a ?? 0) * sr, b: (loop.b ?? 0) * sr))
    }
    public func loopIn() { guard loaded else { return }; loop = Loop(on: false, a: snap(now()), b: nil); sendLoop() }
    public func loopOut() {
        guard loaded, let a = loop.a else { return }
        let b = snap(now())
        if b <= a + 0.01 { return }
        loop.b = b; loop.on = true; sendLoop()
    }
    public func reloopExit() {
        guard let a = loop.a, let b = loop.b else { return }
        if loop.on { loop.on = false; sendLoop() }
        else { loop.on = true; sendLoop(); let n = now(); if n > b || n < a { seek(a) } }
    }
    public func beatLoop(_ beats: Double) {
        guard loaded else { return }
        let len = beats * spb
        if loop.on, let a = loop.a, let b = loop.b, abs((b - a) - len) < 0.002 { loop.on = false; sendLoop(); return }
        let t = now()
        let a = quant && ana != nil ? timeOfBeat(jsFloor(beatAt(t) + 1e-6)) : t
        loop = Loop(on: true, a: a, b: a + len)
        sendLoop()
    }
    public func loopScale(_ f: Double) {
        guard let a = loop.a, let b = loop.b else { return }
        let len = (b - a) * f
        if len < spb / 32 || len > spb * 512 { return }
        loop.b = a + len
        sendLoop()
    }
    public func loopBeats() -> Double { if let a = loop.a, let b = loop.b { return (b - a) / spb }; return 0 }
    public func beatJump(_ beats: Double) {
        guard loaded else { return }
        let d = beats * spb
        if loop.on, let a = loop.a, let b = loop.b { loop.a = a + d; loop.b = b + d; sendLoop() }
        seek(playhead() + d)
    }
    // hold LOOP IN for half a second: 4-beat loop
    public func loopInPress(_ on: Bool) {
        if on { loopInDown = core.wallMs(); loopIn() }
        else if loopInDown > 0 && core.wallMs() - loopInDown > 500 { beatLoop(4) }
    }

    // ---- hot cues ----
    public func hotcue(_ k: Int) {
        guard loaded else { return }
        if let h = hot[k] { seek(h); if !playing { cue = h } }
        else { hot[k] = snap(now()); saveCues() }
    }
    public func clearHot(_ k: Int) { hot[k] = nil; saveCues() }
    public func callCue(_ dir: Int) {
        if loop.on { loopScale(dir > 0 ? 2 : 0.5); return }
        let t = now()
        let cues = hot.compactMap { $0 }.sorted()
        let next = dir > 0 ? cues.first { $0 > t + 0.05 } : cues.reversed().first { $0 < t - 0.05 }
        if let next { seek(next); if !playing { cue = next } }
    }
    func saveCues() { if let t = track { core.cues.save(t.id, cue: cue, hot: hot) } }
    /// the PAD FX bank each held pad was pressed in: its release goes there even if the pad mode changed meanwhile
    private var padHeld = [Int: PadMode]()
    public func padPress(_ p: Int, shift: Bool = false) {
        switch padMode {
        case .padfx, .padfx2: padHeld[p] = padMode; core.fx.padDown(i, padMode, p)
        case .hotcue: shift ? clearHot(p) : hotcue(p)
        case .beatloop: beatLoop(LOOP_SIZES[p])
        case .beatjump: beatJump(JUMPS[p])
        }
    }
    public func padRelease(_ p: Int) { if let b = padHeld.removeValue(forKey: p) { core.fx.padUp(i, b, p) } }
    /// for the screen: refresh @Published values that follow the playhead
    public func objectChanged() { objectWillChange.send() }
}

/// Settings and small state kept between launches
public protocol Prefs: AnyObject {
    func bool(_ k: String, _ d: Bool) -> Bool
    func double(_ k: String, _ d: Double) -> Double
    func string(_ k: String, _ d: String) -> String
    func set(_ k: String, _ v: Any?)
}
public final class MemoryPrefs: Prefs {
    var m = [String: Any]()
    public init() {}
    public func bool(_ k: String, _ d: Bool) -> Bool { m[k] as? Bool ?? d }
    public func double(_ k: String, _ d: Double) -> Double { m[k] as? Double ?? d }
    public func string(_ k: String, _ d: String) -> String { m[k] as? String ?? d }
    public func set(_ k: String, _ v: Any?) { m[k] = v }
}
public final class DefaultsPrefs: Prefs {
    let u = UserDefaults.standard
    public init() {}
    public func bool(_ k: String, _ d: Bool) -> Bool { u.object(forKey: k) == nil ? d : u.bool(forKey: k) }
    public func double(_ k: String, _ d: Double) -> Double { u.object(forKey: k) == nil ? d : u.double(forKey: k) }
    public func string(_ k: String, _ d: String) -> String { u.string(forKey: k) ?? d }
    public func set(_ k: String, _ v: Any?) { u.set(v, forKey: k) }
}

public final class Core: ObservableObject {
    public let engine: Engine
    public let prefs: Prefs
    public let cues: CueStore
    public private(set) var decks: [DeckModel] = []
    public lazy var fx = FxController(core: self)
    /// the audio clock now (seconds): the app works it out from the last report and the host clock
    public var clock: () -> Double = { 0 }
    /// how far what you hear is behind `clock` (the output's latency); the app sets it, tests can
    public var lag: () -> Double = { 0 }
    public var wallMs: () -> Double = { hostSeconds() * 1000 }
    public var status: (String, Double) -> Void = { _, _ in }
    public var trackChanged: (TrackInfo) -> Void = { _ in }
    public var reanalyse: (TrackInfo) -> Void = { _ in }
    public var playStarted: () -> Void = {}
    @Published public var mixer = MixerState() { didSet { engine.post(.mixer(mixer)) } }
    @Published public private(set) var four: Bool
    @Published public var loadLock: Bool { didSet { prefs.set("cb.loadLock", loadLock) } }
    public var jogSens: Double { didSet { prefs.set("cb.jogSens", jogSens) } }
    public var spinSecs: Double { didSet { prefs.set("cb.spin", spinSecs); engine.post(decks.indices.map { .deck($0, .spin(spinSecs)) }) } }

    public init(engine: Engine, prefs: Prefs = MemoryPrefs(), cues: CueStore = MemoryCueStore()) {
        self.engine = engine; self.prefs = prefs; self.cues = cues
        four = prefs.bool("cb.four", false)
        loadLock = prefs.bool("cb.loadLock", true)
        jogSens = prefs.double("cb.jogSens", 1)
        spinSecs = prefs.double("cb.spin", 2.5)
        decks = (0..<4).map { DeckModel($0, core: self) }
        mixer.active = [true, true, four, four]
        engine.post(.mixer(mixer))
        for d in decks { engine.post(.deck(d.i, .mt(d.mt))) }
    }
    public func status(_ s: String, _ secs: Double = 4) { status(s, secs) }
    public func deckActive(_ i: Int) -> Bool { i < 2 || four }
    public func setFour(_ on: Bool) {
        four = on; prefs.set("cb.four", on)
        mixer.active = [true, true, on, on]
        if !on { for d in decks[2...] where d.playing { d.setPlaying(false) } }
    }

    /// Call often (the app does ~60 times a second): reads the engine's reports, keeps sync locked and the FX clocks fresh.
    public func tick() {
        let s = engine.snapshot()
        for (k, d) in decks.enumerated() { d.onReport(s.decks[k], time: s.time) }
        for d in decks where d.sync { d.syncTick() }
        fx.clockTick()
        lastSnapshot = s
    }
    public private(set) var lastSnapshot = EngineSnapshot()

    // ---- mixer controls (the controller and the screen both come here) ----
    public func setMixer(_ name: String, _ deck: Int, _ v: Double) {
        switch name {
        case "fader": mixer.fader[deck] = v
        case "trim": mixer.trim[deck] = v
        case "hi": mixer.hi[deck] = v
        case "mid": mixer.mid[deck] = v
        case "low": mixer.low[deck] = v
        case "cfx": mixer.cfx[deck] = v
        case "xfader": mixer.xfader = v
        case "headMix": mixer.headMix = v
        case "master": mixer.master = v
        default: break
        }
    }
    public func mixerValue(_ name: String, _ deck: Int) -> Double? {
        switch name {
        case "fader": return mixer.fader[deck]
        case "trim": return mixer.trim[deck]
        case "hi": return mixer.hi[deck]
        case "mid": return mixer.mid[deck]
        case "low": return mixer.low[deck]
        case "cfx": return mixer.cfx[deck]
        case "tempo": return (decks[deck].pitch + 1) / 2
        default: return nil
        }
    }
    public func togglePfl(_ deck: Int) { mixer.pfl[deck].toggle() }
    public func toggleMasterCue() { mixer.masterCue.toggle() }
}

// ---- Beat FX / Pad FX state (the effects themselves run in the engine's FxUnits) ----
public struct FxSpec { public let beats: [Double]?; public let beat: Double; public let depth: Double }
public let FX_LIST: [(FxKind, FxSpec)] = [
    (.echo, FxSpec(beats: [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 3.0 / 4, 1, 2, 4], beat: 0.5, depth: 0.55)),
    (.delay, FxSpec(beats: [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 3.0 / 4, 1, 2, 4], beat: 0.75, depth: 0.6)),
    (.pingPong, FxSpec(beats: [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 3.0 / 4, 1, 2, 4], beat: 0.5, depth: 0.6)),
    (.reverb, FxSpec(beats: nil, beat: 1, depth: 0.55)),
    (.flanger, FxSpec(beats: [1, 2, 4, 8, 16, 32], beat: 16, depth: 0.8)),
    (.filter, FxSpec(beats: [1, 2, 4, 8, 16, 32], beat: 4, depth: 0.7)),
    (.trans, FxSpec(beats: [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2], beat: 0.25, depth: 1)),
    (.roll, FxSpec(beats: [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4], beat: 0.5, depth: 1)),
    (.hpf, FxSpec(beats: nil, beat: 1, depth: 0.6)),
    (.lpf, FxSpec(beats: nil, beat: 1, depth: 0.6)),
]
public let PAD_FX: [PadMode: [(FxKind, Double, Double)]] = [
    .padfx: [(.echo, 0.5, 0.6), (.echo, 1, 0.6), (.reverb, 1, 0.7), (.roll, 0.25, 1), (.roll, 0.5, 1), (.trans, 0.25, 1), (.hpf, 1, 0.7), (.lpf, 1, 0.7)],
    .padfx2: [(.pingPong, 0.5, 0.6), (.delay, 0.75, 0.6), (.flanger, 16, 0.8), (.roll, 0.125, 1), (.roll, 1, 1), (.trans, 0.125, 1), (.filter, 4, 0.8), (.echo, 0.25, 0.7)],
]
public func fracText(_ b: Double) -> String { b >= 1 ? (b == b.rounded() ? String(Int(b)) : String(b)) : b == 0.75 ? "3/4" : "1/\(Int(jsRound(1 / b)))" }

public final class FxController: ObservableObject {
    unowned let core: Core
    /// the BEAT FX unit: effect, BEAT per effect, depth, on, channel (0-3, or 4 = MASTER)
    @Published public private(set) var fx: FxKind = .echo
    @Published public private(set) var beats: [FxKind: Double] = [:]
    @Published public private(set) var depth = 0.55
    @Published public private(set) var on = false
    @Published public private(set) var ch = 0
    @Published public private(set) var pad: [(p: Int, bank: PadMode)?] = [nil, nil, nil, nil]
    var lastActive = [Int: Double]()
    var lastClock = 0.0
    init(core: Core) {
        self.core = core
        for (k, s) in FX_LIST { beats[k] = s.beat }
        let p = core.prefs
        if let f = FxKind(rawValue: p.string("cb.bfx.fx", "ECHO")), f != .none { fx = f }
        depth = p.double("cb.bfx.depth", depth)
        ch = Int(p.double("cb.bfx.ch", 0))
        for (k, _) in FX_LIST { let v = p.double("cb.bfx.beat.\(k.rawValue)", -1); if v > 0 { beats[k] = v } }
    }
    func save() {
        let p = core.prefs
        p.set("cb.bfx.fx", fx.rawValue); p.set("cb.bfx.depth", depth); p.set("cb.bfx.ch", Double(ch))
        for (k, v) in beats { p.set("cb.bfx.beat.\(k.rawValue)", v) }
    }
    public var spec: FxSpec { FX_LIST.first { $0.0 == fx }!.1 }
    public var beat: Double { beats[fx] ?? spec.beat }
    // the beat clock for an insert: its deck's (master: the deck the mix follows)
    func clockDeck(_ u: Int) -> DeckModel {
        if u < 4 { return core.decks[u] }
        if let s = core.decks.first(where: { core.deckActive($0.i) && $0.sync && $0.master() != nil }), let m = s.master() { return m }
        let loud = core.decks.filter { core.deckActive($0.i) && $0.playing && $0.loaded }.sorted { core.mixer.fader[$0.i] > core.mixer.fader[$1.i] }
        return loud.first ?? core.decks.first { $0.loaded } ?? core.decks[0]
    }
    func sendClock(_ u: Int) {
        let d = clockDeck(u)
        let bpm = d.bpm > 0 ? d.effBpm() : 120, playing = d.playing && d.loaded
        core.engine.post(.clock(unit: u, FxClock(t0: core.clock(), beat0: d.bpm > 0 ? d.beatAt(d.now()) : 0, bps: playing ? bpm / 60 : 0, spb: 60 / bpm)))
    }
    func clockTick() {
        let now = core.wallMs()
        if now - lastClock < 100 { return }
        lastClock = now
        for (u, t) in lastActive {
            let busy = (u == ch && on) || (u < 4 && pad[u] != nil)
            if busy { lastActive[u] = now }
            if busy || now - t < 15000 { sendClock(u) } else { lastActive[u] = nil }
        }
    }
    func send() {
        if on { lastActive[ch] = core.wallMs(); sendClock(ch) }
        core.engine.post(.fx(unit: ch, slot: .beat, fx: fx, beats: beat, depth: depth, on: on))
    }
    public func select(_ step: Int) {
        let names = FX_LIST.map { $0.0 }, k = names.firstIndex(of: fx) ?? 0
        let was = on
        fx = names[(k + step + names.count) % names.count]
        send(); save()
        if was { core.status("Beat FX: \(fx.rawValue)") }
    }
    public func select(_ kind: FxKind) { fx = kind; send(); save() }
    public func beatStep(_ step: Int) {
        guard let list = spec.beats else { return }
        var k = list.firstIndex { abs($0 - beat) < 1e-6 } ?? (list.firstIndex(of: spec.beat) ?? 0)
        k = max(0, min(list.count - 1, k + step))
        beats[fx] = list[k]
        send(); save()
    }
    public func channel(_ c: Int) {
        if c == ch { return }
        // the old insert stops taking input and rings out; the new one picks up
        core.engine.post(.fx(unit: ch, slot: .beat, fx: nil, beats: nil, depth: nil, on: false))
        ch = c
        send(); save()
    }
    public func setOn(_ v: Bool) { on = v; send() }
    public func setDepth(_ v: Double) { depth = clamp(v, 0, 1); send(); save() }
    // PAD FX: hold a pad = that effect on this deck; let go = off (the last pad pressed wins)
    public func padDown(_ i: Int, _ bank: PadMode, _ p: Int) {
        guard let pr = PAD_FX[bank]?[p] else { return }
        pad[i] = (p, bank)
        lastActive[i] = core.wallMs(); sendClock(i)
        core.engine.post(.fx(unit: i, slot: .pad, fx: pr.0, beats: pr.1, depth: pr.2, on: true))
    }
    public func padUp(_ i: Int, _ bank: PadMode, _ p: Int) {
        guard let cur = pad[i], cur.p == p, cur.bank == bank else { return }
        pad[i] = nil
        core.engine.post(.fx(unit: i, slot: .pad, fx: nil, beats: nil, depth: nil, on: false))
    }
}

/// Musical keys: 0-11 major (C...B), 12-23 minor; Camelot labels (the web app's camelot / shiftKey / keysMatch).
public enum Keys {
    static let pitch = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    public static func shift(_ k: Int, _ semis: Int) -> Int { k < 0 ? k : (k >= 12 ? 12 : 0) + (((k % 12) + semis) % 12 + 12) % 12 }
    public struct Camelot { public let num: Int, letter: String, label: String, name: String, sort: Int }
    public static func camelot(_ k: Int) -> Camelot? {
        guard k >= 0 else { return nil }
        let minor = k >= 12, pc = k % 12, rel = minor ? (pc + 3) % 12 : pc     // relative major
        let num = ((rel * 7) % 12 + 7) % 12 + 1                              // C major = 8B, G = 9B ...
        let letter = minor ? "A" : "B"
        return Camelot(num: num, letter: letter, label: "\(num)\(letter)", name: pitch[pc] + (minor ? " minor" : " major"), sort: num * 2 + (minor ? 0 : 1))
    }
    /// harmonic mixing: same key, one step round the wheel, or the relative major/minor
    public static func mixes(_ a: Int, _ b: Int) -> Bool {
        guard let x = camelot(a), let y = camelot(b) else { return false }
        if x.num == y.num { return true }
        return x.letter == y.letter && (abs(x.num - y.num) == 1 || abs(x.num - y.num) == 11)
    }
}
