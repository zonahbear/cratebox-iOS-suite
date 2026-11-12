import XCTest
@testable import CrateboxKit

/// AI DJ's decisions (AutoMix) and loudness. The audio here is test tones for the loudness meter's reference
/// values (BS.1770's own calibration case); the picks and plans run on track descriptions, not audio.
final class AutoMixTests: XCTestCase {
    // Camelot nA / nB → key index (as NextTrackTests)
    func A(_ n: Int) -> Int { [8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1][n - 1] + 12 }
    func B(_ n: Int) -> Int { [11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4][n - 1] }

    func sine(_ f: Double, amp: Double, secs: Double, fs: Double) -> [Float] {
        (0..<Int(secs * fs)).map { Float(amp * sin(2 * .pi * f * Double($0) / fs)) }
    }

    // ---- loudness ----
    func testFullScaleSineIsMinus3LUFS() {
        // BS.1770: a 997 Hz sine at 0 dBFS in one channel reads -3.01 LUFS
        for fs in [48000.0, 44100, 11025] {
            let l = Loudness.integrated(sine(997, amp: 1, secs: 5, fs: fs), fs: fs)
            XCTAssertNotNil(l)
            XCTAssertEqual(l!, -3.01, accuracy: 0.15, "at \(fs) Hz")
        }
    }
    func testLevelsAndGating() {
        let fs = 11025.0
        let loud = Loudness.integrated(sine(997, amp: 0.1, secs: 5, fs: fs), fs: fs)!
        XCTAssertEqual(loud, -23.01, accuracy: 0.15)                       // 20 dB down
        // silence in front is gated out: same reading
        let gap = [Float](repeating: 0, count: Int(10 * fs)) + sine(997, amp: 0.1, secs: 5, fs: fs)
        XCTAssertEqual(Loudness.integrated(gap, fs: fs)!, loud, accuracy: 0.25)   // the blocks across the edge count a little
        XCTAssertNil(Loudness.integrated([Float](repeating: 0, count: Int(3 * fs)), fs: fs))
        XCTAssertNil(Loudness.integrated([0.5, 0.5], fs: fs))
    }
    func testTrimIsTheMixersCurveBackwards() {
        for db in [-12.0, -6, -1.5, 0, 2, 6] {
            let v = Loudness.trimValue(db: db)
            XCTAssertEqual(20 * log10(MixerCurves.trimGain(v)), db, accuracy: 1e-9, "\(db) dB")
        }
        XCTAssertEqual(Loudness.trimValue(db: 0), 0.5, accuracy: 1e-12)
    }
    func testGainToTarget() {
        XCTAssertEqual(Loudness.gainDb(lufs: -6, peakDb: 0), -3, accuracy: 1e-9)          // loud master: down
        XCTAssertEqual(Loudness.gainDb(lufs: -13, peakDb: -6), 4, accuracy: 1e-9)         // quiet: up
        XCTAssertEqual(Loudness.gainDb(lufs: -13, peakDb: -1), 2, accuracy: 1e-9)         // up only to +1 dBFS peak
        XCTAssertEqual(Loudness.gainDb(lufs: -30, peakDb: -20), 6, accuracy: 1e-9)        // at most +6
    }

    // ---- the bass swap ----
    func testBassSwapLevels() {
        let t = AutoMix.Transition.bassSwap
        XCTAssertEqual(t.bars, 32)
        let s = t.levels(atBar: 0, of: 32)
        XCTAssertEqual(s, AutoMix.Levels(outFader: 1, outLow: 0.5, inFader: 0, inLow: 0))
        let q = t.levels(atBar: 8, of: 32)
        XCTAssertEqual(q.inFader, 1, accuracy: 1e-9); XCTAssertEqual(q.inLow, 0, accuracy: 1e-9); XCTAssertEqual(q.outLow, 0.5, accuracy: 1e-9)
        let before = t.levels(atBar: 15.99, of: 32), after = t.levels(atBar: 16.25, of: 32)
        XCTAssertEqual(before.inLow, 0, accuracy: 1e-9); XCTAssertEqual(before.outLow, 0.5, accuracy: 1e-9)
        XCTAssertEqual(after.inLow, 0.5, accuracy: 1e-9); XCTAssertEqual(after.outLow, 0, accuracy: 1e-9)    // swapped on the downbeat of bar 17
        XCTAssertEqual(t.levels(atBar: 24, of: 32).outFader, 1, accuracy: 1e-9)
        XCTAssertEqual(t.levels(atBar: 28, of: 32).outFader, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.levels(atBar: 32, of: 32), AutoMix.Levels(outFader: 0, outLow: 0, inFader: 1, inLow: 0.5))
        XCTAssertEqual(t.swapBar(of: 32), 16)
        // never both basses full at once
        for k in 0...640 { let l = t.levels(atBar: Double(k) / 20, of: 32); XCTAssertLessThanOrEqual(l.inLow + l.outLow, 0.5 + 1e-9) }
    }

