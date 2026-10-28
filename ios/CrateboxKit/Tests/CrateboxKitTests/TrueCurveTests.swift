import XCTest
@testable import CrateboxKit

// TrueCurve mini: expected numbers come from running cratebox.html's TC code in node (makeCurve, Driver,
// the simulator's plant) and Node's crypto for the unlock token.
final class TrueCurveTests: XCTestCase {
    typealias TC = TrueCurve
    let banger = TC.preset("Quartz Banger")!

    func testCurveMatchesWeb() {
        let c = TC.Curve(banger.points, smooth: true)!
        XCTAssertEqual(c.end, 65)
        for (t, f) in [(0.0, 520.0), (10, 508), (25, 485), (45, 462), (65, 450), (5, 515.669), (30, 478.424)] { XCTAssertEqual(c.at(t), f, accuracy: 0.001, "t=\(t)") }
        XCTAssertEqual(c.slope(5), -1.4661, accuracy: 1e-4)
        XCTAssertEqual(c.slope(30), -1.2954, accuracy: 1e-4)
        let lin = TC.Curve(banger.points, smooth: false)!
        XCTAssertEqual(lin.at(5), 514, accuracy: 0.001)
        XCTAssertEqual(lin.at(30), 479.25, accuracy: 0.001)
        XCTAssertEqual(c.at(-5), 520); XCTAssertEqual(c.at(99), 450)
        XCTAssertNil(TC.Curve([.init(t: 3, f: 500), .init(t: 3, f: 510)], smooth: true))
    }

    func testCurveNeverOvershoots() {
        for p in TC.presets {
            let def = TC.preset(p.name)!, c = TC.Curve(def.points, smooth: true)!
            for i in 0..<(def.points.count - 1) {
                let a = def.points[i], b = def.points[i + 1], lo = min(a.f, b.f) - 1e-9, hi = max(a.f, b.f) + 1e-9
                for k in 0...20 { let v = c.at(a.t + (b.t - a.t) * Double(k) / 20); XCTAssert(v >= lo && v <= hi, "\(p.name) \(v)") }
            }
        }
    }

    func testDriverStaysInSafeBand() {
        let c = TC.Curve(banger.points, smooth: true)!
        var d = TC.Driver(c, TC.HeaterModel())
        for k in 0..<400 {
            let t = Double(k) * 0.2, r = c.at(t)
            for y in [nil, 70.0, r - 50, r, r + 50, 640] {
                let u = d.command(t, y, 0.2)
                XCTAssert(u >= max(TC.minF, r - 40) - 1e-9 && u <= min(TC.maxF, r + 30) + 1e-9)
            }
        }
    }

    /// the runner's loop against the simulator: preheat, then 5 Hz commands with the web app's send rules
    func testClosedLoopTracksQuartzBanger() {
        let c = TC.Curve(banger.points, smooth: true)!
        var sim = TC.SimHeater(), drv = TC.Driver(c, TC.HeaterModel()), learner = TC.Learner(TC.HeaterModel())
        sim.slots[3] = (520, 75); sim.slotIdx = 3; sim.start()
        func adv(_ dt: Double) { for _ in 0..<Int((dt / 0.05).rounded()) { sim.advance(0.05) } }
        var pt = 0.0
        while sim.y < 512 && pt < 70 { adv(0.25); pt += 0.25 }
        XCTAssertLessThan(pt, 60, "preheat")
        var sent = 520.0, sentAt = -9.0, err = 0.0, n = 0.0, worst = 0.0, t = 0.0
        while t < c.end {
            let y = (sim.y * 10).rounded() / 10, u = (drv.command(t, y, 0.2) * 10).rounded() / 10, diff = abs(u - sent)
            if diff >= 1.5 || (diff >= 0.5 && t - sentAt > 1.5) { sim.setLiveTarget(u); sent = u; sentAt = t }
            learner.add(t, y, sent)
            if t > 1 { let e = abs(y - c.at(t)); err += e; n += 1; worst = max(worst, e) }
            XCTAssertLessThan(y, TC.cutoffF)
            adv(0.2); t += 0.2
        }
        // node gives 0.27 average, 4.2 worst
        XCTAssertLessThan(err / n, 2)
        XCTAssertLessThan(worst, 10)
        XCTAssertTrue(TC.heating.contains(sim.state), "the device should still be in its cycle")
        XCTAssert(learner.m.tau.isFinite && learner.m.heatMax.isFinite && learner.m.coolK.isFinite)
    }

