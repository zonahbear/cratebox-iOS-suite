// Beat FX / Pad FX: a line-by-line port of the web app's FxUnit (the WORKLET in cratebox.html). One unit
// per insert point (every deck channel, and the master), two slots: "beat" (the BEAT FX unit, when it's
// routed here) and "pad" (PAD FX, decks only). Timed by a beat clock (where the beat is now and how fast
// it's moving), so echoes, rolls and gates land on the grid. With nothing on and no tails left it's a
// straight copy. Tested sample for sample against the JS (Fixtures/dsp).
import Foundation

public enum FxKind: String, CaseIterable {
    case none = "", echo = "ECHO", delay = "DELAY", pingPong = "PING PONG", reverb = "REVERB", flanger = "FLANGER"
    case filter = "FILTER", trans = "TRANS", roll = "ROLL", hpf = "HPF", lpf = "LPF"
    /// Cratebox HEAT only: tape warble played by a Puffco (HeatController's HOLD sets `mod` from the temperature drop)
    case puff = "PUFF"
}

public struct FxClock { public var t0 = 0.0, beat0 = 0.0, bps = 0.0, spb = 0.5
    public init(t0: Double = 0, beat0: Double = 0, bps: Double = 0, spb: Double = 0.5) { self.t0 = t0; self.beat0 = beat0; self.bps = bps; self.spb = spb } }

let FX_HIST = 5.0                     // seconds of input history (roll) and of each delay line

final class FloatRing {
    let p: UnsafeMutablePointer<Float>, n: Int
    init(_ n: Int) { self.n = n; p = .allocate(capacity: n); p.initialize(repeating: 0, count: n) }
    deinit { p.deallocate() }
}

final class Reverb {
    var cL: [FloatRing], cR: [FloatRing], ci: [Int], fsL: [Double], fsR: [Double]
    var aL: [FloatRing], aR: [FloatRing], ai: [Int]
    init(sr: Double) {
        let k = sr / 44100
        let mk = { (n: Int) in FloatRing(max(8, Int(jsRound(Double(n) * k)))) }
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], aps = [556, 441, 341, 225]
        cL = combs.map(mk); cR = combs.map { mk($0 + 23) }; ci = combs.map { _ in 0 }
        fsL = combs.map { _ in 0 }; fsR = combs.map { _ in 0 }
        aL = aps.map(mk); aR = aps.map { mk($0 + 23) }; ai = aps.map { _ in 0 }
    }
}

public final class FxSlot {
    let sr: Double
    public internal(set) var fx: FxKind = .none
    public internal(set) var on = false
    public internal(set) var beats = 0.5
    public internal(set) var depth = 0.6
    /// PUFF: how hard the Puffco is being hit right now, 0...1 (set from outside, smoothed here)
    public internal(set) var mod = 0.0
    var modS = 0.0, lfo = 0.0
    var g = 0.0, inG = 0.0                // smoothed: effect amount / feed into delays and reverb
    public internal(set) var active = false   // on, or still ringing out
    var dL: FloatRing?, dR: FloatRing?, w = 0
    var fl = [0.0, 0.0, 0.0, 0.0], fr = [0.0, 0.0, 0.0, 0.0]
    var cf: [Double]? = nil
    var rev: Reverb?
    var roll: (start: Int, len: Int, pos: Int)?
    var quiet = 0
    var tg: Double? = nil
    init(sr: Double) {
        self.sr = sr
        // allocated up front, never on the audio thread
        let n = Int((FX_HIST * sr).rounded(.up))
        dL = FloatRing(n); dR = FloatRing(n); rev = Reverb(sr: sr)
        cf = [0, 0, 0, 0, 0]
    }
    /// The JS slot "set" message: nil leaves a setting as it is.
    public func set(fx newFx: FxKind? = nil, beats b: Double? = nil, depth d: Double? = nil, on o: Bool? = nil, mod m: Double? = nil) {
        if let m { mod = min(1, max(0, m)) }
        if let newFx, newFx != fx { fx = newFx; roll = nil; cfReady = false }
        if let b { beats = b }
        if let d { depth = d }
        if let o { if o && !on { roll = nil }; on = o }
        if on { active = true; quiet = 0 }
    }
    var cfReady = false
}

