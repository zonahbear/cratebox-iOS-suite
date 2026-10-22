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
}
