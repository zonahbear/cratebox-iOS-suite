// Track analysis: BPM and beat grid, phrases, key and the waveform. A line-by-line port of the web app's
// ANALYZER (cratebox.html), so a track gets the same grid, key and phrases on iOS as in the browser;
// tested against the JS on the synthetic test tracks (Fixtures/analysis.json, ios/tools/analysis_oracle.js).
// Where the JS keeps numbers in a Float32Array, this keeps them in [Float] (same rounding).
import Foundation

public struct Phrase: Equatable, Codable { public var start: Double; public var bars: Int; public var label: String }

public struct Waveform: Equatable {
    public var duration: Double, wps: Int
    public var peak: [UInt8], rms: [UInt8], low: [UInt8], mid: [UInt8], high: [UInt8]
}

public struct AnalysisResult {
    public var wave: Waveform?
    public var bpm: Double, firstBeat: Double, gridConf: Double
    public var key: Int, keyConf: Double
    public var phrases: [Phrase]
}

// JS Array.prototype.sort is stable; Swift's sort isn't guaranteed to be
extension Array {
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset) }.map { $0.element }
    }
}
@inline(__always) func jsFloor(_ x: Double) -> Double { x.rounded(.down) }
@inline(__always) func jsCeil(_ x: Double) -> Double { x.rounded(.up) }

public enum Analysis {
    /// The app's downmix before analysis: mono, decimated by whole samples to about `target` Hz.
    public static func monoFor(_ chs: [UnsafePointer<Float>], length: Int, sampleRate: Double, target: Double = 11025) -> (mono: [Float], fs: Double) {
        let f = max(1, Int(jsRound(sampleRate / target)))
        let n = length / f
        var out = [Float](repeating: 0, count: n)
        let use = Array(chs.prefix(2))
        let k = 1 / Double(f * use.count)
        for i in 0..<n {
            var s = 0.0
            for ch in use { for j in 0..<f { s += Double(ch[i * f + j]) } }
            out[i] = Float(s * k)
        }
        return (out, sampleRate / Double(f))
    }

    public static func analyze(_ x: [Float], fs: Double, range: (Double, Double) = (88, 176), waveSource: (x: [Float], fs: Double)? = nil,
                               noWave: Bool = false, grid: (bpm: Double, firstBeat: Double)? = nil) -> AnalysisResult {
        let wave = noWave ? nil : waveform(waveSource?.x ?? x, waveSource?.fs ?? fs)
        let g = grid.map { (bpm: $0.bpm, firstBeat: $0.firstBeat, conf: 0.0) } ?? beatGrid(x, fs, range)
        let phrases = phraseAnalysis(x, fs, g.bpm, g.firstBeat)
        let k = detectKey(x, fs)
        return AnalysisResult(wave: wave, bpm: g.bpm, firstBeat: g.firstBeat, gridConf: g.conf, key: k.key, keyConf: k.keyConf, phrases: phrases)
    }

    // ---- waveform: 300 points per second, peak and RMS (the shape) and three band RMS (the colour) ----
    public static func waveform(_ x: [Float], _ fs: Double) -> Waveform {
        let n = x.count, WPS = 300.0, hop = fs / WPS, frames = Int(jsCeil(Double(n) / hop))
        var pk = [Float](repeating: 0, count: frames), rm = pk, lo = pk, mi = pk, hi = pk
        func coef(_ lp: Bool, _ f0: Double) -> [Double] {
            let w = 2 * Double.pi * f0 / fs, c = cos(w), al = sin(w) / (2 * 0.7071), a0 = 1 + al
            let b = lp ? [(1 - c) / 2, 1 - c, (1 - c) / 2] : [(1 + c) / 2, -(1 + c), (1 + c) / 2]
            return [b[0] / a0, b[1] / a0, b[2] / a0, -2 * c / a0, (1 - al) / a0]
        }
        let L = coef(true, 200), H = coef(false, 2500)
        var l1a = 0.0, l1b = 0.0, l2a = 0.0, l2b = 0.0, h1a = 0.0, h1b = 0.0, h2a = 0.0, h2b = 0.0
        var f = 0, next = hop, sP = 0.0, sR = 0.0, sL = 0.0, sM = 0.0, sH = 0.0, cnt = 0.0
        for i in 0..<n {
            let s = Double(x[i])
            var y = L[0] * s + l1a; l1a = L[1] * s - L[3] * y + l1b; l1b = L[2] * s - L[4] * y
            let low = L[0] * y + l2a; l2a = L[1] * y - L[3] * low + l2b; l2b = L[2] * y - L[4] * low
            y = H[0] * s + h1a; h1a = H[1] * s - H[3] * y + h1b; h1b = H[2] * s - H[4] * y
            let high = H[0] * y + h2a; h2a = H[1] * y - H[3] * high + h2b; h2b = H[2] * y - H[4] * high
            let mid = s - low - high, a = s < 0 ? -s : s
            if a > sP { sP = a }
            sR += s * s; sL += low * low; sM += mid * mid; sH += high * high; cnt += 1
            if Double(i + 1) >= next || i == n - 1 {
                if f < frames {
                    pk[f] = Float(sP); rm[f] = Float((sR / cnt).squareRoot()); lo[f] = Float((sL / cnt).squareRoot())
                    mi[f] = Float((sM / cnt).squareRoot()); hi[f] = Float((sH / cnt).squareRoot())
                }
                f += 1; next += hop; sP = 0; sR = 0; sL = 0; sM = 0; sH = 0; cnt = 0
            }
        }
        let fr = min(f, frames)
        func top(_ arr: [Float], _ q: Double) -> Double {
            let t = arr[0..<fr].sorted()
            if t.isEmpty { return 1e-9 }
            let v = Double(t[min(t.count - 1, Int(jsFloor(Double(t.count) * q)))])
            return v == 0 ? 1e-9 : v
        }
        func bytes(_ arr: [Float], _ ref: Double, _ gamma: Double) -> [UInt8] {
            (0..<fr).map { i in
                let v = min(255, jsRound(255 * pow(Double(arr[i]) / ref, gamma)))
                return v.isNaN || v < 0 ? 0 : UInt8(v)
            }
        }
        let pref = top(pk, 0.999)
        return Waveform(duration: Double(n) / fs, wps: Int(WPS), peak: bytes(pk, pref, 1), rms: bytes(rm, pref, 1),
                        low: bytes(lo, top(lo, 0.995), 0.9), mid: bytes(mi, top(mi, 0.995), 0.9), high: bytes(hi, top(hi, 0.995), 0.9))
    }