    // ---- plans ----
    /// a 128 BPM track, bar 1 at 0.5 s, `secs` long, with vocals where given (seconds)
    func track(_ id: String, bpm: Double = 128, secs: Double = 360, key: Int = 0, vocals: [(Double, Double)]? = []) -> AutoMix.Track {
        var t = AutoMix.Track(id: id, bpm: bpm, firstBeat: 0.5, duration: secs, key: key)
        t.vocals = vocals?.map { AppleFeatures.Span($0.0, $0.1, 1) }
        return t
    }
    func testPlanAvoidsVocals() {
        // a sings to 4:40 (280 s), then an instrumental outro; b's vocals start at bar 33 (beat 128 = 60.5 s)
        let a = track("a", vocals: [(30, 280)])
        let b = track("b", vocals: [(60.5, 200)])
        let p = AutoMix.plan(from: a, aRate: 1, to: b, after: 0)!
        XCTAssertEqual(p.bars, 32)
        XCTAssertEqual(p.clash!, 0, accuracy: 1e-9)
        XCTAssertEqual(p.outStart.truncatingRemainder(dividingBy: 32), 0)        // on a phrase line
        XCTAssertEqual(p.inStart.truncatingRemainder(dividingBy: 32), 0)
        XCTAssertEqual(p.mult, 1)
        // b's vocals start 32 bars in; a's mix-in must start after a's vocals stop being heard (from bar 25 on a
        // fades, so a's vocals may run into the first 24 bars only while b is still vocal-free there)
        XCTAssertLessThanOrEqual(p.outEnd, a.lastBeat)
        // and it plays a as long as it can: within 8 bars of the latest clean start
        let latest = ((a.lastBeat - 128) / 32).rounded(.down) * 32
        XCTAssertGreaterThanOrEqual(p.outStart, latest - 32)
    }
    func testPlanWithoutVocalsKnownStillPlans() {
        let p = AutoMix.plan(from: track("a", vocals: nil), aRate: 1, to: track("b"), after: 100)!
        XCTAssertNil(p.clash)
        XCTAssertGreaterThanOrEqual(p.outStart, 100)
    }
    func testShortTransitionWhenNoRoom() {
        let a = track("a", secs: 60)          // 60 s at 128 = 127 beats: no room for 32 bars after beat 32
        let p = AutoMix.plan(from: a, aRate: 1, to: track("b"), after: 32)
        XCTAssertNotNil(p)
        XCTAssertLessThan(p!.bars, 32)
        XCTAssertLessThanOrEqual(p!.outEnd, a.lastBeat)
    }
    func testTempoGlide() {
        let a = track("a", bpm: 124), b = track("b", bpm: 130)
        let p = AutoMix.plan(from: a, aRate: 1, to: b, after: 0)!
        XCTAssertEqual(p.toRate, 130.0 / 124, accuracy: 1e-9)
        XCTAssertEqual(AutoMix.rate(atBar: 0, p), 1, accuracy: 1e-9)
        XCTAssertEqual(AutoMix.rate(atBar: Double(p.bars), p), 130.0 / 124, accuracy: 1e-9)
        // half time: 87 against 174 meets at 2×, no tempo change
        let h = AutoMix.plan(from: track("a", bpm: 174), aRate: 1, to: track("b", bpm: 87), after: 0)!
        XCTAssertEqual(h.mult, 0.5)
        XCTAssertEqual(h.toRate, 1, accuracy: 1e-9)
        // too far apart: no plan
        XCTAssertNil(AutoMix.plan(from: track("a", bpm: 124), aRate: 1, to: track("b", bpm: 150), after: 0))
    }

