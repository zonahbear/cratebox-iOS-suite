import XCTest
@testable import CrateboxKit

/// The mixer and engine, by measurement: tones through a deck, then what comes out where.
final class EngineTests: XCTestCase {
    let SR = 44100.0
    func tone(_ hz: Double, _ secs: Double = 2, amp: Float = 0.5) -> PCMTrack {
        let n = Int(secs * SR)
        let t = PCMTrack(count: n, sampleRate: SR)
        for i in 0..<n { let v = amp * Float(sin(2 * Double.pi * hz * Double(i) / SR)); t.left[i] = v; t.right[i] = v }
        return t
    }
    /// RMS of each output channel over `secs` after `skip` seconds
    func run(_ e: Engine, channels: Int = 2, skip: Double = 0.3, secs: Double = 0.5) -> [Double] {
        let n = 512
        let outs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { outs.forEach { $0.deallocate() } }
        var sums = [Double](repeating: 0, count: channels), cnt = 0
        for b in 0..<Int((skip + secs) * SR) / n {
            e.render(outs, n)
            if Double(b * n) >= skip * SR { for c in 0..<channels { for j in 0..<n { sums[c] += Double(outs[c][j]) * Double(outs[c][j]) } }; cnt += n }
        }
        return sums.map { ($0 / Double(max(cnt, 1))).squareRoot() }
    }
    func engine(_ hz: Double, deck: Int = 0, _ m: (inout MixerState) -> Void = { _ in }) -> Engine {
        let e = Engine(sampleRate: SR)
        var ms = MixerState(); m(&ms)
        e.post([.track(deck, tone(hz)), .deck(deck, .load(mt: false, spin: nil)), .mixer(ms), .deck(deck, .play(true))])
        return e
    }
    func testPlaysThrough() {
        let r = run(engine(440))
        XCTAssertGreaterThan(r[0], 0.2); XCTAssertGreaterThan(r[1], 0.2)
    }
    func testEqKillsEachBand() {
        for (hz, band) in [(80.0, "low"), (900.0, "mid"), (8000.0, "hi")] {
            let open = run(engine(hz))[0]
            let killed = run(engine(hz) { m in if band == "low" { m.low[0] = 0 } else if band == "mid" { m.mid[0] = 0 } else { m.hi[0] = 0 } })[0]
            print("ENGINE eq \(band) kill at \(hz) Hz: \(20 * log10(killed / open)) dB")
            XCTAssertLessThan(killed / open, 0.12, "\(band) kill")       // about -18 dB or more at the band's centre
        }
    }
    func testCrossfaderAndHiddenDecks() {
        XCTAssertLessThan(run(engine(440) { $0.xfader = 1 })[0], 0.001, "deck 1 gone with the crossfader on the right")
        XCTAssertGreaterThan(run(engine(440, deck: 1) { $0.xfader = 1 })[0], 0.2, "deck 2 still there")
        XCTAssertLessThan(run(engine(440, deck: 2))[0], 0.001, "deck 3 muted while 4-deck mode is off")
        XCTAssertGreaterThan(run(engine(440, deck: 2) { $0.active = [true, true, true, true] })[0], 0.2, "deck 3 plays in 4-deck mode")
    }
    func testHeadphonesOnThreeAndFour() {
        let e = engine(440) { $0.pfl[0] = true; $0.fader[0] = 0 }
        e.post(.output(.quad))
        let r = run(e, channels: 4)
        print("ENGINE quad: master \(r[0]) \(r[1]), headphones \(r[2]) \(r[3])")
        XCTAssertLessThan(r[0], 0.001, "fader down: nothing on the master")
        XCTAssertGreaterThan(r[2], 0.2, "CUE: in the headphones (pre-fader)")
        let e2 = engine(440) { $0.headMix = 1 }
        e2.post(.output(.quad))
        let r2 = run(e2, channels: 4)
        XCTAssertGreaterThan(r2[2], 0.2, "CUE/MASTER right: master in the headphones")
        XCTAssertGreaterThan(r2[0], 0.2)
    }
    func testLimiterHoldsTheMaster() {
        let e = engine(440) { $0.trim[0] = 1; $0.hi[0] = 1; $0.mid[0] = 1; $0.low[0] = 1; $0.master = 1 }
        let n = 512, outs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { outs.forEach { $0.deallocate() } }
        var peak: Float = 0
        for b in 0..<200 { e.render(outs, n); if b > 20 { for j in 0..<n { peak = max(peak, abs(outs[0][j])) } } }
        print("ENGINE limiter peak \(peak)")
        XCTAssertLessThan(peak, 1.05)
    }
    func testReportsPosition() {
        let e = engine(440)
        _ = run(e, skip: 0, secs: 1)
        let s = e.snapshot()
        XCTAssertTrue(s.decks[0].playing)
        XCTAssertEqual(s.decks[0].pos / SR, s.time, accuracy: 0.05)
    }
}