    func testPasteFromTrueCurve() {
        let txt = #" {"Mine": {"points": [{"t": 0, "f": 700}, {"t": "20", "f": 480}, {"t": 999, "f": 300}, {"t": "x", "f": 1}], "smooth": false},"#
            + #" "Bad": {"points": [{"t": 0, "f": 500}]}, "A name that is far too long for the menu": {"points": [{"t": 0, "f": 500}, {"t": 9, "f": 510}]}} "#
        let got = TC.parseCurves(txt)!
        XCTAssertEqual(got["Mine"], TC.CurveDef(points: [.init(t: 0, f: 590), .init(t: 20, f: 480), .init(t: 110, f: 350)], smooth: false))
        XCTAssertNil(got["Bad"])
        XCTAssertEqual(got["A name that is far too l"]?.smooth, true)
        XCTAssertEqual(got.count, 2)
        XCTAssertNil(TC.parseCurves("not json"))
    }

    func testLoraxBytes() {
        XCTAssertEqual(Lorax.token(seed: Array(0..<16)), hex("cc4af4246a24eb8bb512bc7dc5157b9c"))
        XCTAssertEqual(Lorax.encodeC(TC.fToC(520), .f32), hex("398e8743"))
        XCTAssertEqual(Lorax.encodeC(TC.fToC(520), .i10), hex("970a0000"))
        XCTAssertEqual(Lorax.decodeC(hex("398e8743"), fmt: .f32)!, 271.111, accuracy: 0.001)
        XCTAssertEqual(Lorax.decodeC(hex("970a0000"), fmt: .i10), 271.1)
        XCTAssertEqual(Lorax.decodeC(hex("970a0000"), fmt: nil), 271.1)   // a tiny denormal float: read as tenths
        XCTAssertEqual(Lorax.readPayload("/p/x", max: 4), [0, 0, 4, 0] + Array("/p/x".utf8))
        XCTAssertEqual(Lorax.writePayload("/p/x", [9]), [0, 0, 0] + Array("/p/x".utf8) + [0, 9])
        XCTAssertEqual(Lorax.frame(seq: 0x0102, op: 16, [7]), [2, 1, 16, 7])
        XCTAssertEqual(Lorax.detectFormat(hex("398e8743"), isProxy: true), .f32)
        XCTAssertEqual(Lorax.detectFormat(hex("970a0000"), isProxy: false), .i10)
        XCTAssertEqual(Lorax.detectFormat(nil, isProxy: true), .i10)
        var soc = Lorax.SocDecoder()
        XCTAssertEqual(soc.decode(Lorax.f32Bytes(0.87)), 87)
        XCTAssertEqual(soc.decode([0x12, 0x02, 0, 0]), 53)   // 530 = 53.0 %
        XCTAssertEqual(soc.decode([53]), 5)                  // the scale sticks once seen
    }

