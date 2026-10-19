import XCTest
@testable import CrateboxKit

/// Track analysis against the web app's (Fixtures/analysis.json, from ios/tools/analysis_oracle.js) on the
/// synthetic test tracks. CI makes the tracks with tests/make_tracks.py and checks they're the same files
/// (Fixtures/music.md5); the folder comes in as CRATEBOX_MUSIC.
final class AnalysisTests: XCTestCase {
    func wav(_ url: URL) throws -> (chs: [[Float]], sr: Double) {
        let b = [UInt8](try Data(contentsOf: url))
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var o = 12, fmt = 0, data = 0, size = 0
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<(o + 4)], encoding: .ascii)!, sz = u32(o + 4)
            if id == "fmt " { fmt = o + 8 }
            if id == "data" { data = o + 8; size = sz; break }
            o += 8 + sz + (sz & 1)
        }
        let ch = u16(fmt + 2), sr = Double(u32(fmt + 4)), n = size / (2 * ch)
        var chs = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
        for i in 0..<n { for c in 0..<ch { chs[c][i] = Float(Int16(truncatingIfNeeded: u16(data + 2 * (i * ch + c)))) / 32768 } }
        return (chs, sr)
    }

    func testMatchesTheWebApp() throws {
        guard let dir = ProcessInfo.processInfo.environment["CRATEBOX_MUSIC"] else { throw XCTSkip("CRATEBOX_MUSIC not set") }
        let url = Bundle.module.url(forResource: "Fixtures/analysis.json", withExtension: nil)!
        let want = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: [String: Any]]
        XCTAssertEqual(want.count, 4)
        for name in want.keys.sorted() {
            let w = want[name]!
            let (chs, sr) = try wav(URL(fileURLWithPath: dir).appendingPathComponent(name))
            let ptrs = chs.map { c -> UnsafeMutablePointer<Float> in let p = UnsafeMutablePointer<Float>.allocate(capacity: c.count); p.initialize(from: c, count: c.count); return p }
            defer { ptrs.forEach { $0.deallocate() } }
            let t0 = Date()
            let (mono, fs) = Analysis.monoFor(ptrs.map { UnsafePointer($0) }, length: chs[0].count, sampleRate: sr)
            let r = Analysis.analyze(mono, fs: fs)
            let secs = Date().timeIntervalSince(t0)
            let num = { (k: String) in (w[k] as! NSNumber).doubleValue }
            XCTAssertEqual(mono.count, w["n"] as! Int, name)
            XCTAssertEqual(mono.reduce(0.0) { $0 + Double($1) }, num("monoSum"), accuracy: 1e-6, name)
            let wantPh = (w["phrases"] as! [[String: Any]]).map { Phrase(start: ($0["start"] as! NSNumber).doubleValue, bars: $0["bars"] as! Int, label: $0["label"] as! String) }
            print("ANALYSIS \(name): bpm \(r.bpm) (web \(num("bpm"))), first beat \(r.firstBeat) (web \(num("firstBeat"))), key \(r.key) (web \(w["key"]!)), phrases \(r.phrases.map { "\($0.label) \($0.bars)" }) (web \(wantPh.map { "\($0.label) \($0.bars)" })), \(String(format: "%.2f", secs)) s")
            XCTAssertEqual(r.bpm, num("bpm"), accuracy: 1e-9, name)
            XCTAssertEqual(r.firstBeat, num("firstBeat"), accuracy: 1e-6, name)
            XCTAssertEqual(r.gridConf, num("gridConf"), accuracy: 1e-6, name)
            XCTAssertEqual(r.key, w["key"] as! Int, name)
            XCTAssertEqual(r.keyConf, num("keyConf"), accuracy: 1e-6, name)
            XCTAssertEqual(r.phrases.count, wantPh.count, name)
            for (a, b) in zip(r.phrases, wantPh) { XCTAssertEqual(a.label, b.label, name); XCTAssertEqual(a.bars, b.bars, name); XCTAssertEqual(a.start, b.start, accuracy: 1e-6, name) }
            let ww = w["wave"] as! [String: [Int]], wv = r.wave!
            for (k, got) in [("peak", wv.peak), ("rms", wv.rms), ("low", wv.low), ("mid", wv.mid), ("high", wv.high)] {
                let exp = ww[k]!
                XCTAssertEqual(got.count, exp.count, "\(name) \(k)")
                let off = zip(got, exp).filter { Int($0) != $1 }.count
                print("ANALYSIS \(name) wave \(k): \(off) of \(exp.count) bytes differ")
                XCTAssertEqual(off, 0, "\(name) waveform \(k)")
            }
        }
    }
}