    // ---- phrases ----
    struct BarF { var e: Double, low: Double, high: Double, mid: Double, kick: Double }
    struct Seg { var a: Int, b: Int, level: Double, kick: Double, low: Double, rise: Double, label: String }

    public static func phraseAnalysis(_ x: [Float], _ fs: Double, _ bpm: Double, _ firstBeat: Double) -> [Phrase] {
        let n = x.count, spb = 60 / bpm, barLen = 4 * spb
        let nBarsD = jsFloor((Double(n) / fs - firstBeat) / barLen)
        if !(nBarsD >= 8) { return [] }
        let nBars = Int(nBarsD)
        let hop = Int(jsRound(fs / 200)), ER = fs / Double(hop), m = n / hop
        var eAll = [Float](repeating: 0, count: m), eLow = eAll, eHigh = eAll, eMid = eAll
        let aL = 1 - exp(-2 * Double.pi * 150 / fs), aH = 1 - exp(-2 * Double.pi * 2500 / fs)
        var l1 = 0.0, l2 = 0.0, h1 = 0.0
        for j in 0..<m {
            var sa = 0.0, sl = 0.0, sh = 0.0, sm = 0.0
            for i in (j * hop)..<(j * hop + hop) {
                let s = Double(x[i])
                l1 += aL * (s - l1); l2 += aL * (l1 - l2)
                h1 += aH * (s - h1)
                let hiV = s - h1, md = h1 - l2
                sa += s * s; sl += l2 * l2; sh += hiV * hiV; sm += md * md
            }
            let hd = Double(hop)
            eAll[j] = Float((sa / hd).squareRoot()); eLow[j] = Float((sl / hd).squareRoot())
            eHigh[j] = Float((sh / hd).squareRoot()); eMid[j] = Float((sm / hd).squareRoot())
        }
        let db = { (v: Double) in 20 * log10(v + 1e-6) }
        var F = [BarF]()
        for b in 0..<nBars {
            let t0 = firstBeat + Double(b) * barLen
            let j0 = Int(jsFloor(t0 * ER)), j1 = Int(jsFloor((t0 + barLen) * ER))
            var sa = 0.0, sl = 0.0, sh = 0.0, sm = 0.0, c = 0.0
            var j = j0
            while j < j1 && j < m {
                if j >= 0 {
                    sa += pow(Double(eAll[j]), 2); sl += pow(Double(eLow[j]), 2); sh += pow(Double(eHigh[j]), 2); sm += pow(Double(eMid[j]), 2)
                }
                c += 1; j += 1
            }
            var rises = [Double]()
            for k in 0..<16 {
                let jb = Int(jsFloor((t0 + Double(k) * spb / 4) * ER))
                var before = Double.infinity, after = 0.0
                for q in -6..<0 { let ix = jb + q; if ix >= 0 && ix < m { let v = Double(eLow[ix]); if v < before { before = v } } }
                for q in 0..<6 { let ix = jb + q; if ix >= 0 && ix < m { let v = Double(eLow[ix]); if v > after { after = v } } }
                rises.append(before != .infinity ? max(0, after - before) : 0)
            }
            rises = rises.stableSorted { $0 > $1 }
            let cc = c == 0 ? 1 : c
            F.append(BarF(e: db((sa / cc).squareRoot()), low: db((sl / cc).squareRoot()), high: db((sh / cc).squareRoot()), mid: db((sm / cc).squareRoot()), kick: (rises[0] + rises[1]) / 2))
        }
        func pct(_ arr: [Double], _ q: Double) -> Double { let t = arr.sorted(); return t[min(t.count - 1, Int(jsFloor(q * Double(t.count))))] }
        let eHi = pct(F.map { $0.e }, 0.85), eLo = pct(F.map { $0.e }, 0.15)
        let lowHi = pct(F.map { $0.low }, 0.85)
        var kRef = pct(F.map { $0.kick }, 0.9); if kRef == 0 { kRef = 1e-6 }
        for i in F.indices { F[i].kick /= kRef }
        func mean(_ a: Int, _ b: Int, _ key: KeyPath<BarF, Double>) -> Double {
            var s = 0.0, c = 0.0
            var i = max(0, a)
            while i < min(nBars, b) { s += F[i][keyPath: key]; c += 1; i += 1 }
            return c > 0 ? s / c : 0
        }
        let kickOn = { (v: Double) in min(1, max(0, (v - 0.2) / 0.3)) }
        var nov = [(b: Int, d: Double)]()
        var bb = 4
        while bb < nBars - 2 {
            let w = 4, b = bb
            let d = abs(mean(b, b + w, \.e) - mean(b - w, b, \.e)) / 4
                + abs(mean(b, b + w, \.low) - mean(b - w, b, \.low)) / 5
                + abs(mean(b, b + w, \.high) - mean(b - w, b, \.high)) / 6
                + abs(mean(b, b + w, \.mid) - mean(b - w, b, \.mid)) / 5
                + 1.5 * abs(kickOn(mean(b, b + w, \.kick)) - kickOn(mean(b - w, b, \.kick)))
            nov.append((b, d)); bb += 4
        }
        var cuts = [0]
        let dMed = nov.isEmpty ? 0 : pct(nov.map { $0.d }, 0.5)
        let thr = max(0.45, 3 * dMed)
        let cand = nov.enumerated().filter { (i, v) in v.d > thr && (i == 0 || v.d >= nov[i - 1].d) && (i == nov.count - 1 || v.d >= nov[i + 1].d) }
            .map { $0.element }.stableSorted { $0.d > $1.d }
        for c in cand where cuts.allSatisfy({ x in abs(x - c.b) >= 8 || (c.d > 4 * thr && abs(x - c.b) >= 4) }) { cuts.append(c.b) }
        cuts = cuts.stableSorted { $0 < $1 }; cuts.append(nBars)
        var segs = [Seg]()
        for i in 0..<(cuts.count - 1) {
            let a = cuts[i], b = cuts[i + 1]
            let e = mean(a, b, \.e), kick = kickOn(mean(a, b, \.kick)), low = mean(a, b, \.low)
            let level = (e - eLo) / max(3, eHi - eLo)
            let rise = b - a >= 4 ? (mean(b - 2, b, \.e) - mean(a, a + 2, \.e)) + (mean(b - 2, b, \.high) - mean(a, a + 2, \.high)) * 0.5 : 0
            segs.append(Seg(a: a, b: b, level: level, kick: kick, low: low, rise: rise, label: ""))
        }
        for i in segs.indices {
            let s = segs[i], full = s.kick > 0.5 && s.low > lowHi - 4
            segs[i].label = full && s.level > 0.78 ? "Drop" : s.kick > 0.5 ? "Groove" : "Breakdown"
        }
        var i = 0
        while i + 1 < segs.count {
            let s = segs[i]
            if segs[i + 1].label != "Drop" || s.label == "Drop" || s.b - s.a < 16 { i += 1; continue }
            let c = s.b - 8
            let ramp = (mean(c, s.b, \.e) - mean(s.a, c, \.e)) + 0.5 * (mean(c, s.b, \.high) - mean(s.a, c, \.high))
            if ramp > 3 {
                segs.insert(Seg(a: c, b: s.b, level: s.level, kick: s.kick, low: s.low, rise: ramp, label: "Build"), at: i + 1)
                segs[i].b = c; i += 1
            }
            i += 1
        }
        for i in segs.indices {
            let s = segs[i]
            if i + 1 < segs.count {
                let nx = segs[i + 1]
                if s.label != "Drop" && nx.label == "Drop" && (s.rise > 3 || (s.kick < 0.5 && s.b - s.a <= 8)) && s.b - s.a <= 16 { segs[i].label = "Build" }
            }
        }
        if segs.count > 1 && (segs[0].label != "Drop" || segs[0].level < 0.95) { segs[0].label = "Intro" }
        let li = segs.count - 1
        if segs.count > 2 && segs[li].label != "Drop" && segs[li].level < 0.8 && segs[li].b - segs[li].a <= 32 { segs[li].label = "Outro" }
        var merged = [(a: Int, b: Int, label: String)]()
        for s in segs { if let p = merged.last, p.label == s.label { merged[merged.count - 1].b = s.b } else { merged.append((s.a, s.b, s.label)) } }
        var out = [Phrase]()
        for s in merged {
            var a = s.a
            while s.b - a > 32 { out.append(Phrase(start: firstBeat + Double(a) * barLen, bars: 16, label: s.label)); a += 16 }
            out.append(Phrase(start: firstBeat + Double(a) * barLen, bars: s.b - a, label: s.label))
        }
        return out
    }