// RBJ biquad coefficients
func biq(_ hp: Bool, _ f: Double, _ q: Double, _ sr: Double) -> (Double, Double, Double, Double, Double) {
    let w = 2 * Double.pi * min(f, sr * 0.45) / sr, cs = cos(w), al = sin(w) / (2 * q)
    let b0, b1, b2: Double
    if hp { b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2 } else { b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2 }
    let a0 = 1 + al
    return (b0 / a0, b1 / a0, b2 / a0, (-2 * cs) / a0, (1 - al) / a0)
}

public final class FxUnit {
    public let sampleRate: Double
    let hL: FloatRing, hR: FloatRing
    var hw = 0
    let hn: Int
    public let beat: FxSlot, pad: FxSlot
    public var clock = FxClock()

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hn = Int((FX_HIST * sampleRate).rounded(.up))
        hL = FloatRing(hn); hR = FloatRing(hn)
        beat = FxSlot(sr: sampleRate); pad = FxSlot(sr: sampleRate)
    }

    /// In place: io holds the input and gets the output. `time` is the audio clock at the block's start.
    public func process(_ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>, _ n: Int, time: Double) {
        var hw = self.hw
        for i in 0..<n {
            hL.p[hw] = oL[i]; hR.p[hw] = oR[i]
            hw += 1; if hw == hn { hw = 0 }
        }
        if !beat.active && !pad.active { self.hw = hw; return }
        let c = clock, sr = sampleRate
        let beatAt0 = c.beat0 + (time - c.t0) * c.bps, dBeat = c.bps / sr
        let histEnd = hw
        if beat.active { run(beat, oL, oR, n, beatAt0, dBeat, c.spb, histEnd) }
        if pad.active { run(pad, oL, oR, n, beatAt0, dBeat, c.spb, histEnd) }
        self.hw = hw
    }

    func run(_ s: FxSlot, _ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>, _ N: Int,
             _ beat0: Double, _ dBeat: Double, _ spb: Double, _ histEnd: Int) {
        let sr = sampleRate, fx = s.fx, on = s.on, depth = s.depth
        let gStep = 1 / (0.004 * sr)        // 4 ms fades in and out: no clicks
        var g = s.g, inG = s.inG, peak = 0.0
        let delayFamily = fx == .echo || fx == .delay || fx == .pingPong
        let dl0 = s.dL!.p, dr0 = s.dR!.p
        let dn = s.dL!.n
        let fb = fx == .echo ? 0.6 : fx == .pingPong ? 0.55 : 0.32
        let dSamp = delayFamily ? max(1, min(dn - 2, Int(jsRound(s.beats * spb * sr)))) : 0
        var w = s.w
        let rv = s.rev!
        for i in 0..<N {
            let xl = Double(oL[i]), xr = Double(oR[i])
            let want = on ? 1.0 : 0.0
            g += g < want ? min(gStep, want - g) : -min(gStep, g - want)
            inG += inG < want ? min(gStep, want - inG) : -min(gStep, inG - want)
            var yl = xl, yr = xr
            if delayFamily {
                // echoes: the dry signal always passes; switching off stops feeding the delay, so they ring out
                var r = w - dSamp; if r < 0 { r += dn }
                let dl = Double(dl0[r]), dr = Double(dr0[r])
                if fx == .pingPong { dl0[w] = Float((xl + xr) * 0.5 * inG + dr * fb); dr0[w] = Float(dl * fb) }
                else { dl0[w] = Float(xl * inG + dl * fb); dr0[w] = Float(xr * inG + dr * fb) }
                yl = xl + dl * depth; yr = xr + dr * depth
                let a = abs(dl) + abs(dr); if a > peak { peak = a }
                w += 1; if w == dn { w = 0 }
            } else if fx == .reverb {
                // Freeverb: 8 damped combs into 4 allpasses per side; switching off lets the room ring out
                let inS = (xl + xr) * 0.015 * inG
                var sl = 0.0, sr2 = 0.0
                for k in 0..<8 {
                    let bl = rv.cL[k], br = rv.cR[k]
                    let j = rv.ci[k]
                    let ol = Double(bl.p[j % bl.n]), or = Double(br.p[j % br.n])
                    rv.fsL[k] = ol * 0.8 + rv.fsL[k] * 0.2; rv.fsR[k] = or * 0.8 + rv.fsR[k] * 0.2
                    bl.p[j % bl.n] = Float(inS + rv.fsL[k] * 0.86); br.p[j % br.n] = Float(inS + rv.fsR[k] * 0.86)
                    sl += ol; sr2 += or
                    rv.ci[k] = j + 1 >= 1_000_000_000 ? 0 : j + 1
                }
                for k in 0..<4 {
                    let al = rv.aL[k], ar = rv.aR[k], j = rv.ai[k]
                    let bo = Double(al.p[j % al.n]), bo2 = Double(ar.p[j % ar.n])
                    al.p[j % al.n] = Float(sl + bo * 0.5); ar.p[j % ar.n] = Float(sr2 + bo2 * 0.5)
                    sl = bo - sl; sr2 = bo2 - sr2
                    rv.ai[k] = j + 1 >= 1_000_000_000 ? 0 : j + 1
                }
                yl = xl + sl * depth * 1.2; yr = xr + sr2 * depth * 1.2
                let a = abs(sl) + abs(sr2); if a > peak { peak = a }
            } else {
                let beat = beat0 + Double(i) * dBeat
                var el = xl, er = xr              // the fully-wet signal
                if fx == .flanger {
                    // a 1-5 ms delay swept once per cycle (BEAT sets the cycle length), with feedback
                    let cyc = max(0.25, s.beats), ph = beat / cyc
                    let dd = (0.001 + 0.004 * (0.5 - 0.5 * cos(2 * Double.pi * ph))) * sr
                    var rp = Double(w) - dd; if rp < 0 { rp += Double(dn) }
                    let i0 = Int(rp), f = rp - Double(i0), i1 = i0 + 1 == dn ? 0 : i0 + 1
                    let dl = Double(dl0[i0]) + (Double(dl0[i1]) - Double(dl0[i0])) * f
                    let dr = Double(dr0[i0]) + (Double(dr0[i1]) - Double(dr0[i0])) * f
                    dl0[w] = Float(xl + dl * 0.6); dr0[w] = Float(xr + dr * 0.6)
                    w += 1; if w == dn { w = 0 }
                    el = (xl + dl * depth) / (1 + 0.6 * depth); er = (xr + dr * depth) / (1 + 0.6 * depth)
                } else if fx == .puff {
                    // tape warble: a sine-swept 1-8 ms delay (pitch wobble, no dry mix); the hit sets both how far
                    // and how fast it sweeps (2 Hz light pull ... 7 Hz hard rip), LEVEL/DEPTH caps it
                    s.modS += (s.mod - s.modS) * (1 / (0.05 * sr))       // ~50 ms: BLE readings arrive in steps
                    let a = s.modS * depth
                    s.lfo += (2 + 5 * a) / sr; if s.lfo >= 1 { s.lfo -= 1 }
                    let dd = (0.0045 + 0.0035 * a * sin(2 * Double.pi * s.lfo)) * sr
                    var rp = Double(w) - dd; if rp < 0 { rp += Double(dn) }
                    let i0 = Int(rp), f = rp - Double(i0), i1 = i0 + 1 == dn ? 0 : i0 + 1
                    dl0[w] = Float(xl); dr0[w] = Float(xr)
                    el = Double(dl0[i0]) + (Double(dl0[i1]) - Double(dl0[i0])) * f
                    er = Double(dr0[i0]) + (Double(dr0[i1]) - Double(dr0[i0])) * f
                    w += 1; if w == dn { w = 0 }
                } else if fx == .filter || fx == .hpf || fx == .lpf {
                    if (i & 31) == 0 || !s.cfReady {
                        let c: (Double, Double, Double, Double, Double)
                        if fx == .filter {
                            // LFO low-pass sweep, one cycle per BEAT setting; LEVEL/DEPTH sets how low it dips
                            let ph = beat / max(0.25, s.beats)
                            let f = 20000 * pow(2, -9 * depth * (0.5 - 0.5 * cos(2 * Double.pi * ph)))
                            c = biq(false, f, 2.2, sr)
                        } else if fx == .hpf { c = biq(true, 20 * pow(2, 9.5 * depth), 1.1, sr) }
                        else { c = biq(false, 20000 * pow(2, -9.5 * depth), 1.1, sr) }
                        s.cf![0] = c.0; s.cf![1] = c.1; s.cf![2] = c.2; s.cf![3] = c.3; s.cf![4] = c.4
                        s.cfReady = true
                    }
                    let c0 = s.cf![0], c1 = s.cf![1], c2 = s.cf![2], c3 = s.cf![3], c4 = s.cf![4]
                    el = c0 * xl + c1 * s.fl[0] + c2 * s.fl[1] - c3 * s.fl[2] - c4 * s.fl[3]
                    s.fl[1] = s.fl[0]; s.fl[0] = xl; s.fl[3] = s.fl[2]; s.fl[2] = el
                    er = c0 * xr + c1 * s.fr[0] + c2 * s.fr[1] - c3 * s.fr[2] - c4 * s.fr[3]
                    s.fr[1] = s.fr[0]; s.fr[0] = xr; s.fr[3] = s.fr[2]; s.fr[2] = er
                } else if fx == .trans {
                    // gate: on for the first half of each BEAT-long step, cut (by LEVEL/DEPTH) for the second half
                    let st = max(1.0 / 32, s.beats), ph = beat / st, frc = ph - ph.rounded(.down)
                    let want2 = frc < 0.5 ? 1 : 1 - depth
                    s.tg = s.tg == nil ? want2 : s.tg! + (want2 - s.tg!) * 0.02     // ~1 ms smoothing
                    el = xl * s.tg!; er = xr * s.tg!
                } else if fx == .roll {
                    // repeat the last BEAT-long slice, lined up with the grid (it starts on the slice the playhead is in)
                    if s.roll == nil && on {
                        let len = max(64, min(hn - 256, Int(jsRound(s.beats * spb * sr))))
                        let st = max(1.0 / 32, s.beats), frc = beat / st - (beat / st).rounded(.down)
                        let into = Int(jsRound(frc * Double(len)))      // samples since the slice began
                        let nowIdx = histEnd - N + i
                        var start = nowIdx - into; while start < 0 { start += hn }
                        s.roll = (start, len, into)
                    }
                    if let r = s.roll {
                        var j = r.start + (r.pos % r.len); if j >= hn { j -= hn }
                        el = Double(hL.p[j]); er = Double(hR.p[j]); s.roll!.pos += 1
                    }
                    if !on && g < 0.001 { s.roll = nil }
                }
                let mix = fx == .roll ? max(depth, 0.001) : 1
                yl = xl + (el - xl) * g * mix; yr = xr + (er - xr) * g * mix
            }
            oL[i] = Float(yl); oR[i] = Float(yr)
        }
        s.g = g; s.inG = inG; s.w = w
        // done ringing out? (off, faded, and the delay lines / reverb have gone quiet for half a second)
        if !on && g < 0.0005 && inG < 0.0005 {
            if delayFamily || fx == .reverb { if peak < 1e-4 { s.quiet += N } else { s.quiet = 0 }; if Double(s.quiet) > 0.5 * sr { s.active = false } }
            else { s.active = false }
        }
    }
}