    // ---- picks ----
    func testPicksAreNotOnlyTheSameTempo() {
        let a = track("a", bpm: 124, key: A(8))
        let pool = [track("same-bpm-clash", bpm: 124, key: A(2)),
                    track("faster-same-key", bpm: 129, key: A(8)),
                    track("way-off", bpm: 150, key: A(8)),
                    track("played", bpm: 124, key: A(8))]
        var o = AutoMix.PickOptions()
        o.played = ["played"]
        let c = AutoMix.choose(after: a, aRate: 1, pool: pool, o)
        XCTAssertEqual(c.first?.track.id, "faster-same-key")
        XCTAssertFalse(c.contains { $0.track.id == "way-off" })          // over 10 %
        XCTAssertFalse(c.contains { $0.track.id == "played" })
        XCTAssertTrue(c.first!.why.contains("same key"))
    }
    func testTempoHasNoPullWithinFourPercent() {
        XCTAssertEqual(AutoMix.tempoScore(shift: 0, mult: 1, max: 0.1), AutoMix.tempoScore(shift: 0.039, mult: 1, max: 0.1), accuracy: 1e-12)
        XCTAssertLessThan(AutoMix.tempoScore(shift: 0.08, mult: 1, max: 0.1), 1)
        XCTAssertEqual(AutoMix.tempoScore(shift: 0.1, mult: 1, max: 0.1), 0.2, accuracy: 1e-9)
    }
    func testVocalOverlapCountsInPicks() {
        // two candidates alike but for vocals: one sings from its first beat to its end, so it can't come in clean
        let a = track("a", key: A(8), vocals: [(0, 360)])
        let clean = track("clean", key: A(8), vocals: [(200, 300)])
        let singer = track("singer", key: A(8), vocals: [(0, 360)])
        let c = AutoMix.choose(after: a, aRate: 1, pool: [singer, clean], AutoMix.PickOptions())
        XCTAssertEqual(c.first?.track.id, "clean")
        XCTAssertGreaterThan(c.last!.plan!.clash!, 0)
    }
    func testEnergyFlow() {
        var a = track("a", key: A(8)); a.energy = 0.5
        var up = track("up", key: A(8)); up.energy = 0.62
        var down = track("down", key: A(8)); down.energy = 0.38
        var o = AutoMix.PickOptions()
        o.flow = 1
        XCTAssertEqual(AutoMix.choose(after: a, aRate: 1, pool: [down, up], o).first?.track.id, "up")
        o.flow = -1
        XCTAssertEqual(AutoMix.choose(after: a, aRate: 1, pool: [up, down], o).first?.track.id, "down")
    }

