import XCTest
@testable import CrateboxKit

/// The Swift deck player and FX unit against the web app's own (Fixtures/dsp, rendered in node by
/// ios/tools/dsp_oracle.js from cratebox.html's WORKLET): same scenarios, same samples.
final class DSPTests: XCTestCase {
    let SR = 44100.0
    func data(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/dsp/" + name, withExtension: nil)!) }
    func floats(_ name: String) throws -> [Float] {
        let d = try data(name)
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func runScenario(_ name: String, _ sc: [String: Any], _ sig: (l: [Float], r: [Float])) throws -> (maxErr: Float, at: Int, n: Int) {
        let blocks = sc["blocks"] as! Int, input = sc["input"] as! Bool, proc = sc["proc"] as! String
        let steps = sc["steps"] as! [[String: Any]]
        let want = try floats(name + ".f32")
        let total = blocks * 128
        var outL = [Float](repeating: 0, count: total), outR = [Float](repeating: 0, count: total)
        let deck = DeckPlayer(sampleRate: SR), fx = FxUnit(sampleRate: SR)
        let track = PCMTrack(left: sig.l, right: sig.r, sampleRate: SR)
        let num = { (m: [String: Any], k: String) -> Double? in (m[k] as? NSNumber)?.doubleValue }
        var bl = [Float](repeating: 0, count: 128), br = [Float](repeating: 0, count: 128)
        for b in 0..<blocks {
            let time = Double(b * 128) / SR
            for s in steps where s["block"] as! Int == b {
                let m = s["msg"] as! [String: Any], t = m["t"] as! String
                if proc == "deck-player" {
                    switch t {
                    case "load": deck.setTrack(track); deck.handle(.load(mt: m["mt"] as? Bool, spin: num(m, "spin")))
                    case "play": deck.handle(.play(m["v"] as! Bool))
                    case "rate": deck.handle(.rate(num(m, "v")!))
                    case "seek": deck.handle(.seek(num(m, "v")!, seq: 0))
                    case "bend": deck.handle(.bend(num(m, "v")!))
                    case "scratch": deck.handle(.scratch(m["v"] as! Bool, noCoast: (m["noCoast"] as? Bool) ?? false))
                    case "jog": deck.handle(.jog(num(m, "v")!))
                    case "loop": deck.handle(.loop(on: m["on"] as! Bool, a: num(m, "a")!, b: num(m, "b")!))
                    case "mt": deck.handle(.mt(m["v"] as! Bool))
                    default: XCTFail("unknown deck message \(t)")
                    }
                } else {
                    if t == "clock" { fx.clock = FxClock(t0: num(m, "t0")!, beat0: num(m, "beat0")!, bps: num(m, "bps")!, spb: num(m, "spb")!) }
                    else {
                        let slot = (m["slot"] as! String) == "beat" ? fx.beat : fx.pad
                        slot.set(fx: (m["fx"] as? String).flatMap { FxKind(rawValue: $0) }, beats: num(m, "beats"), depth: num(m, "depth"), on: m["on"] as? Bool)
                    }
                }
            }
            if proc == "deck-player" { deck.render(&bl, &br, 128) }
            else {
                for i in 0..<128 { bl[i] = input ? sig.l[b * 128 + i] : 0; br[i] = input ? sig.r[b * 128 + i] : 0 }
                fx.process(&bl, &br, 128, time: time)
            }
            for i in 0..<128 { outL[b * 128 + i] = bl[i]; outR[b * 128 + i] = br[i] }
        }
        var maxErr: Float = 0, at = -1
        for i in 0..<total {
            let e = max(abs(outL[i] - want[i]), abs(outR[i] - want[total + i]))
            if e > maxErr { maxErr = e; if at < 0 && e > 1e-4 { at = i } }
        }
        return (maxErr, at, total)
    }

    func testMatchesTheWebApp() throws {
        let all = try floats("signal.f32"), half = all.count / 2
        let sig = (Array(all[0..<half]), Array(all[half...]))
        let index = try JSONSerialization.jsonObject(with: try data("scenarios.json")) as! [String: [String: Any]]
        XCTAssertEqual(index.count, 15)
        for name in index.keys.sorted() {
            let r = try runScenario(name, index[name]!, sig)
            print("DSP \(name): max error \(r.maxErr) (first > 1e-4 at sample \(r.at)) over \(r.n) samples")
            XCTAssertLessThan(r.maxErr, 1e-4, "\(name): differs from the web app, first at sample \(r.at)")
        }
    }
    /// tap on an EQ knob: centre → kill (silent), anywhere else (killed, boosted, a little off) → centre
    func testEqTapKillsAtTheCentreAndCentresOtherwise() {
        XCTAssertEqual(MixerCurves.eqTap(0.5), 0)
        XCTAssertEqual(MixerCurves.eqGain(MixerCurves.eqTap(0.5)), 0)
        for v in [0.0, 0.2, 0.48, 0.52, 1.0] { XCTAssertEqual(MixerCurves.eqTap(v), 0.5) }
        XCTAssertEqual(MixerCurves.eqGain(0.5), 1, accuracy: 1e-12)
    }
}
