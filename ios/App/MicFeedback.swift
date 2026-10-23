// Watch mic (personal/heat only): feedback suppression for the watch's voice, run on the network queue at 24 kHz
// before the voice reaches the mix. A 100 Hz high-pass takes out rumble and handling noise. Then a detector looks
// for howl: a narrow peak at least 25 dB above the spectrum around it that holds the same pitch and doesn't fade
// for about 200 ms. Voice drifts and decays, feedback holds or grows. Each one found gets a narrow notch (up to 8;
// the oldest goes when a ninth is needed). Notches stay until Reset or until Listen is turned off.
import Accelerate
import Foundation

final class MicFeedback {
    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
        /// RBJ cookbook
        static func make(_ kind: Int, _ f: Double, _ q: Double, _ fs: Double) -> Biquad {
            let w = 2 * Double.pi * f / fs, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
            var b = Biquad()
            if kind == 0 { b.b0 = Float((1 + c) / 2 / a0); b.b1 = Float(-(1 + c) / a0); b.b2 = b.b0 }   // high-pass
            else { b.b0 = Float(1 / a0); b.b1 = Float(-2 * c / a0); b.b2 = b.b0 }                       // notch
            b.a1 = Float(-2 * c / a0); b.a2 = Float((1 - al) / a0)
            return b
        }
    }

    static let maxNotches = 8
    private let fs: Double
    private var hp: Biquad
    private var notches: [(f: Double, q: Biquad)] = []
    // detector
    private let n = 1024, hop = 512
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var hist: [Float]
    private var filled = 0
    private var candBin = -1, candFrames = 0, candLevel: Float = -200
    /// the notch frequencies, for the screen (read on the main queue through onChange)
    var onChange: (([Double]) -> Void)?

    init(rate: Double) {
        fs = rate
        hp = .make(0, 100, 0.707, rate)
        fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
        hist = [Float](repeating: 0, count: 1024)
    }

    func reset() {
        notches.removeAll(); candBin = -1; candFrames = 0; filled = 0
        onChange?([])
    }

    /// in place: high-pass, notches, and (when `detect`) the howl detector on the result
    func process(_ x: inout [Float], detect: Bool) {
        for i in x.indices {
            var v = hp.run(x[i])
            for k in notches.indices { v = notches[k].q.run(v) }
            x[i] = v
        }
        guard detect else { return }
        for v in x {
            hist[filled] = v; filled += 1
            if filled == n {
                analyse()
                hist.replaceSubrange(0..<(n - hop), with: hist[hop..<n])   // keep the newest half
                filled = n - hop
            }
        }
    }

    private func analyse() {
        let w = vDSP.multiply(hist, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2), mag = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBytes { wb in vDSP_ctoz(wb.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2)) }
                let input = split                                   // in place; a copy of the pointers, so no overlapping access
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &mag)
            }
        }
        // dB, with a floor so silence doesn't count
        let db = mag.map { 10 * log10(max($0, 1e-12)) }
        let binHz = fs / Double(n)
        let lo = max(9, Int(150 / binHz)), hi = min(n / 2 - 9, Int(8000 / binHz))
        var best = -1, bestDb: Float = -200
        for b in lo...hi where db[b] > bestDb { best = b; bestDb = db[b] }
        guard best > 0 else { return }
        // around the peak: average of bins 3...8 away on both sides (lo/hi keep these inside the array)
        var s: Float = 0
        for d in 3...8 { s += db[best - d] + db[best + d] }
        let around = s / 12
        // the absolute floor: ignore anything near the noise (full-scale sine ≈ +48 dB here)
        let howl = bestDb - around >= 25 && bestDb > -10
        if howl && candBin >= 0 && abs(best - candBin) <= 1 && bestDb >= candLevel - 1 {
            candFrames += 1
        } else {
            candFrames = howl ? 1 : 0
        }
        candBin = howl ? best : -1
        candLevel = bestDb
        // ~10 frames of 21 ms ≈ 200 ms
        guard candFrames >= 10 else { return }
        candFrames = 0; candBin = -1
        // parabolic interpolation for the true frequency
        let a = db[best - 1], b = db[best], c = db[best + 1], den = a - 2 * b + c
        let off = den != 0 ? Double(0.5 * (a - c) / den) : 0
        let f = (Double(best) + off) * binHz
        if notches.contains(where: { abs($0.f - f) < f / 30 }) { return }
        if notches.count >= MicFeedback.maxNotches { notches.removeFirst() }
        notches.append((f, .make(1, f, 30, fs)))
        onChange?(notches.map(\.f))
    }
}
