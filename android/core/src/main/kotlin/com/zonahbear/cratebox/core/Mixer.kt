package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

// The mixer: per channel trim, 3-band isolator EQ, CFX filter, FX insert, CUE, fader and crossfader; the
// master (BEAT FX on MASTER, level, limiter) and the headphone mix. Port of CrateboxKit Mixer.swift; the web
// app builds this from Web Audio nodes (buildDeckChain / applyMixer / applyMaster in cratebox.html) and this
// does the same sums: the filters use the Web Audio BiquadFilter formulas (Q in dB for low/high-pass),
// parameter changes glide like setTargetAtTime(v, t, 0.008), and the curves (EQ, trim, fader, crossfader,
// CUE/MASTER) are the app's.

fun dbToGain(db: Double): Double = 10.0.pow(db / 20)

/** Mixer controls, all 0...1 like the hardware (the web app's `M`). Copy before posting to the engine. */
data class MixerState(
    val trim: DoubleArray = DoubleArray(4) { 0.5 }, val hi: DoubleArray = DoubleArray(4) { 0.5 },
    val mid: DoubleArray = DoubleArray(4) { 0.5 }, val low: DoubleArray = DoubleArray(4) { 0.5 },
    val cfx: DoubleArray = DoubleArray(4) { 0.5 }, val fader: DoubleArray = DoubleArray(4) { 1.0 },
    val pfl: BooleanArray = BooleanArray(4),
    var xfader: Double = 0.5, var headMix: Double = 0.0, var masterCue: Boolean = false, var master: Double = 0.8,
    /** decks shown (3 and 4 only in 4-deck mode); hidden ones are muted */
    val active: BooleanArray = booleanArrayOf(true, true, false, false),
) {
    fun deepCopy() = MixerState(trim.copyOf(), hi.copyOf(), mid.copyOf(), low.copyOf(), cfx.copyOf(), fader.copyOf(),
        pfl.copyOf(), xfader, headMix, masterCue, master, active.copyOf())
}

object MixerCurves {
    fun eqGain(v: Double): Double {
        if (v < 0.5) return if (v < 0.02) 0.0 else (v / 0.5).pow(2.2)          // left = kill
        return 1 + (v - 0.5) * 2 * (dbToGain(6.0) - 1)                         // right = +6 dB
    }
    fun trimGain(v: Double): Double = if (v < 0.5) (if (v < 0.01) 0.0 else dbToGain(-24 + 48 * v)) else dbToGain((v - 0.5) * 18)
    fun faderGain(v: Double): Double = if (v < 0.005) 0.0 else v.pow(1.8)
    /** crossfader: both full at the centre; decks 1 and 3 on the left, 2 and 4 on the right */
    fun xfGain(deck: Int, x: Double): Double {
        val g = if (deck % 2 == 0) (if (x <= 0.5) 1.0 else cos((x - 0.5) * Math.PI)) else (if (x >= 0.5) 1.0 else cos((0.5 - x) * Math.PI))
        return if (g < 0.002) 0.0 else g
    }
    data class Cfx(val lp: Double, val lpQ: Double, val hp: Double, val hpQ: Double)
    /** CFX knob -> (low-pass Hz, Q dB, high-pass Hz, Q dB): left = low-pass, right = high-pass, centre = off */
    fun cfx(v: Double): Cfx {
        if (v < 0.47) return Cfx(60 * (20000.0 / 60).pow(v / 0.47), 1.4, 10.0, 0.707)
        if (v > 0.53) return Cfx(22000.0, 0.707, 20 * (9000.0 / 20).pow((v - 0.53) / 0.47), 1.4)
        return Cfx(22000.0, 0.707, 10.0, 0.707)
    }
    /** CUE/MASTER knob -> (cue gain, master gain), equal power past 12 o'clock */
    fun headMix(v: Double): Pair<Double, Double> {
        val hm = min(1.0, max(0.0, (v - 0.53) / 0.47))
        return cos(hm * Math.PI / 2) to sin(hm * Math.PI / 2)
    }
    fun masterGain(v: Double): Double = v.pow(1.6) * 1.2
}