    // ---- FFT (radix 2, tables per size) ----
    final class FFTTables { let rev: [Int]; let cosT: [Double]; let sinT: [Double]
        init(_ n: Int) {
            var rev = [Int](repeating: 0, count: n)
            var j = 0
            for i in 0..<n { rev[i] = j; var bit = n >> 1; while j & bit != 0 { j ^= bit; bit >>= 1 }; j ^= bit }
            self.rev = rev
            cosT = (0..<(n / 2)).map { cos(-2 * Double.pi * Double($0) / Double(n)) }
            sinT = (0..<(n / 2)).map { sin(-2 * Double.pi * Double($0) / Double(n)) }
        }
    }
    static func fft(_ re: inout [Double], _ im: inout [Double], _ t: FFTTables) {
        let n = re.count
        re.withUnsafeMutableBufferPointer { re in im.withUnsafeMutableBufferPointer { im in
            for i in 0..<n { let j = t.rev[i]; if i < j { var x = re[i]; re[i] = re[j]; re[j] = x; x = im[i]; im[i] = im[j]; im[j] = x } }
            var len = 2
            while len <= n {
                let h = len >> 1, step = n / len
                var i = 0
                while i < n {
                    var w = 0
                    for k in 0..<h {
                        let a = i + k, b = a + h, cr = t.cosT[w], ci = t.sinT[w]
                        let tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr
                        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti
                        w += step
                    }
                    i += len
                }
                len <<= 1
            }
        } }
    }
    static func splitMags(_ re: [Double], _ im: [Double], _ k0: Int, _ k1: Int, _ ma: inout [Double], _ mb: inout [Double]) {
        let n = re.count
        if k1 < k0 { return }
        for k in k0...k1 {
            let zr = re[k], zi = im[k], cr = re[n - k], ci = -im[n - k]
            let ar = (zr + cr) / 2, ai = (zi + ci) / 2, br = (zi - ci) / 2, bi = (cr - zr) / 2
            ma[k] = (ar * ar + ai * ai).squareRoot(); mb[k] = (br * br + bi * bi).squareRoot()
        }
    }

