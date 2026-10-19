// The mixer: per channel trim, 3-band isolator EQ, CFX filter, FX insert, CUE, fader and crossfader; the
// master (BEAT FX on MASTER, level, limiter) and the headphone mix. The web app builds this from Web
// Audio nodes (buildDeckChain / applyMixer / applyMaster in cratebox.html); this does the same sums: the
// filters use the Web Audio BiquadFilter formulas (Q in dB for low/high-pass), parameter changes glide like
// setTargetAtTime(v, t, 0.008), and the curves (EQ, trim, fader, crossfader, CUE/MASTER) are the app's.
import Foundation

@inline(__always) func dbToGain(_ db: Double) -> Double { pow(10, db / 20) }

/// Mixer controls, all 0...1 like the hardware (the web app's `M`).
public struct MixerState {
    public var trim = [Double](repeating: 0.5, count: 4), hi = [Double](repeating: 0.5, count: 4)
    public var mid = [Double](repeating: 0.5, count: 4), low = [Double](repeating: 0.5, count: 4)
    public var cfx = [Double](repeating: 0.5, count: 4), fader = [Double](repeating: 1, count: 4)
    public var pfl = [Bool](repeating: false, count: 4)
    public var xfader = 0.5, headMix = 0.0, masterCue = false, master = 0.8
    /// decks shown (3 and 4 only in 4-deck mode); hidden ones are muted
    public var active = [true, true, false, false]
    public init() {}
}

public enum MixerCurves {
    public static func eqGain(_ v: Double) -> Double {
        if v < 0.5 { return v < 0.02 ? 0 : pow(v / 0.5, 2.2) }          // left = kill
        return 1 + (v - 0.5) * 2 * (dbToGain(6) - 1)                    // right = +6 dB
    }
    public static func trimGain(_ v: Double) -> Double { v < 0.5 ? (v < 0.01 ? 0 : dbToGain(-24 + 48 * v)) : dbToGain((v - 0.5) * 18) }
    public static func faderGain(_ v: Double) -> Double { v < 0.005 ? 0 : pow(v, 1.8) }
    /// crossfader: both full at the centre; decks 1 and 3 on the left, 2 and 4 on the right
    public static func xfGain(deck i: Int, _ x: Double) -> Double {
        let g = i % 2 == 0 ? (x <= 0.5 ? 1 : cos((x - 0.5) * Double.pi)) : (x >= 0.5 ? 1 : cos((0.5 - x) * Double.pi))
        return g < 0.002 ? 0 : g
    }
    /// CFX knob -> (low-pass Hz, Q dB, high-pass Hz, Q dB): left = low-pass, right = high-pass, centre = off
    public static func cfx(_ v: Double) -> (lp: Double, lpQ: Double, hp: Double, hpQ: Double) {
        if v < 0.47 { return (60 * pow(20000 / 60, v / 0.47), 1.4, 10, 0.707) }
        if v > 0.53 { return (22000, 0.707, 20 * pow(9000 / 20, (v - 0.53) / 0.47), 1.4) }
        return (22000, 0.707, 10, 0.707)
    }
    /// CUE/MASTER knob -> (cue gain, master gain), equal power past 12 o'clock
    public static func headMix(_ v: Double) -> (cue: Double, master: Double) {
        let hm = min(1, max(0, (v - 0.53) / 0.47))
        return (cos(hm * Double.pi / 2), sin(hm * Double.pi / 2))
    }
    public static func masterGain(_ v: Double) -> Double { pow(v, 1.6) * 1.2 }
}

/// A Web Audio BiquadFilter (lowpass / highpass), stereo, transposed direct form II.
struct Biquad {
    var hp: Bool
    var f: Double, q: Double                 // current (gliding) frequency and Q (dB)
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var zl1 = 0.0, zl2 = 0.0, zr1 = 0.0, zr2 = 0.0
    init(hp: Bool, f: Double, q: Double = 0.7071, sr: Double) { self.hp = hp; self.f = f; self.q = q; set(sr) }
    mutating func set(_ sr: Double) {
        let nyq = sr / 2, fr = min(max(f, 0), nyq) / nyq
        if fr >= 1 { if hp { b0 = 0; b1 = 0; b2 = 0; a1 = 0; a2 = 0 } else { b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0 }; return }
        if fr <= 0 { if hp { b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0 } else { b0 = 0; b1 = 0; b2 = 0; a1 = 0; a2 = 0 }; return }
        let w0 = Double.pi * fr, alpha = sin(w0) / (2 * pow(10, q / 20)), c = cos(w0)
        let a0 = 1 + alpha
        if hp { b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0 }
        else { b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0 }
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }
    @inline(__always) mutating func run(_ l: inout Double, _ r: inout Double) {
        let yl = b0 * l + zl1; zl1 = b1 * l - a1 * yl + zl2; zl2 = b2 * l - a2 * yl; l = yl
        let yr = b0 * r + zr1; zr1 = b1 * r - a1 * yr + zr2; zr2 = b2 * r - a2 * yr; r = yr
    }
}