/** A Web Audio BiquadFilter (lowpass / highpass), stereo, transposed direct form II. run() works on [l] and [r]. */
internal class Biquad(val hp: Boolean, var f: Double, var q: Double = 0.7071, sr: Double) {
    var b0 = 1.0; var b1 = 0.0; var b2 = 0.0; var a1 = 0.0; var a2 = 0.0
    var zl1 = 0.0; var zl2 = 0.0; var zr1 = 0.0; var zr2 = 0.0
    var l = 0.0; var r = 0.0
    init { set(sr) }
    fun copy(sr: Double) = Biquad(hp, f, q, sr)
    fun set(sr: Double) {
        val nyq = sr / 2
        val fr = min(max(f, 0.0), nyq) / nyq
        if (fr >= 1) { if (hp) { b0 = 0.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0 } else { b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0 }; return }
        if (fr <= 0) { if (hp) { b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0 } else { b0 = 0.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0 }; return }
        val w0 = Math.PI * fr
        val alpha = sin(w0) / (2 * 10.0.pow(q / 20))
        val c = cos(w0)
        val a0 = 1 + alpha
        if (hp) { b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0 }
        else { b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0 }
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }
    fun run() {
        val yl = b0 * l + zl1; zl1 = b1 * l - a1 * yl + zl2; zl2 = b2 * l - a2 * yl; l = yl
        val yr = b0 * r + zr1; zr1 = b1 * r - a1 * yr + zr2; zr2 = b2 * r - a2 * yr; r = yr
    }
    fun run(inL: Double, inR: Double) { l = inL; r = inR; run() }
}

/** One channel strip, after the deck player and before the master bus. */
internal class ChannelStrip(val sr: Double) {
    // Linkwitz-Riley crossovers at 250 Hz and 2.5 kHz
    private val lo1 = Biquad(false, 250.0, sr = sr); private val lo2 = lo1.copy(sr)
    private val mHp1 = Biquad(true, 250.0, sr = sr); private val mHp2 = mHp1.copy(sr)
    private val mLp1 = Biquad(false, 2500.0, sr = sr); private val mLp2 = mLp1.copy(sr)
    private val hi1 = Biquad(true, 2500.0, sr = sr); private val hi2 = hi1.copy(sr)
    private val cfxLp = Biquad(false, 22000.0, sr = sr); private val cfxHp = Biquad(true, 10.0, sr = sr)
    private var gTrim = MixerCurves.trimGain(0.5); private var gLow = 1.0; private var gMid = 1.0; private var gHigh = 1.0
    private var gFader = 1.0; private var gXf = 1.0; private var gPfl = 0.0
    private var tTrim = gTrim; private var tLow = 1.0; private var tMid = 1.0; private var tHigh = 1.0
    private var tFader = 1.0; private var tXf = 1.0; private var tPfl = 0.0
    private var tLpF = 22000.0; private var tLpQ = 0.707; private var tHpF = 10.0; private var tHpQ = 0.707
    val fx = FxUnit(sr)
    var peakL = 0f; var peakR = 0f

    fun apply(m: MixerState, i: Int) {
        tTrim = MixerCurves.trimGain(m.trim[i]); tHigh = MixerCurves.eqGain(m.hi[i]); tMid = MixerCurves.eqGain(m.mid[i]); tLow = MixerCurves.eqGain(m.low[i])
        tFader = MixerCurves.faderGain(m.fader[i]); tPfl = if (m.pfl[i]) 1.0 else 0.0
        val c = MixerCurves.cfx(m.cfx[i]); tLpF = c.lp; tLpQ = c.lpQ; tHpF = c.hp; tHpQ = c.hpQ
        tXf = if (m.active[i]) MixerCurves.xfGain(i, m.xfader) else 0.0
    }

