import XCTest
@testable import CrateboxKit

/// The two analysis speed-ups against what they replace: Accelerate's FFT against the radix-2 loop (the JS port),
/// and the block-at-a-time downmix against `monoFor` on the whole track.
final class AnalysisSpeedTests: XCTestCase {
    func testAccelerateFFTMatchesTheLoop() {
        var rng = SystemRandomNumberGenerator()
        for n in [512, 8192] {
            let t = Analysis.FFTTables(n)
            let re0 = (0..<n).map { _ in Double.random(in: -1...1, using: &rng) }, im0 = (0..<n).map { _ in Double.random(in: -1...1, using: &rng) }
            var ra = re0, ia = im0, rb = re0, ib = im0
            Analysis.useAccelerate = false; Analysis.fft(&ra, &ia, t)
            Analysis.useAccelerate = true; Analysis.fft(&rb, &ib, t)
            var worst = 0.0
            for k in 0..<n { worst = max(worst, abs(ra[k] - rb[k]), abs(ia[k] - ib[k])) }
            print("DSP fft \(n): largest difference loop vs vDSP \(worst)")
            XCTAssertLessThan(worst, 1e-9, "fft \(n)")
        }
    }

    func testMonoAccumulatorMatchesMonoFor() {
        let n = 100_003
        let l = (0..<n).map { Float(sin(Double($0) * 0.013)) * 0.7 }, r = (0..<n).map { Float(cos(Double($0) * 0.029)) * 0.5 }
        for (sr, blocks) in [(48000.0, [1, 3, 4, 7, 4096, 48000]), (44100.0, [5, 1024]), (11025.0, [2])] {
            let want = l.withUnsafeBufferPointer { a in r.withUnsafeBufferPointer { b in
                Analysis.monoFor([a.baseAddress!, b.baseAddress!], length: n, sampleRate: sr) } }
            for bs in blocks {
                var acc = Analysis.MonoAccumulator(sampleRate: sr)
                var i = 0
                l.withUnsafeBufferPointer { a in r.withUnsafeBufferPointer { b in
                    while i < n { let c = min(bs, n - i); acc.add(a.baseAddress! + i, b.baseAddress! + i, count: c); i += c }
                } }
                XCTAssertEqual(acc.fs, want.fs, "\(sr) \(bs)")
                XCTAssertEqual(acc.frames, n)
                XCTAssertEqual(acc.out, want.mono, "same samples, \(sr) Hz in blocks of \(bs)")
            }
        }
    }

    /// Whole-track timing with and without Accelerate on the synthetic tracks (printed for the CI summary), and
    /// the two must give the same grid, key and phrases.
    func testAnalysisSpeed() throws {
        guard let dir = ProcessInfo.processInfo.environment["CRATEBOX_MUSIC"] else { throw XCTSkip("CRATEBOX_MUSIC not set") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted().prefix(4)
        defer { Analysis.useAccelerate = true }
        for name in names {
            let (chs, sr) = try AnalysisTests.wav(URL(fileURLWithPath: dir).appendingPathComponent(name))
            let (mono, fs) = chs[0].withUnsafeBufferPointer { a in chs[chs.count > 1 ? 1 : 0].withUnsafeBufferPointer { b in
                Analysis.monoFor([a.baseAddress!, b.baseAddress!], length: chs[0].count, sampleRate: sr) } }
            var res = [AnalysisResult](), secs = [Double]()
            for acc in [false, true] {
                Analysis.useAccelerate = acc
                let t0 = Date()
                res.append(Analysis.analyze(mono, fs: fs, noWave: true))
                secs.append(Date().timeIntervalSince(t0))
            }
            print("ANALYSIS speed \(name): loop \(String(format: "%.3f", secs[0])) s, vDSP \(String(format: "%.3f", secs[1])) s")
            XCTAssertEqual(res[0].bpm, res[1].bpm, accuracy: 1e-9, name)
            XCTAssertEqual(res[0].firstBeat, res[1].firstBeat, accuracy: 1e-6, name)
            XCTAssertEqual(res[0].key, res[1].key, name)
            XCTAssertEqual(res[0].phrases.map { $0.bars }, res[1].phrases.map { $0.bars }, name)
        }
    }
}