    func hex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! } }

    /// PUFF: a HOLD at 500°F on the simulator; resting reads nothing, a hard draw reads a lot, and letting go
    /// lets go within a couple of seconds
    func testPuffDropFollowsADraw() {
        var h = TC.SimHeater(), m = TC.PuffDrop(hold: 500)
        h.slots[0] = (500, 120); h.y = 495; h.start()
        var t = 0.0, peak = 0.0, rest = 0.0, after = 1.0
        var noise = SystemRandomNumberGenerator()
        while t < 25 {
            h.airflow = t >= 10 && t < 14 ? 1 : 0
            for _ in 0..<10 { h.advance(0.01) }
            t += 0.1
            let a = m.add(t, h.y + Double.random(in: -0.6...0.6, using: &noise))
            if t < 10 && t > 2 { rest = max(rest, a) }
            if t >= 10 && t < 14 { peak = max(peak, a) }
            if t > 17 { after = min(after, a) }
        }
        XCTAssertEqual(rest, 0, "noise at rest isn't a hit")
        XCTAssertGreaterThan(peak, 0.9)
        XCTAssertEqual(after, 0, "the warble lets go once the draw stops")
    }

    /// a gentle inhale only dips the bowl ~4°F; Auto still makes a real warble of it
    func testPuffGentleInhaleStillWarbles() {
        var h = TC.SimHeater(), m = TC.PuffDrop(hold: 500)
        h.slots[0] = (500, 120); h.y = 495; h.start()
        var t = 0.0, peak = 0.0, rest = 0.0
        while t < 15 {
            h.airflow = t >= 10 && t < 14 ? 0.15 : 0
            for _ in 0..<10 { h.advance(0.01) }
            t += 0.1
            let a = m.add(t, h.y + Double.random(in: -0.6...0.6))
            if t < 10 && t > 2 { rest = max(rest, a) }
            if t >= 10 { peak = max(peak, a) }
        }
        XCTAssertEqual(rest, 0)
        XCTAssertGreaterThan(peak, 0.4)
    }

    func testPuffWarbleStaysFinite() {
        let sr = 48000.0, fx = FxUnit(sampleRate: sr), n = 128
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        fx.beat.set(fx: .puff, depth: 1, on: true, mod: 1)
        var k = 0, energy = 0.0
        for b in 0..<400 {
            for i in 0..<n { let v = Float(sin(Double(k) * 2 * .pi * 440 / sr)) * 0.5; l[i] = v; r[i] = v; k += 1 }
            fx.process(l, r, n, time: Double(b * n) / sr)
            // the tone (0.5) plus the theremin voice (at most 0.22 × 1.18)
            for i in 0..<n { XCTAssertTrue(l[i].isFinite && abs(l[i]) <= 0.78); energy += Double(l[i] * l[i]) }
        }
        XCTAssertGreaterThan(energy, 1000, "the tone still comes through")
    }

    /// PUFF is a theremin: silence in, its voice is the only sound; a hard hit sings ≈ 880 Hz (A5), a light one
    /// lower and quieter, no hit nothing (same check as Cratebox OS's puff_sings_higher_the_harder_the_hit)
    func testPuffSingsHigherTheHarderTheHit() {
        func pitch(_ hit: Double) -> (Double, Float) {
            let sr = 48000.0, fx = FxUnit(sampleRate: sr), n = 128
            let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { l.deallocate(); r.deallocate() }
            fx.beat.set(fx: .puff, depth: 1, on: true, mod: hit)
            var last: [Float] = []
            for b in 0..<(4 * 375) {         // 4 s; keep the last second
                for i in 0..<n { l[i] = 0; r[i] = 0 }
                fx.process(l, r, n, time: Double(b * n) / sr)
                if b >= 3 * 375 { last += (0..<n).map { l[$0] } }
            }
            let peak = last.map { abs($0) }.max() ?? 0
            let up = zip(last, last.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count
            return (Double(up), peak)
        }
        let (soft, softPeak) = pitch(0.2), (hard, hardPeak) = pitch(1)
        XCTAssertTrue((780.0..<980.0).contains(hard), "hard hit ≈ 880 Hz: \(hard)")
        XCTAssertTrue(soft < hard * 0.6 && softPeak < hardPeak, "soft \(soft) Hz / \(softPeak), hard \(hard) Hz / \(hardPeak)")
        XCTAssertLessThan(pitch(0).1, 1e-4, "no hit, no voice")
    }

    /// GLOW: louder is brighter, the rainbow moves, the knob down dims it; the lantern bytes
    func testGlowBreathesWithTheMusic() {
        var g = TC.Glow()
        var quiet: [UInt8] = [0, 0, 0], loud: [UInt8] = [0, 0, 0], low: [UInt8] = [0, 0, 0]
        for _ in 0..<100 { quiet = g.color(0.05, level: 0, knob: 0.5, what: .intensity) }
        for _ in 0..<20 { loud = g.color(0.05, level: 0.9, knob: 0.5, what: .intensity) }
        XCTAssertGreaterThan(Int(loud.max()!), Int(quiet.max()!) * 2, "louder is brighter: \(quiet) \(loud)")
        let h0 = g.hue
        for _ in 0..<100 { _ = g.color(0.05, level: 0.5, knob: 0.5, what: .intensity) }
        XCTAssertNotEqual(g.hue, h0, "the rainbow moves")
        for _ in 0..<100 { low = g.color(0.05, level: 1, knob: 0, what: .intensity) }
        XCTAssertLessThan(low.max()!, 60, "knob down = dim: \(low)")
        XCTAssertEqual(Lorax.lanternColor([1, 2, 3]), [1, 2, 3, 0, 1, 0, 0, 0])
        // at most 5 a second
        var t = TC.Glow(), sent = 0
        for i in 0..<100 { if t.tick(Double(i) * 0.05, level: Double(i % 7) / 7, knob: 1, what: .speed) != nil { sent += 1 } }
        XCTAssertLessThanOrEqual(sent, 26)
        XCTAssertGreaterThan(sent, 3)
    }
}