/// One channel strip, after the deck player and before the master bus.
final class ChannelStrip {
    let sr: Double
    // Linkwitz-Riley crossovers at 250 Hz and 2.5 kHz
    var lo1: Biquad, lo2: Biquad, mHp1: Biquad, mHp2: Biquad, mLp1: Biquad, mLp2: Biquad, hi1: Biquad, hi2: Biquad
    var cfxLp: Biquad, cfxHp: Biquad
    var gTrim = 0.0, gLow = 1.0, gMid = 1.0, gHigh = 1.0, gFader = 1.0, gXf = 1.0, gPfl = 0.0
    var tTrim = 0.0, tLow = 1.0, tMid = 1.0, tHigh = 1.0, tFader = 1.0, tXf = 1.0, tPfl = 0.0
    var tLpF = 22000.0, tLpQ = 0.707, tHpF = 10.0, tHpQ = 0.707
    let fx: FxUnit
    var peakL: Float = 0, peakR: Float = 0
    init(sr: Double) {
        self.sr = sr
        lo1 = Biquad(hp: false, f: 250, sr: sr); lo2 = lo1
        mHp1 = Biquad(hp: true, f: 250, sr: sr); mHp2 = mHp1
        mLp1 = Biquad(hp: false, f: 2500, sr: sr); mLp2 = mLp1
        hi1 = Biquad(hp: true, f: 2500, sr: sr); hi2 = hi1
        cfxLp = Biquad(hp: false, f: 22000, sr: sr); cfxHp = Biquad(hp: true, f: 10, sr: sr)
        fx = FxUnit(sampleRate: sr)
        gTrim = MixerCurves.trimGain(0.5); tTrim = gTrim
    }
    func apply(_ m: MixerState, _ i: Int) {
        tTrim = MixerCurves.trimGain(m.trim[i]); tHigh = MixerCurves.eqGain(m.hi[i]); tMid = MixerCurves.eqGain(m.mid[i]); tLow = MixerCurves.eqGain(m.low[i])
        tFader = MixerCurves.faderGain(m.fader[i]); tPfl = m.pfl[i] ? 1 : 0
        let c = MixerCurves.cfx(m.cfx[i]); tLpF = c.lp; tLpQ = c.lpQ; tHpF = c.hp; tHpQ = c.hpQ
        tXf = m.active[i] ? MixerCurves.xfGain(deck: i, m.xfader) : 0
    }
    /// in: the deck's output in io; out: io = post-fader-and-crossfader signal, cue += the CUE send
    func process(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int, time: Double,
                 cueL: UnsafeMutablePointer<Float>, cueR: UnsafeMutablePointer<Float>) {
        let k = 1 - exp(-1 / (0.008 * sr))          // setTargetAtTime, 8 ms
        // the CFX filters glide too (coefficients every 32 samples)
        var i = 0
        while i < n {
            let m = min(32, n - i)
            let kb = 1 - pow(1 - k, Double(m))
            cfxLp.f += (tLpF - cfxLp.f) * kb; cfxLp.q += (tLpQ - cfxLp.q) * kb; cfxLp.set(sr)
            cfxHp.f += (tHpF - cfxHp.f) * kb; cfxHp.q += (tHpQ - cfxHp.q) * kb; cfxHp.set(sr)
            for j in i..<(i + m) {
                gTrim += (tTrim - gTrim) * k; gLow += (tLow - gLow) * k; gMid += (tMid - gMid) * k; gHigh += (tHigh - gHigh) * k
                let x0 = Double(L[j]) * gTrim, y0 = Double(R[j]) * gTrim
                var al = x0, ar = y0; lo1.run(&al, &ar); lo2.run(&al, &ar)
                var bl = x0, br = y0; mHp1.run(&bl, &br); mHp2.run(&bl, &br); mLp1.run(&bl, &br); mLp2.run(&bl, &br)
                var cl = x0, cr = y0; hi1.run(&cl, &cr); hi2.run(&cl, &cr)
                var l = al * gLow + bl * gMid + cl * gHigh, r = ar * gLow + br * gMid + cr * gHigh
                cfxLp.run(&l, &r); cfxHp.run(&l, &r)
                L[j] = Float(l); R[j] = Float(r)
            }
            i += m
        }
        // Beat FX / Pad FX insert: after the EQ and CFX filter, before CUE, the meters and the fader
        fx.process(L, R, n, time: time)
        var pl: Float = 0, pr: Float = 0
        for j in 0..<n {
            gPfl += (tPfl - gPfl) * k; gFader += (tFader - gFader) * k; gXf += (tXf - gXf) * k
            let l = L[j], r = R[j]
            if abs(l) > pl { pl = abs(l) }; if abs(r) > pr { pr = abs(r) }
            cueL[j] += Float(Double(l) * gPfl); cueR[j] += Float(Double(r) * gPfl)
            let g = gFader * gXf
            L[j] = Float(Double(l) * g); R[j] = Float(Double(r) * g)
        }
        peakL = max(pl, peakL * 0.9); peakR = max(pr, peakR * 0.9)
    }
}

/// Peak limiter like the web app's DynamicsCompressor (threshold -1 dB, knee 0, ratio 20, attack 1 ms,
/// release 80 ms), with the compressor's automatic makeup gain.
struct Limiter {
    var env = 0.0
    let att: Double, rel: Double
    let thr = -1.0, ratio = 20.0
    let makeup: Double
    init(sr: Double) {
        att = 1 - exp(-1 / (0.001 * sr)); rel = 1 - exp(-1 / (0.08 * sr))
        // Web Audio: makeup = (1 / gain at 0 dBFS) ^ 0.6
        let at0 = -1.0 + 1.0 / 20.0
        makeup = dbToGain(-at0 * 0.6)
    }
    @inline(__always) mutating func run(_ l: inout Double, _ r: inout Double) {
        let p = max(abs(l), abs(r))
        env += (p - env) * (p > env ? att : rel)
        let db = 20 * log10(max(env, 1e-9))
        let red = db > thr ? (db - thr) * (1 - 1 / ratio) : 0
        let g = dbToGain(-red) * makeup
        l *= g; r *= g
    }
}

public enum OutputMode { case stereo, quad, split }
