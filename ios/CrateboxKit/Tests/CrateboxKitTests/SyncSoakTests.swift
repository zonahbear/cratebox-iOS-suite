import XCTest
@testable import CrateboxKit

/// Synced decks over minutes, the way the phone runs them: 48 kHz, big audio buffers, the screen's tick
/// at its own pace and an audio clock estimated from the last buffer. Measures where the decks really are
/// (the players' own positions), and what you actually hear (clicks in the output), and prints it.
final class SyncSoakTests: XCTestCase {
    let SR = 48000.0

    func clicks(bpm: Double, secs: Double, first: Double = 0) -> PCMTrack {
        let n = Int(secs * SR), t = PCMTrack(count: n, sampleRate: SR), spb = 60 / bpm
        for i in 0..<n {
            let s = Double(i) / SR - first
            let ph = s >= 0 ? s.truncatingRemainder(dividingBy: spb) : 1
            let v = Float(ph < 0.004 ? 0.9 * sin(2 * .pi * 2000 * ph) : 0)
            t.left[i] = v; t.right[i] = v
        }
        return t
    }

    struct Clock { var renderedAt = 0.0, renderTime = 0.0 }

    /// returns the worst beat offset (ms) between the two decks' players over each 30 s
    func soak(trueA: Double, gridA: Double, trueB: Double, gridB: Double, mt: Bool, pitchA: Double, buffer: Int, secs: Double, appClock: Bool, label: String) -> [Double] {
        let e = Engine(sampleRate: SR), c = Core(engine: e)
        var wall = 0.0
        c.wallMs = { wall }
        // the app's clock: last buffer's audio time + host time since; buffers are rendered a little early
        var ck = Clock(), host = 0.0
        c.clock = appClock ? { ck.renderTime + min(0.25, max(0, host - ck.renderedAt)) } : { e.time }
        let tA = clicks(bpm: trueA, secs: secs + 30), tB = clicks(bpm: trueB, secs: secs + 30, first: 0.21)
        for (k, (t, g, fb)) in [(tA, gridA, 0.0), (tB, gridB, 0.21)].enumerated() {
            let info = TrackInfo(id: "soak\(k)", title: "Soak \(k)")
            c.decks[k].beginLoad(info)
            c.decks[k].finishLoad(info, pcm: t, analysis: DeckAnalysis(bpm: g, firstBeat: fb, key: 21, phrases: [], wave: nil, duration: secs + 30), mono: nil)
            if c.decks[k].mt != mt { c.decks[k].setMT(mt) }
        }
        let outs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: buffer) }
        defer { outs.forEach { $0.deallocate() } }
        let a = c.decks[0], b = c.decks[1]
        var worst = [Double](), cur = 0.0
        func step(_ dt: Double) {
            // the screen ticks at 60 Hz; the audio thread renders whole buffers to stay ahead of real time
            let target = host + dt
            while host < target {
                host = min(target, host + 1.0 / 60)
                while e.time < host + Double(buffer) / SR {
                    e.render(outs, buffer)
                    ck.renderTime = e.time; ck.renderedAt = host + Double.random(in: 0...0.004)
                }
                wall = host * 1000
                c.tick()
            }
        }
        step(0.1)
        a.setPitch(pitchA); a.togglePlay(); step(1)
        b.seek(10); step(0.1)
        b.setSync(true); b.togglePlay()
        var t = 0.0
        while t < secs {
            step(0.25); t += 0.25
            // where the players really are, in each one's own (grid) beats
            let pa = e.decks[0].pos / SR, pb = e.decks[1].pos / SR
            var err = (pb - 0.21) / (60 / gridB) - b.syncMult * pa / (60 / gridA)
            err -= err.rounded()
            let ms = err * 60 / (gridB * b.rate()) * 1000
            cur = max(cur, abs(ms))
            if Int(t * 4) % 120 == 0 { worst.append(cur); cur = 0 }
        }
        print("SYNC \(label): worst offset per 30 s (ms) \(worst.map { String(format: "%.1f", $0) }.joined(separator: " ")) · trim \(String(format: "%.5f", b.syncTrim)) phaseErr \(String(format: "%.4f", b.phaseErr ?? -1))")
        return worst
    }

    func testSyncHoldsOverMinutes() {
        let w1 = soak(trueA: 128, gridA: 128, trueB: 126, gridB: 126, mt: true, pitchA: 0.3, buffer: 1024, secs: 180, appClock: true, label: "MT on, 1024 buffers, app clock")
        let w2 = soak(trueA: 128, gridA: 128, trueB: 126, gridB: 126, mt: false, pitchA: 0.3, buffer: 1024, secs: 180, appClock: true, label: "MT off, 1024 buffers, app clock")
        let w3 = soak(trueA: 174, gridA: 174, trueB: 87.3, gridB: 87.3, mt: true, pitchA: -0.2, buffer: 512, secs: 120, appClock: false, label: "halftime, MT on")
        _ = soak(trueA: 128, gridA: 128, trueB: 126.05, gridB: 126, mt: true, pitchA: 0, buffer: 1024, secs: 180, appClock: true, label: "deck 2's grid 0.05 BPM off")
        XCTAssertLessThan(w1.max() ?? 99, 8); XCTAssertLessThan(w2.max() ?? 99, 8); XCTAssertLessThan(w3.max() ?? 99, 8)
    }

    /// what you hear against where the player says it is: with MT on (time-stretched), the clicks in the
    /// output should stay a fixed distance from the reported position, not wander off
    func testHeardMatchesPosition() {
        for mt in [true, false] {
            let p = DeckPlayer(sampleRate: SR), bpm = 125.0, spb = 60 / bpm
            let t = clicks(bpm: bpm, secs: 200)
            p.setTrack(t)
            p.handle(.load(mt: mt, spin: 1.5)); p.handle(.rate(1.037)); p.handle(.play(true))
            let n = 512, l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { l.deallocate(); r.deallocate() }
            var outT = 0.0, last = -1.0, offs = [Double]()
            for _ in 0..<Int(150 * SR) / n {
                let pos0 = p.pos
                p.render(l, r, n)
                for j in 0..<n where abs(l[j]) > 0.3 && outT + Double(j) / SR - last > spb / 2 {
                    last = outT + Double(j) / SR
                    // the track time of the beat heard, and the player's position at that moment
                    let at = pos0 / SR + (p.pos - pos0) / SR * Double(j) / Double(n)
                    let beat = (at / spb).rounded()
                    offs.append((at - beat * spb) * 1000)
                }
                outT += Double(n) / SR
            }
            let head = offs.prefix(20).reduce(0, +) / Double(max(1, min(20, offs.count))), tail = offs.suffix(20).reduce(0, +) / Double(max(1, min(20, offs.count)))
            print("SYNC heard vs position, MT \(mt ? "on" : "off"): \(offs.count) clicks, offset at start \(String(format: "%.2f", head)) ms, after 150 s \(String(format: "%.2f", tail)) ms, spread \(String(format: "%.2f", (offs.max() ?? 0) - (offs.min() ?? 0))) ms")
            XCTAssertLessThan(abs(tail - head), 5, "what's heard stays with the reported position")
        }
    }
    /// a track whose tempo wanders (like a live drummer, or rekordbox's dynamic grids): synced on rekordbox's
    /// beat-by-beat grid it stays on the beat; on a single BPM it can't
    func testVariableTempoFollowsTheBeats() {
        for perBeat in [true, false] {
            let e = Engine(sampleRate: SR), c = Core(engine: e)
            var wall = 0.0
            c.wallMs = { wall }
            c.clock = { e.time }
            let secs = 150.0
            let a = clicks(bpm: 126, secs: secs + 30)
            // deck 2: beats whose spacing swings 0.4% around 126 BPM over about a minute
            var beats = [Double](), t = 0.3
            while t < secs + 25 { beats.append(t); t += 60 / 126 * (1 + 0.004 * sin(t / 9)) }
            let n = Int((secs + 30) * SR), tb = PCMTrack(count: n, sampleRate: SR)
            for bt in beats { let s0 = Int(bt * SR); for k in 0..<Int(0.004 * SR) where s0 + k < n { let v = Float(0.9 * sin(2 * .pi * 2000 * Double(k) / SR)); tb.left[s0 + k] = v; tb.right[s0 + k] = v } }
            for (k, (tr, an)) in [(a, DeckAnalysis(bpm: 126, firstBeat: 0, key: 21, phrases: [], wave: nil, duration: secs + 30)),
                                   (tb, { var x = DeckAnalysis(bpm: 126, firstBeat: 0.3, key: 21, phrases: [], wave: nil, duration: secs + 30); if perBeat { x.beats = beats }; return x }())].enumerated() {
                let info = TrackInfo(id: "var\(k)\(perBeat)", title: "Var \(k)")
                c.decks[k].beginLoad(info); c.decks[k].finishLoad(info, pcm: tr, analysis: an, mono: nil)
            }
            let outs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
            defer { outs.forEach { $0.deallocate() } }
            func run(_ s: Double) { for _ in 0..<Int(s * SR / 512) { e.render(outs, 512); wall += 512 / SR * 1000; c.tick() } }
            run(0.1); c.decks[0].togglePlay(); run(1)
            c.decks[1].seek(10); run(0.1); c.decks[1].setSync(true); c.decks[1].togglePlay()
            var worst = 0.0
            for _ in 0..<Int(secs * 2) {
                run(0.5)
                // the true beat phase of deck 2 (its real beats), against deck 1's
                let pb = e.decks[1].pos / SR, pa = e.decks[0].pos / SR
                var i = 0; while i + 1 < beats.count && beats[i + 1] <= pb { i += 1 }
                let trueB = Double(i) + (pb - beats[i]) / (beats[min(i + 1, beats.count - 1)] - beats[i])
                var err = trueB - pa / (60.0 / 126)
                err -= err.rounded()
                worst = max(worst, abs(err) * 60 / 126 * 1000)
            }
            print("SYNC wandering tempo, \(perBeat ? "beat-by-beat grid" : "one BPM"): worst offset \(String(format: "%.1f", worst)) ms over \(Int(secs)) s")
            if perBeat { XCTAssertLessThan(worst, 8) }
        }
    }
}