    /** in: the deck's output in L/R; out: L/R = post-fader-and-crossfader signal, cue += the CUE send */
    fun process(L: FloatArray, R: FloatArray, n: Int, time: Double, cueL: FloatArray, cueR: FloatArray) {
        val k = 1 - exp(-1 / (0.008 * sr))          // setTargetAtTime, 8 ms
        // the CFX filters glide too (coefficients every 32 samples)
        var i = 0
        while (i < n) {
            val m = min(32, n - i)
            val kb = 1 - (1 - k).pow(m.toDouble())
            cfxLp.f += (tLpF - cfxLp.f) * kb; cfxLp.q += (tLpQ - cfxLp.q) * kb; cfxLp.set(sr)
            cfxHp.f += (tHpF - cfxHp.f) * kb; cfxHp.q += (tHpQ - cfxHp.q) * kb; cfxHp.set(sr)
            for (j in i until i + m) {
                gTrim += (tTrim - gTrim) * k; gLow += (tLow - gLow) * k; gMid += (tMid - gMid) * k; gHigh += (tHigh - gHigh) * k
                val x0 = L[j] * gTrim
                val y0 = R[j] * gTrim
                lo1.run(x0, y0); lo2.run(lo1.l, lo1.r)
                mHp1.run(x0, y0); mHp2.run(mHp1.l, mHp1.r); mLp1.run(mHp2.l, mHp2.r); mLp2.run(mLp1.l, mLp1.r)
                hi1.run(x0, y0); hi2.run(hi1.l, hi1.r)
                val l = lo2.l * gLow + mLp2.l * gMid + hi2.l * gHigh
                val r = lo2.r * gLow + mLp2.r * gMid + hi2.r * gHigh
                cfxLp.run(l, r); cfxHp.run(cfxLp.l, cfxLp.r)
                L[j] = cfxHp.l.toFloat(); R[j] = cfxHp.r.toFloat()
            }
            i += m
        }
        // Beat FX / Pad FX insert: after the EQ and CFX filter, before CUE, the meters and the fader
        fx.process(L, R, n, time)
        var pl = 0f
        var pr = 0f
        for (j in 0 until n) {
            gPfl += (tPfl - gPfl) * k; gFader += (tFader - gFader) * k; gXf += (tXf - gXf) * k
            val l = L[j]
            val r = R[j]
            if (abs(l) > pl) pl = abs(l); if (abs(r) > pr) pr = abs(r)
            cueL[j] += (l * gPfl).toFloat(); cueR[j] += (r * gPfl).toFloat()
            val g = gFader * gXf
            L[j] = (l * g).toFloat(); R[j] = (r * g).toFloat()
        }
        peakL = max(pl, peakL * 0.9f); peakR = max(pr, peakR * 0.9f)
    }
}

/** Peak limiter at -1 dB (ratio 20, release 80 ms), like the web app's DynamicsCompressor on the master,
 *  except that it catches a peak at once (the browser's looks 6 ms ahead) and has no makeup gain, so the
 *  output never goes over full scale. Works on [l] and [r]. */
internal class Limiter(sr: Double) {
    private var env = 0.0
    private val rel = 1 - exp(-1 / (0.08 * sr))
    private val thr = -1.0
    private val ratio = 20.0
    var l = 0.0; var r = 0.0
    fun run() {
        val p = max(abs(l), abs(r))
        if (p > env) env = p else env += (p - env) * rel
        val db = 20 * log10(max(env, 1e-9))
        if (db > thr) { val g = dbToGain(-(db - thr) * (1 - 1 / ratio)); l *= g; r *= g }
    }
}

/** STEREO: master on 1/2. QUAD: master 1/2, headphones 3/4. QUAD_SWAPPED: headphones 1/2, master 3/4.
 *  SPLIT: mono master left, mono cue right. */
enum class OutputMode { STEREO, QUAD, QUAD_SWAPPED, SPLIT }