    // ---- beat grid ----
    static let W_KS = 0.5, W_NOV = 20.0, W_START = 2.0, W_ENTRY = 0.0

    public static func beatGrid(_ x: [Float], _ fs: Double, _ range: (Double, Double)) -> (bpm: Double, firstBeat: Double, conf: Double) {
        let n = x.count, N = 512, hop = 64, FPS = fs / Double(hop)
        let frames = max(0, (n - N) / hop + 1)
        if Double(frames) < FPS * 4 { return (120, 0, 0) }
        let win = (0..<N).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N)) }
        let binHz = fs / Double(N)
        let bin = { (f: Double) in max(1, Int(jsRound(f / binHz))) }
        let b0 = bin(30), b1 = bin(150), b2 = bin(2000), b3 = min(N / 2 - 1, bin(5000))
        var fLow = [Float](repeating: 0, count: frames), fMid = fLow, fHigh = fLow, rms = fLow
        let NB = 16
        var bandOf = [Int](repeating: -1, count: N / 2)
        for k in b0..<b2 { bandOf[k] = min(NB - 1, Int(jsFloor(Double(NB) * log(Double(k) / Double(b0)) / log(Double(b2) / Double(b0))))) }
        var spec = [Float](repeating: 0, count: frames * NB)
        var re = [Double](repeating: 0, count: N), im = re, ma = [Double](repeating: 0, count: N / 2), mb = ma
        var prev = [Float](repeating: 0, count: N / 2), cur = prev
        let tables = FFTTables(N)
        func frameOut(_ t: Int, _ mag: [Double]) {
            var lo = 0.0, mi = 0.0, hi = 0.0
            for k in b0...b3 {
                let Lg = log(1 + 100 * mag[k])
                cur[k] = Float(Lg)
                // the flux and the spectrum use L as a double (cur[k] is a Float32Array slot in the JS)
                let dd = Lg - Double(prev[k])
                if dd > 0 { if k < b1 { lo += dd } else if k < b2 { mi += dd } else { hi += dd } }
                let bb = bandOf[k]
                if bb >= 0 { spec[t * NB + bb] = Float(Double(spec[t * NB + bb]) + Lg) }
            }
            fLow[t] = Float(lo / Double(b1 - b0)); fMid[t] = Float(mi / Double(b2 - b1)); fHigh[t] = Float(hi / Double(b3 - b2 + 1))
            swap(&prev, &cur)
        }
        var t = 0
        while t < frames {
            let sa = t * hop, sb = sa + hop, two = t + 1 < frames
            var ea = 0.0, eb = 0.0
            if two { for i in 0..<N { let v = Double(x[sa + i]), w = Double(x[sb + i]); re[i] = v * win[i]; im[i] = w * win[i]; ea += v * v; eb += w * w } }
            else { for i in 0..<N { let v = Double(x[sa + i]); re[i] = v * win[i]; im[i] = 0; ea += v * v } }
            rms[t] = Float((ea / Double(N)).squareRoot())
            if two { rms[t + 1] = Float((eb / Double(N)).squareRoot()) }
            fft(&re, &im, tables)
            splitMags(re, im, b0, b3, &ma, &mb)
            frameOut(t, ma)
            if two { frameOut(t + 1, mb) }
            t += 2
        }
        fLow[0] = 0; fMid[0] = 0; fHigh[0] = 0
        let W = Int(jsRound(0.15 * FPS))
        func clean(_ a: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: frames)
            var s = 0.0
            for t in 0..<min(frames, W) { s += Double(a[t]) }
            var tot = 0.0
            for t in 0..<frames {
                let hiI = t + W, loI = t - W - 1
                if hiI < frames { s += Double(a[hiI]) }
                if loI >= 0 { s -= Double(a[loI]) }
                let cnt = min(frames - 1, hiI) - max(0, loI + 1) + 1
                let v = Double(a[t]) - s / Double(cnt)
                out[t] = v > 0 ? Float(v) : 0; tot += Double(out[t])
            }
            var m = tot / Double(frames); if m == 0 || m.isNaN { m = 1 }
            for t in 0..<frames { out[t] = Float(Double(out[t]) / m) }
            return out
        }
        let oL = clean(fLow), oM = clean(fMid), oH = clean(fHigh)
        var odf = [Float](repeating: 0, count: frames), beatOdf = odf
        for t in 0..<frames {
            odf[t] = Float(Double(oL[t]) + Double(oM[t]) + 0.6 * Double(oH[t]))
            beatOdf[t] = Float(Double(oL[t]) + 0.8 * Double(oM[t]) + 0.15 * Double(oH[t]))
        }
        // ---- tempo candidates from the autocorrelation
        var mean = 0.0
        for t in 0..<frames { mean += Double(odf[t]) }
        mean /= Double(frames)
        var z = [Float](repeating: 0, count: frames)
        for t in 0..<frames { z[t] = Float(Double(odf[t]) - mean) }
        let maxLag = min(frames - 1, Int(jsCeil(FPS * 60 / 55 * 4)) + 2)
        var ac = [Float](repeating: 0, count: maxLag + 1)
        z.withUnsafeBufferPointer { zp in
            for lag in 1...maxLag {
                var s = 0.0
                for i in lag..<frames { s += Double(zp[i]) * Double(zp[i - lag]) }
                ac[lag] = Float(s / Double(frames - lag))
            }
        }
        func acAt(_ Lg: Double) -> Double {
            let i = Int(jsFloor(Lg)), f = Lg - Double(i)
            if i < 1 || i + 2 > maxLag { return 0 }
            let a = Double(ac[i]) + (Double(ac[i + 1]) - Double(ac[i])) * f
            return max(a, Double(ac[i - 1]) * 0.9, Double(ac[i + 2]) * 0.9)
        }
        func acScore(_ b: Double) -> Double { let P = FPS * 60 / b; return acAt(P) + acAt(2 * P) + acAt(4 * P) }
        var tempos = [(Double, Double)]()
        var bt = 60.0
        while bt <= 200 { tempos.append((bt, acScore(bt))); bt += 0.1 }
        var peaks = [(Double, Double)]()
        for i in 1..<(tempos.count - 1) where tempos[i].1 >= tempos[i - 1].1 && tempos[i].1 > tempos[i + 1].1 { peaks.append(tempos[i]) }
        peaks = peaks.stableSorted { $0.1 > $1.1 }
        func fold(_ b0: Double) -> Double { var b = b0; while b < range.0 { b *= 2 }; while b >= range.1 { b /= 2 }; return b }
        var cands = [Double]()
        func addCand(_ b0: Double) { let b = fold(b0); if !cands.contains(where: { abs($0 / b - 1) < 0.004 }) { cands.append(b) } }
        for p in peaks.prefix(5) { addCand(p.0) }
        for p in peaks.prefix(2) { for r in [2.0 / 3, 3.0 / 2, 3.0 / 4, 4.0 / 3] { addCand(p.0 * r) } }
        // ---- grid quality: fold onsets into a beat-phase histogram
        let HB = 64
        var hist = [Double](repeating: 0, count: HB)
        struct Fit { var b: Double; var score: Double; var phase: Double; var P: Double; var contrast = 0.0; var total = 0.0 }
        func fit(_ b: Double) -> Fit {
            let P = FPS * 60 / b
            for k in 0..<HB { hist[k] = 0 }
            for t in 0..<frames {
                let v = Double(beatOdf[t])
                if v <= 0 { continue }
                let ph = (Double(t) / P).truncatingRemainder(dividingBy: 1) * Double(HB), i0 = Int(jsFloor(ph)), f = ph - Double(i0)
                hist[i0 % HB] += v * (1 - f); hist[(i0 + 1) % HB] += v * f
            }
            var mx = -1.0, mi = 0, tot = 0.0
            for k in 0..<HB {
                let s = hist[k] + 0.5 * (hist[(k + 1) % HB] + hist[(k + HB - 1) % HB])
                tot += hist[k]
                if s > mx { mx = s; mi = k }
            }
            var den = 2 * tot / Double(HB); if den == 0 || den.isNaN { den = 1 }
            return Fit(b: b, score: mx / den, phase: (Double(mi) / Double(HB)) * P, P: P)
        }
        func bestNear(_ b: Double, _ span: Double, _ step: Double) -> Fit {
            var best = fit(b), bb = b
            var c = b - span
            while c <= b + span + 1e-9 { let f = fit(c); if f.score > best.score { best = f; bb = c }; c += step }
            best.b = bb
            return best
        }
        var odfMean = 0.0
        for t in 0..<frames { odfMean += Double(beatOdf[t]) }
        odfMean = odfMean / Double(frames); if odfMean == 0 || odfMean.isNaN { odfMean = 1 }
        func at(_ arr: [Float], _ i: Int) -> Double? { i >= 0 && i < arr.count ? Double(arr[i]) : nil }
        func contrast(_ P: Double, _ ph: Double) -> Double {
            var s = 0.0, c = 0.0
            var f = ph
            while f < Double(frames - 3) {
                let i = Int(jsRound(f))
                s += max(at(beatOdf, i - 2) ?? 0, at(beatOdf, i - 1) ?? 0, at(beatOdf, i) ?? .nan, at(beatOdf, i + 1) ?? .nan, at(beatOdf, i + 2) ?? .nan)
                c += 1; f += P
            }
            return c > 0 ? s / c / odfMean : 0
        }
        let acMax = max(1e-9, peaks.isEmpty ? 1 : peaks[0].1)
        func peakNear(_ arr: [Float], _ f: Double, _ w: Double) -> (f: Double, v: Double)? {
            let lo = max(1, Int(jsFloor(f - w))), hi = min(frames - 2, Int(jsCeil(f + w)))
            var bi = -1, bv = 0.0
            if lo <= hi { for i in lo...hi where Double(arr[i]) > bv { bv = Double(arr[i]); bi = i } }
            if bi < 0 { return nil }
            let a = Double(arr[bi - 1]), c = Double(arr[bi + 1]), d = a - 2 * bv + c
            return (Double(bi) + (d < 0 ? 0.5 * (a - c) / d : 0), bv)
        }
        var P = 0.0, a0 = 0.0
        let sortedOdf = beatOdf.filter { $0 > 0 }.sorted()
        let thr = sortedOdf.isEmpty ? 0 : Double(sortedOdf[Int(jsFloor(Double(sortedOdf.count) * 0.6))])
        @discardableResult func regress(_ winFrac: Double) -> Bool {
            let k0 = Int(jsCeil(-a0 / P)), k1 = Int(jsFloor((Double(frames - 1) - a0) / P))
            var ks = [Double](), fs_ = [Double](), ws = [Double]()
            if k0 <= k1 {
                for k in k0...k1 {
                    guard let p = peakNear(beatOdf, a0 + Double(k) * P, P * winFrac), p.v >= thr else { continue }
                    ks.append(Double(k)); fs_.append(p.f); ws.append(min(p.v, 4 * thr + 1e-9))
                }
            }
            if ks.count < 16 { return false }
            var keep = ks.map { _ in true }
            for _ in 0..<3 {
                var sw = 0.0, sk = 0.0, sf = 0.0, skk = 0.0, skf = 0.0
                for i in 0..<ks.count where keep[i] { let w = ws[i]; sw += w; sk += w * ks[i]; sf += w * fs_[i]; skk += w * ks[i] * ks[i]; skf += w * ks[i] * fs_[i] }
                let den = sw * skk - sk * sk
                if den <= 0 { return false }
                let slope = (sw * skf - sk * sf) / den, icpt = (sf - slope * sk) / sw
                let res = ks.indices.map { abs(fs_[$0] - (icpt + slope * ks[$0])) }
                let sr = res.indices.filter { keep[$0] }.map { res[$0] }.sorted()
                // (JS: an empty list gives NaN, which keeps nothing)
                if sr.isEmpty { keep = res.map { _ in false } }
                else { let cut = max(1.5, 3 * sr[sr.count / 2]); keep = res.map { $0 <= cut } }
                P = slope; a0 = icpt
            }
            return true
        }
        var pick: Fit? = nil
        for c in cands {
            var r = bestNear(c, c * 0.004, c * 0.0005)
            let prior = max(0, acScore(r.b)) / acMax
            P = r.P; a0 = r.phase
            if regress(0.12) { regress(0.06) }
            if abs(P / r.P - 1) > 0.01 { P = r.P; a0 = r.phase }
            r.P = P; r.phase = a0; r.b = 60 * FPS / P
            r.contrast = contrast(r.P, (r.phase.truncatingRemainder(dividingBy: P) + P).truncatingRemainder(dividingBy: P))
            r.total = r.contrast * (0.6 + 0.4 * prior)
            if pick == nil || r.total > pick!.total { pick = r }
        }
        guard let pk = pick else { return (120, 0, 0) }
        P = pk.P; a0 = pk.phase
        // ---- on the beat, or between the beats?
        func sumAt(_ arr: [Float], _ off: Double) -> Double {
            var s = 0.0
            var k = Int(jsCeil(-(a0 + off) / P))
            while a0 + off + Double(k) * P < Double(frames - 2) { if let p = peakNear(arr, a0 + off + Double(k) * P, 2) { s += p.v }; k += 1 }
            return s
        }
        var lm = [Float](repeating: 0, count: frames)
        for t in 0..<frames { lm[t] = Float(max(0, Double(oL[t]) + Double(oM[t]) - 0.5 * Double(oH[t]))) }
        if sumAt(lm, P / 2) > 1.1 * sumAt(lm, 0) { a0 += P / 2; regress(0.06) }
        // ---- round to a whole (or half) BPM only when it can't cause audible drift
        let nBeats = Double(frames) / P
        var bpm = 60 * FPS / P
        for q in [1.0, 2, 100] {
            let r = jsRound(bpm * q) / q, Pr = 60 * FPS / r
            let driftMs = abs(Pr - P) * nBeats / FPS * 1000
            if driftMs < (q == 100 ? 2 : 5) { bpm = r; break }
        }
        P = 60 * FPS / bpm
        do {
            var s = 0.0, w = 0.0
            var k = Int(jsCeil(-a0 / P))
            while a0 + Double(k) * P < Double(frames - 2) {
                if let p = peakNear(beatOdf, a0 + Double(k) * P, P * 0.05), p.v >= thr { s += (p.f - (a0 + Double(k) * P)) * p.v; w += p.v }
                k += 1
            }
            if w != 0 { a0 += s / w }
        }
        let beatTime = { (k: Int) -> Double in (a0 + Double(k) * P) / FPS + 0.75 * Double(N) / fs }
        // ---- downbeat vote
        let kFirst = Int(jsCeil(-a0 / P)), kLast = Int(jsFloor((Double(frames - 1) - a0) / P)) - 1
        let nb = kLast - kFirst + 1
        var vote = [0.0, 0.0, 0.0, 0.0]
        let mod4 = { (v: Int) in ((v % 4) + 4) % 4 }
        if nb >= 16 {
            var fKick = [Float](repeating: 0, count: nb), fSnare = fKick, fChange = fKick, fEntry = fKick, loud = fKick
            var avgSpec = [Float](repeating: 0, count: nb * NB)
            for j in 0..<nb {
                let k = kFirst + j, f0 = a0 + Double(k) * P
                let pkk = peakNear(oL, f0, 3), ps = peakNear(oM, f0, 3)
                fKick[j] = Float(pkk?.v ?? 0); fSnare[j] = Float(ps?.v ?? 0)
                let s = max(0, Int(jsRound(f0))), e = min(frames, Int(jsRound(f0 + P)))
                var r = 0.0
                if s < e {
                    for t in s..<e {
                        r += Double(rms[t])
                        for q in 0..<NB { avgSpec[j * NB + q] = Float(Double(avgSpec[j * NB + q]) + Double(spec[t * NB + q])) }
                    }
                }
                let c = Double(max(1, e - s))
                loud[j] = Float(r / c)
                for q in 0..<NB { avgSpec[j * NB + q] = Float(Double(avgSpec[j * NB + q]) / c) }
            }
            if nb > 1 {
                for j in 1..<nb {
                    var d = 0.0
                    for q in 0..<NB { d += abs(Double(avgSpec[j * NB + q]) - Double(avgSpec[(j - 1) * NB + q])) }
                    fChange[j] = Float(d)
                }
            }
            if nb > 8 {
                for j in 4..<(nb - 4) {
                    var a = 0.0, b = 0.0
                    for q in 0..<4 { a += Double(loud[j + q]); b += Double(loud[j - 4 + q]) }
                    let r = log((a + 1e-6) / (b + 1e-6))
                    fEntry[j] = Float(r > 0.4 ? r : 0)
                }
            }
            func zs(_ v: [Float]) -> [Float] {
                var m = 0.0, s = 0.0
                for a in v { m += Double(a) }
                m /= Double(v.count)
                for a in v { s += pow(Double(a) - m, 2) }
                s = (s / Double(v.count)).squareRoot(); if s == 0 || s.isNaN { s = 1 }
                return v.map { Float((Double($0) - m) / s) }
            }
            let zK = zs(fKick), zS = zs(fSnare)
            _ = zs(fChange)
            var nov = [0.0, 0.0, 0.0, 0.0]
            for r in 0..<4 {
                let j0 = mod4(r - kFirst)
                var prevBar: [Float]? = nil, cnt = 0.0
                var j = j0
                while j + 4 <= nb {
                    var bar = [Float](repeating: 0, count: NB)
                    for q in 0..<4 { for u in 0..<NB { bar[u] = Float(Double(bar[u]) + Double(avgSpec[(j + q) * NB + u]) / 4) } }
                    if let pb = prevBar { var d = 0.0; for u in 0..<NB { d += abs(Double(bar[u]) - Double(pb[u])) }; nov[r] += d; cnt += 1 }
                    prevBar = bar; j += 4
                }
                nov[r] /= cnt == 0 ? 1 : cnt
            }
            var ks = [0.0, 0.0, 0.0, 0.0], ksn = [0.0, 0.0, 0.0, 0.0]
            for j in 0..<nb { let r = mod4(kFirst + j); ks[r] += Double(zK[j]) - Double(zS[j]); ksn[r] += 1 }
            for r in 0..<4 { ks[r] /= ksn[r] == 0 ? 1 : ksn[r] }
            let lsorted = loud.sorted(), lmed = Double(lsorted[nb / 2])
            var jStart = 0
            while jStart < nb - 1 && Double(loud[jStart]) < 0.25 * lmed { jStart += 1 }
            var novMean = (nov[0] + nov[1] + nov[2] + nov[3]) / 4; if novMean == 0 || novMean.isNaN { novMean = 1 }
            for r in 0..<4 { vote[r] = W_KS * ks[r] + W_NOV * (nov[r] / novMean - 1) }
            vote[mod4(kFirst + jStart)] += W_START
            for j in 0..<nb { vote[mod4(kFirst + j)] += W_ENTRY * Double(fEntry[j]) }
        }
        var best = 0
        for r in 1..<4 where vote[r] > vote[best] { best = r }
        var k = best
        while beatTime(k - 4) >= 0 { k -= 4 }
        while beatTime(k) < 0 { k += 4 }
        return (bpm, beatTime(k), pk.contrast)
    }

    // ---- musical key ----
    static let tpn: [[Double]] = [[5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0],
                                  [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 4.0, 1.5]]

    public static func detectKey(_ x: [Float], _ fs: Double) -> (key: Int, keyConf: Double) {
        let prom = 3.0, powE = 2.0, harm = 5, hdecay = 0.8, thrF = 0.02, fmax = 2100.0, split = 52.0, bw = 0.5
        let N = 8192, n = x.count
        let hop = max(N / 2, (n - N) / 360)
        let win = (0..<N).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N)) }
        var re = [Double](repeating: 0, count: N), im = re, magA = [Double](repeating: 0, count: N / 2), magB = magA
        let kLo = Int(jsCeil(50 * Double(N) / fs)), kHi = min(N / 2 - 2, Int(jsFloor(fmax * Double(N) / fs)))
        var pm = [Double](), pw = [Double]()
        let R = 24, kM0 = max(1, kLo - R - 1), kM1 = min(N / 2 - 1, kHi + R + 1)
        var starts = [Int]()
        var s0 = 0
        while s0 + N <= n { starts.append(s0); s0 += hop }
        let tables = FFTTables(N)
        func frameOut(_ mag: [Double]) {
            var mx = 0.0
            for k in (kLo - 1)...(kHi + 1) where mag[k] > mx { mx = mag[k] }
            if mx < 1e-4 { return }
            let thr = mx * thrF
            var run = 0.0
            for k in (kLo - R)...(kLo + R) { run += k >= kM0 ? mag[k] : 0 }
            for k in kLo...kHi {
                if k > kLo { let a = k + R, b0 = k - R - 1; run += (a <= kM1 ? mag[a] : 0) - (b0 >= kM0 ? mag[b0] : 0) }
                let b = mag[k]
                if b < thr || b <= mag[k - 1] || b < mag[k + 1] { continue }
                if b < prom * run / Double(2 * R + 1) { continue }
                let la = log(mag[k - 1] + 1e-12), lb = log(b), lc = log(mag[k + 1] + 1e-12)
                let den = la - 2 * lb + lc
                let p = Double(k) + (den < 0 ? 0.5 * (la - lc) / den : 0)
                let f = p * fs / Double(N)
                pm.append(69 + 12 * log2(f / 440)); pw.append(pow(b / mx, powE))
            }
        }
        var q = 0
        while q < starts.count {
            let sa = starts[q], two = q + 1 < starts.count, sb = two ? starts[q + 1] : 0
            if two { for i in 0..<N { re[i] = Double(x[sa + i]) * win[i]; im[i] = Double(x[sb + i]) * win[i] } }
            else { for i in 0..<N { re[i] = Double(x[sa + i]) * win[i]; im[i] = 0 } }
            fft(&re, &im, tables)
            splitMags(re, im, kM0, kM1, &magA, &magB)
            frameOut(magA)
            if two { frameOut(magB) }
            q += 2
        }
        var cs = 0.0, sn = 0.0
        for i in 0..<pm.count { let a = 2 * Double.pi * pm[i]; cs += pw[i] * cos(a); sn += pw[i] * sin(a) }
        let tune = atan2(sn, cs) / (2 * Double.pi)
        var bass = [Double](repeating: 0, count: 12), high = bass
        for i in 0..<pm.count {
            let m = pm[i] - tune, r = jsRound(m), dev = abs(m - r)
            if dev > 0.4 { continue }
            let w = pw[i] * (1 - dev / 0.4 * 0.5)
            for hh in 1...harm {
                let mf = m - 12 * log2(Double(hh)), rr = jsRound(mf)
                if abs(mf - rr) > 0.4 { continue }
                let ri = Int(rr), pc = ((ri % 12) + 12) % 12, ww = w * pow(hdecay, Double(hh - 1))
                if rr < split { bass[pc] += ww } else { high[pc] += ww }
            }
        }
        func norm(_ v: [Double]) -> [Double] { var s = 0.0; for a in v { s += a }; let d = s == 0 ? 1 : s; return v.map { $0 / d } }
        let nb = norm(bass), nh = norm(high)
        let chroma = nh.indices.map { nh[$0] + bw * nb[$0] }
        func corr(_ c: [Double], _ p: [Double], _ rot: Int) -> Double {
            var mc = 0.0, mp = 0.0
            for i in 0..<12 { mc += c[i]; mp += p[i] }
            mc /= 12; mp /= 12
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in 0..<12 { let a = c[(i + rot) % 12] - mc, b = p[i] - mp; sxy += a * b; sxx += a * a; syy += b * b }
            let d = sxx * syy
            return sxy / (d == 0 || d.isNaN ? 1 : d).squareRoot()
        }
        var scores = [Double]()
        for m in 0..<2 { for t in 0..<12 { scores.append(corr(chroma, tpn[m], t)) } }
        var best = 0
        for k in 1..<24 where scores[k] > scores[best] { best = k }
        let sorted = scores.sorted(by: >)
        return (best, sorted[0] - sorted[1])
    }
}