    // ---- AI DJ v2: kinds, lengths, mix points, mix now ----
    func testEveryKindKeepsOneBassLineAndEndsClean() {
        for kd in AutoMix.Transition.allCases {
            for n in kd.lengths {
                for k in 0...(n * 20) {
                    let l = kd.levels(atBar: Double(k) / 20, of: n)
                    XCTAssertLessThanOrEqual(l.inLow + l.outLow, 0.5 + 1e-9, "\(kd) \(n) bars at \(Double(k) / 20)")
                }
                let s = kd.levels(atBar: 0, of: n), e = kd.levels(atBar: Double(n), of: n)
                XCTAssertEqual(s.inFader, 0, accuracy: 1e-9, "\(kd)"); XCTAssertEqual(s.outFader, 1, accuracy: 1e-9, "\(kd)")
                XCTAssertEqual(e.outFader, 0, accuracy: 1e-9, "\(kd)"); XCTAssertEqual(e.inFader, 1, accuracy: 1e-9, "\(kd)")
                // the next track ends up flat: full bass, EQ centred, COLOR off
                XCTAssertEqual(e.inLow, 0.5, accuracy: 1e-9, "\(kd)"); XCTAssertEqual(e.inMid, 0.5, accuracy: 1e-9, "\(kd)")
                XCTAssertEqual(e.inHi, 0.5, accuracy: 1e-9, "\(kd)"); XCTAssertEqual(e.inCfx, 0.5, accuracy: 1e-9, "\(kd)")
            }
        }
    }
    func testHighsAndLowsHandOffSeparately() {
        let t = AutoMix.Transition.eqHandoff
        let early = t.levels(atBar: 4, of: 32), mid = t.levels(atBar: 15.5, of: 32)
        XCTAssertLessThan(early.inHi, 0.3)                              // the next track's hats held back at first
        XCTAssertGreaterThan(mid.inHi, 0.45); XCTAssertLessThan(mid.outHi, 0.2)    // highs handed over before…
        XCTAssertEqual(mid.inLow, 0, accuracy: 1e-9)                    // …the lows, which wait for the halfway downbeat
        XCTAssertEqual(t.levels(atBar: 16.5, of: 32).inLow, 0.5, accuracy: 1e-9)
    }
    func testColorSweepFiltersBothSides() {
        let t = AutoMix.Transition.colorSweep
        XCTAssertGreaterThan(t.levels(atBar: 0, of: 16).inCfx, 0.53)     // in through the high-pass
        XCTAssertLessThan(t.levels(atBar: 15, of: 16).outCfx, 0.47)      // out through the low-pass
        XCTAssertEqual(t.levels(atBar: 4, of: 16).outCfx, 0.5, accuracy: 1e-9)
    }
    func testSkipsALongIntroAtTheMixInPoint() {
        var b = track("b"); b.mixIn = b.time(ofBeat: 128)               // Apple: comes in at bar 33
        let p = AutoMix.plan(from: track("a"), aRate: 1, to: b, after: 0)!
        XCTAssertEqual(p.inStart, 128)
        var o = AutoMix.PlanOptions(); o.skipIntros = false
        XCTAssertEqual(AutoMix.plan(from: track("a"), aRate: 1, to: b, after: 0, options: o)!.inStart, 0)
    }
    func testYourCueWinsOverApplesPoint() {
        var b = track("b"); b.mixIn = b.time(ofBeat: 128)
        b.setCue(b.time(ofBeat: 72))                                     // your CUE at bar 19
        XCTAssertEqual(AutoMix.plan(from: track("a"), aRate: 1, to: b, after: 0)!.inStart, 72)
        // a CUE on the first beat is rekordbox's auto cue: Apple's point stays
        var c = track("c"); c.mixIn = c.time(ofBeat: 128)
        c.setCue(c.time(ofBeat: 0))
        XCTAssertEqual(c.mixIn!, c.time(ofBeat: 128), accuracy: 1e-9)
    }
    func testMixNowStartsWithinTwoBars() {
        var o = AutoMix.PlanOptions(); o.within = 8
        let p = AutoMix.plan(from: track("a"), aRate: 1, to: track("b"), after: 101, step: 4, options: o)!
        XCTAssertGreaterThanOrEqual(p.outStart, 101); XCTAssertLessThanOrEqual(p.outStart, 109)
        // what MIX NOW did before: any bar, and the planner likes playing the track out, so minutes later
        XCTAssertGreaterThan(AutoMix.plan(from: track("a"), aRate: 1, to: track("b"), after: 101, step: 4)!.outStart, 200)
    }
    func testKindAndLengthChosenPerPair() {
        var o = AutoMix.PlanOptions(); o.kinds = AutoMix.Transition.allCases; o.variableLength = true
        // nothing in the way: the usual long bass swap
        let q = AutoMix.plan(from: track("a"), aRate: 1, to: track("b"), after: 0, options: o)!
        XCTAssertEqual(q.kind, .bassSwap); XCTAssertEqual(q.bars, 32)
        // vocals all the way through both: any blend puts them on top of each other, so a cut
        let p = AutoMix.plan(from: track("a", vocals: [(0, 360)]), aRate: 1, to: track("b", vocals: [(0, 360)]), after: 0, options: o)!
        XCTAssertEqual(p.kind, .cut)
        XCTAssertLessThan(p.clash!, 1)
        // a kind that's turned off is never used
        o.kinds = [.colorSweep]
        XCTAssertEqual(AutoMix.plan(from: track("a"), aRate: 1, to: track("b"), after: 0, options: o)!.kind, .colorSweep)
    }
    func testOutroAwareStart() {
        var a = track("a"); a.mixOut = a.time(ofBeat: 512)               // outro from bar 129
        let p = AutoMix.plan(from: a, aRate: 1, to: track("b"), after: 0)!
        XCTAssertEqual(p.outStart, 512)
    }
}
