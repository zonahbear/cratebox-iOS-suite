// The audio engine: 4 decks -> channel strips -> master (BEAT FX on MASTER, level, limiter), plus the
// headphone mix, rendered in 128-frame blocks like the web app's AudioWorklets (so anything timed per block,
// such as the jog's pitch bend fading out, behaves the same). The app's audio callback calls render();
// everything else talks to it through post() and reads it back with snapshot().
import Foundation
import os

public struct DeckReport { public var pos = 0.0, speed = 0.0, playing = false, ended = false, coast = false, peakL: Float = 0, peakR: Float = 0, seq = 0 }
/// time: the audio clock (s) at the end of the last block; host: the host clock (s, uptime) when it was rendered
public struct EngineSnapshot { public var time = 0.0, host = 0.0; public var decks = [DeckReport](repeating: DeckReport(), count: 4); public var masterPeak: (Float, Float) = (0, 0) }
@inline(__always) public func hostSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

public enum EngineCommand {
    case deck(Int, DeckMessage)
    case track(Int, PCMTrack?)                 // then .deck(i, .load(...))
    case mixer(MixerState)
    case fx(unit: Int, slot: FxSlotName, fx: FxKind?, beats: Double?, depth: Double?, on: Bool?)   // unit 0-3 = decks, 4 = master
    case clock(unit: Int, FxClock)
    /// PUFF (Cratebox HEAT): how hard the Puffco is being hit, 0...1, for the BEAT FX slot of that unit
    case fxMod(unit: Int, mod: Double)
    case output(OutputMode)
    /// set or clear the recording tap on the audio thread itself (so it never changes mid-block)
    case recordTap(((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?)
    /// three short beeps in the headphone mix only (if the speakers play them too, cue isn't separate)
    case testCue
    /// three short beeps on the master only (the speakers)
    case testMaster
}
public enum FxSlotName { case beat, pad }

public final class Engine {
    public let sampleRate: Double
    public let decks: [DeckPlayer]
    let strips: [ChannelStrip]
    let masterFx: FxUnit
    var limiter: Limiter
    var mixer = MixerState()
    var gMaster: Double, gHpCue = 1.0, gHpMaster = 0.0, gMcue = 0.0
    public private(set) var output: OutputMode = .stereo
    var frames: Int64 = 0
    var beepLeft = 0, beepPhase = 0.0, beepMaster = false
    // scratch, allocated once
    let B = 128
    let dl: [UnsafeMutablePointer<Float>], dr: [UnsafeMutablePointer<Float>]
    let mL: UnsafeMutablePointer<Float>, mR: UnsafeMutablePointer<Float>, cL: UnsafeMutablePointer<Float>, cR: UnsafeMutablePointer<Float>
    let hL: UnsafeMutablePointer<Float>, hR: UnsafeMutablePointer<Float>
    // commands in, reports out (the audio thread never waits: it tries the lock and skips if it's busy)
    // on the heap: a lock needs an address that never moves, which a Swift stored property doesn't promise
    let lock: UnsafeMutablePointer<os_unfair_lock> = { let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p }()
    var pending = [EngineCommand]()
    var inbox = [EngineCommand]()
    // written by the audio thread in place (no array copy-on-write there)
    let reports = UnsafeMutablePointer<DeckReport>.allocate(capacity: 4)
    var reportTime = 0.0, reportHost = 0.0, reportMaster: (Float, Float) = (0, 0)
    // replaced tracks, freed off the audio thread: `retired` belongs to the audio thread alone; it hands them to
    // `trash` (shared, under the lock) and the main thread takes them from there and lets go after unlocking
    // (room for 16 kept in each: only a 17th track replaced before the main thread's next snapshot, which comes
    // every frame, would make the audio thread grow `retired`, so that's an allocation, not a free, and in practice never)
    var retired = [PCMTrack](), trash = [PCMTrack]()
    /// a copy of the master output (after the limiter) for recording; set by the recorder
    var recordTap: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    /// how many .recordTap commands the audio thread has applied (reported under the lock): once it's past the one
    /// that removed a tap, that tap will never be called again
    var tapApplied = 0, reportTapApplied = 0
    public var tapChanges: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return reportTapApplied }
    /// HEAT build: the host mixes things in after the engine (the watch mic, its auto-duck), so with this on the
    /// record tap gets the master after them: render keeps the callback's master here and `recordMixed` hands it on
    public var recordAfterMix = false
    let recCap = 8192
    let recL: UnsafeMutablePointer<Float>, recR: UnsafeMutablePointer<Float>
    var recN = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        decks = (0..<4).map { _ in DeckPlayer(sampleRate: sampleRate) }
        strips = (0..<4).map { _ in ChannelStrip(sr: sampleRate) }
        masterFx = FxUnit(sampleRate: sampleRate)
        limiter = Limiter(sr: sampleRate)
        gMaster = MixerCurves.masterGain(0.8)
        func buf() -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: 128); p.initialize(repeating: 0, count: 128); return p }
        dl = (0..<4).map { _ in buf() }; dr = (0..<4).map { _ in buf() }
        mL = buf(); mR = buf(); cL = buf(); cR = buf(); hL = buf(); hR = buf()
        recL = .allocate(capacity: recCap); recR = .allocate(capacity: recCap)
        recL.initialize(repeating: 0, count: recCap); recR.initialize(repeating: 0, count: recCap)
        reports.initialize(repeating: DeckReport(), count: 4)
        pending.reserveCapacity(1024); inbox.reserveCapacity(1024); retired.reserveCapacity(16); trash.reserveCapacity(16)
        for i in 0..<4 { strips[i].apply(mixer, i) }
    }

    /// From any thread.
    public func post(_ c: EngineCommand) { os_unfair_lock_lock(lock); pending.append(c); os_unfair_lock_unlock(lock) }
    public func post(_ cs: [EngineCommand]) { os_unfair_lock_lock(lock); pending.append(contentsOf: cs); os_unfair_lock_unlock(lock) }
    /// What the audio thread last reported, and the tracks it's done with (drop them here).
    public func snapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        var done = [PCMTrack]()
        os_unfair_lock_lock(lock)
        s.time = reportTime; s.host = reportHost; s.masterPeak = reportMaster
        for i in 0..<4 { s.decks[i] = reports[i] }
        if !trash.isEmpty { done.reserveCapacity(trash.capacity); swap(&trash, &done) }   // trash keeps an empty buffer
        os_unfair_lock_unlock(lock)
        withExtendedLifetime(done) {}           // freed after this, outside the lock
        return s
    }

    func apply(_ c: EngineCommand) {
        switch c {
        case .deck(let i, let m):
            // unload drops the deck's audio: keep it alive until the main thread drops it, as .track does (freeing
            // a whole track's buffers here would stall this thread)
            if case .unload = m, let old = decks[i].track { retired.append(old) }
            decks[i].handle(m)
        case .track(let i, let t):
            if let old = decks[i].track { retired.append(old) }     // keep it alive until the main thread drops it
            decks[i].setTrack(t)
        case .mixer(let m): mixer = m; for i in 0..<4 { strips[i].apply(m, i) }
        case .fx(let u, let slot, let fx, let beats, let depth, let on):
            let unit = u < 4 ? strips[u].fx : masterFx
            (slot == .beat ? unit.beat : unit.pad).set(fx: fx, beats: beats, depth: depth, on: on)
        case .clock(let u, let c): (u < 4 ? strips[u].fx : masterFx).clock = c
        case .fxMod(let u, let m): (u < 4 ? strips[u].fx : masterFx).beat.set(mod: m)
        case .output(let o): output = o
        case .recordTap(let f): recordTap = f; tapApplied += 1
        case .testCue: beepLeft = Int(1.05 * sampleRate); beepPhase = 0; beepMaster = false
        case .testMaster: beepLeft = Int(1.05 * sampleRate); beepPhase = 0; beepMaster = true
        }
    }

    /// The audio callback: `outs` are the output channels (2, or 4 for master on 1/2 and headphones on 3/4).
    /// audio thread, after the host's own mixing (recordAfterMix): `add` gets this callback's master (stereo, after
    /// the limiter) to mix the same things into, then the record tap gets it
    public func recordMixed(_ add: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) {
        guard recordAfterMix, recN > 0, let tap = recordTap else { return }
        add(recL, recR, recN)
        tap(recL, recR, recN)
        recN = 0
    }
    public func render(_ outs: [UnsafeMutablePointer<Float>], _ n: Int) {
        if os_unfair_lock_trylock(lock) {
            swap(&pending, &inbox)
            os_unfair_lock_unlock(lock)
            for c in inbox { apply(c) }
            inbox.removeAll(keepingCapacity: true)
        }
        var done = 0
        recN = 0
        let k = 1 - exp(-1 / (0.008 * sampleRate))
        let tMaster = MixerCurves.masterGain(mixer.master), hm = MixerCurves.headMix(mixer.headMix), tMc = mixer.masterCue ? 1.0 : 0
        var mpl: Float = 0, mpr: Float = 0
        while done < n {
            let m = min(B, n - done)
            let time = Double(frames) / sampleRate
            for j in 0..<m { mL[j] = 0; mR[j] = 0; cL[j] = 0; cR[j] = 0 }
            for i in 0..<4 {
                decks[i].render(dl[i], dr[i], m)
                strips[i].process(dl[i], dr[i], m, time: time, cueL: cL, cueR: cR)
                for j in 0..<m { mL[j] += dl[i][j]; mR[j] += dr[i][j] }
            }
            masterFx.process(mL, mR, m, time: time)
            for j in 0..<m {
                gMaster += (tMaster - gMaster) * k; gHpCue += (hm.cue - gHpCue) * k; gHpMaster += (hm.master - gHpMaster) * k; gMcue += (tMc - gMcue) * k
                let ml = Double(mL[j]) * gMaster, mr = Double(mR[j]) * gMaster
                // headphones: the CUE mix, the master by the CUE/MASTER knob, and MASTER CUE at full level
                hL[j] = Float(Double(cL[j]) * gHpCue + ml * (gHpMaster + gMcue)); hR[j] = Float(Double(cR[j]) * gHpCue + mr * (gHpMaster + gMcue))
                var mb: Float = 0
                if beepLeft > 0 {
                    // 3 x 150 ms of 880 Hz, 200 ms apart
                    let pos = Int(1.05 * sampleRate) - beepLeft, cyc = Int(0.35 * sampleRate)
                    if pos % cyc < Int(0.15 * sampleRate) {
                        let b = Float(0.3 * sin(beepPhase))
                        if beepMaster { mb = b } else { hL[j] += b; hR[j] += b }
                    }
                    beepPhase += 2 * Double.pi * 880 / sampleRate
                    beepLeft -= 1
                }
                var l = ml, r = mr
                limiter.run(&l, &r)
                mL[j] = Float(l) + mb; mR[j] = Float(r) + mb
                if abs(mL[j]) > mpl { mpl = abs(mL[j]) }; if abs(mR[j]) > mpr { mpr = abs(mR[j]) }
            }
            if let tap = recordTap {
                if recordAfterMix {
                    let c = min(m, recCap - recN)
                    recL.advanced(by: recN).update(from: mL, count: c); recR.advanced(by: recN).update(from: mR, count: c); recN += c
                } else { tap(mL, mR, m) }
            }
            switch output {
            case .quad where outs.count >= 4:
                for j in 0..<m { outs[0][done + j] = mL[j]; outs[1][done + j] = mR[j]; outs[2][done + j] = hL[j]; outs[3][done + j] = hR[j] }
                if outs.count > 4 { for c in 4..<outs.count { for j in 0..<m { outs[c][done + j] = 0 } } }
            case .quadSwapped where outs.count >= 4:
                for j in 0..<m { outs[0][done + j] = hL[j]; outs[1][done + j] = hR[j]; outs[2][done + j] = mL[j]; outs[3][done + j] = mR[j] }
                if outs.count > 4 { for c in 4..<outs.count { for j in 0..<m { outs[c][done + j] = 0 } } }
            case .split where outs.count >= 2:
                // mono master on the left, mono cue mix on the right (a splitter cable)
                for j in 0..<m { outs[0][done + j] = (mL[j] + mR[j]) * 0.5; outs[1][done + j] = (hL[j] + hR[j]) * 0.5 }
            default:
                for j in 0..<m { outs[0][done + j] = mL[j]; if outs.count > 1 { outs[1][done + j] = mR[j] } }
                if outs.count > 2 { for c in 2..<outs.count { for j in 0..<m { outs[c][done + j] = 0 } } }
            }
            frames += Int64(m); done += m
        }
        if os_unfair_lock_trylock(lock) {
            reportTime = Double(frames) / sampleRate; reportHost = hostSeconds()
            for i in 0..<4 {
                let d = decks[i]
                reports[i] = DeckReport(pos: d.pos, speed: d.speed, playing: d.playing, ended: d.ended, coast: d.coast, peakL: strips[i].peakL, peakR: strips[i].peakR, seq: d.seq)
            }
            reportMaster = (mpl, mpr); reportTapApplied = tapApplied
            // hand retired tracks over (a swap of two buffers: nothing allocated or freed here); if the main
            // thread hasn't taken the last lot yet, they wait for the next block
            if !retired.isEmpty && trash.isEmpty { swap(&retired, &trash) }
            os_unfair_lock_unlock(lock)
        }
    }
    public var time: Double { Double(frames) / sampleRate }
}
