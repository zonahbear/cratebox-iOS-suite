package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

// Beat FX / Pad FX: a line-by-line port of CrateboxKit FxUnit.swift (the web app's FxUnit WORKLET). One unit
// per insert point (every deck channel, and the master), two slots: "beat" (the BEAT FX unit, when it's
// routed here) and "pad" (PAD FX, decks only). Timed by a beat clock (where the beat is now and how fast
// it's moving), so echoes, rolls and gates land on the grid. With nothing on and no tails left it's a
// straight copy. Tested sample for sample against the JS (Fixtures/dsp).

enum class FxKind(val raw: String) {
    NONE(""), ECHO("ECHO"), DELAY("DELAY"), PING_PONG("PING PONG"), REVERB("REVERB"), FLANGER("FLANGER"),
    FILTER("FILTER"), TRANS("TRANS"), ROLL("ROLL"), HPF("HPF"), LPF("LPF");
    companion object { fun of(raw: String?): FxKind? = entries.firstOrNull { it.raw == raw } }
}

data class FxClock(val t0: Double = 0.0, val beat0: Double = 0.0, val bps: Double = 0.0, val spb: Double = 0.5)

internal const val FX_HIST = 5.0                     // seconds of input history (roll) and of each delay line

internal class Reverb(sr: Double) {
    private val k = sr / 44100
    private fun mk(n: Int) = FloatArray(max(8, jsRound(n * k).toInt()))
    private val combs = intArrayOf(1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)
    private val aps = intArrayOf(556, 441, 341, 225)
    val cL = Array(8) { mk(combs[it]) }
    val cR = Array(8) { mk(combs[it] + 23) }
    val ci = IntArray(8)
    val fsL = DoubleArray(8)
    val fsR = DoubleArray(8)
    val aL = Array(4) { mk(aps[it]) }
    val aR = Array(4) { mk(aps[it] + 23) }
    val ai = IntArray(4)
}

class FxSlot internal constructor(internal val sr: Double) {
    var fx = FxKind.NONE; internal set
    var on = false; internal set
    var beats = 0.5; internal set
    var depth = 0.6; internal set
    internal var g = 0.0
    internal var inG = 0.0                // smoothed: effect amount / feed into delays and reverb
    var active = false; internal set   // on, or still ringing out
    // allocated up front, never on the audio thread
    internal val dn = ceil(FX_HIST * sr).toInt()
    internal val dL = FloatArray(dn)
    internal val dR = FloatArray(dn)
    internal var w = 0
    internal val fl = DoubleArray(4)
    internal val fr = DoubleArray(4)
    internal val cf = DoubleArray(5)
    internal val rev = Reverb(sr)
    internal var rollOn = false
    internal var rollStart = 0
    internal var rollLen = 0
    internal var rollPos = 0
    internal var quiet = 0
    internal var tg: Double? = null
    internal var cfReady = false

    /** The JS slot "set" message: null leaves a setting as it is. */
    fun set(fx: FxKind? = null, beats: Double? = null, depth: Double? = null, on: Boolean? = null) {
        if (fx != null && fx != this.fx) { this.fx = fx; rollOn = false; cfReady = false }
        if (beats != null) this.beats = beats
        if (depth != null) this.depth = depth
        if (on != null) { if (on && !this.on) rollOn = false; this.on = on }
        if (this.on) { active = true; quiet = 0 }
    }
}

// RBJ biquad coefficients, into c[0..4]
internal fun biq(c: DoubleArray, hp: Boolean, f: Double, q: Double, sr: Double) {
    val w = 2 * Math.PI * min(f, sr * 0.45) / sr
    val cs = cos(w)
    val al = sin(w) / (2 * q)
    val b0: Double; val b1: Double; val b2: Double
    if (hp) { b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2 } else { b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2 }
    val a0 = 1 + al
    c[0] = b0 / a0; c[1] = b1 / a0; c[2] = b2 / a0; c[3] = (-2 * cs) / a0; c[4] = (1 - al) / a0
}

class FxUnit(val sampleRate: Double) {
    private val hn = ceil(FX_HIST * sampleRate).toInt()
    private val hL = FloatArray(hn)
    private val hR = FloatArray(hn)
    private var hw = 0
    val beat = FxSlot(sampleRate)
    val pad = FxSlot(sampleRate)
    @Volatile var clock = FxClock()

    /** In place: oL/oR hold the input (from index 0) and get the output. `time` is the audio clock at the block's start. */
    fun process(oL: FloatArray, oR: FloatArray, n: Int, time: Double) {
        var hw = this.hw
        for (i in 0 until n) {
            hL[hw] = oL[i]; hR[hw] = oR[i]
            hw += 1; if (hw == hn) hw = 0
        }
        if (!beat.active && !pad.active) { this.hw = hw; return }
        val c = clock
        val sr = sampleRate
        val beatAt0 = c.beat0 + (time - c.t0) * c.bps
        val dBeat = c.bps / sr
        val histEnd = hw
        if (beat.active) run(beat, oL, oR, n, beatAt0, dBeat, c.spb, histEnd)
        if (pad.active) run(pad, oL, oR, n, beatAt0, dBeat, c.spb, histEnd)
        this.hw = hw
    }

    private fun run(s: FxSlot, oL: FloatArray, oR: FloatArray, N: Int, beat0: Double, dBeat: Double, spb: Double, histEnd: Int) {
        val sr = sampleRate
        val fx = s.fx
        val on = s.on
        val depth = s.depth
        val gStep = 1 / (0.004 * sr)        // 4 ms fades in and out: no clicks
        var g = s.g
        var inG = s.inG
        var peak = 0.0
        val delayFamily = fx == FxKind.ECHO || fx == FxKind.DELAY || fx == FxKind.PING_PONG
        val dl0 = s.dL
        val dr0 = s.dR
        val dn = s.dn
        val fb = if (fx == FxKind.ECHO) 0.6 else if (fx == FxKind.PING_PONG) 0.55 else 0.32
        val dSamp = if (delayFamily) max(1, min(dn - 2, jsRound(s.beats * spb * sr).toInt())) else 0
        var w = s.w
        val rv = s.rev
        for (i in 0 until N) {
            val xl = oL[i].toDouble()
            val xr = oR[i].toDouble()
            val want = if (on) 1.0 else 0.0
            g += if (g < want) min(gStep, want - g) else -min(gStep, g - want)
            inG += if (inG < want) min(gStep, want - inG) else -min(gStep, inG - want)
            var yl = xl
            var yr = xr
            if (delayFamily) {
                // echoes: the dry signal always passes; switching off stops feeding the delay, so they ring out
                var r = w - dSamp; if (r < 0) r += dn
                val dl = dl0[r].toDouble()
                val dr = dr0[r].toDouble()
                if (fx == FxKind.PING_PONG) { dl0[w] = ((xl + xr) * 0.5 * inG + dr * fb).toFloat(); dr0[w] = (dl * fb).toFloat() }
                else { dl0[w] = (xl * inG + dl * fb).toFloat(); dr0[w] = (xr * inG + dr * fb).toFloat() }
                yl = xl + dl * depth; yr = xr + dr * depth
                val a = abs(dl) + abs(dr); if (a > peak) peak = a
                w += 1; if (w == dn) w = 0
            } else if (fx == FxKind.REVERB) {
                // Freeverb: 8 damped combs into 4 allpasses per side; switching off lets the room ring out
                val inS = (xl + xr) * 0.015 * inG
                var sl = 0.0
                var sr2 = 0.0
                for (k in 0 until 8) {
                    val bl = rv.cL[k]; val br = rv.cR[k]
                    val j = rv.ci[k]
                    val ol = bl[j % bl.size].toDouble()
                    val or = br[j % br.size].toDouble()
                    rv.fsL[k] = ol * 0.8 + rv.fsL[k] * 0.2; rv.fsR[k] = or * 0.8 + rv.fsR[k] * 0.2
                    bl[j % bl.size] = (inS + rv.fsL[k] * 0.86).toFloat(); br[j % br.size] = (inS + rv.fsR[k] * 0.86).toFloat()
                    sl += ol; sr2 += or
                    rv.ci[k] = if (j + 1 >= 1_000_000_000) 0 else j + 1
                }
                for (k in 0 until 4) {
                    val al = rv.aL[k]; val ar = rv.aR[k]; val j = rv.ai[k]
                    val bo = al[j % al.size].toDouble()
                    val bo2 = ar[j % ar.size].toDouble()
                    al[j % al.size] = (sl + bo * 0.5).toFloat(); ar[j % ar.size] = (sr2 + bo2 * 0.5).toFloat()
                    sl = bo - sl; sr2 = bo2 - sr2
                    rv.ai[k] = if (j + 1 >= 1_000_000_000) 0 else j + 1
                }
                yl = xl + sl * depth * 1.2; yr = xr + sr2 * depth * 1.2
                val a = abs(sl) + abs(sr2); if (a > peak) peak = a
            } else {
                val beat = beat0 + i * dBeat
                var el = xl
                var er = xr              // the fully-wet signal
                if (fx == FxKind.FLANGER) {
                    // a 1-5 ms delay swept once per cycle (BEAT sets the cycle length), with feedback
                    val cyc = max(0.25, s.beats)
                    val ph = beat / cyc
                    val dd = (0.001 + 0.004 * (0.5 - 0.5 * cos(2 * Math.PI * ph))) * sr
                    var rp = w - dd; if (rp < 0) rp += dn
                    val i0 = rp.toInt()
                    val f = rp - i0
                    val i1 = if (i0 + 1 == dn) 0 else i0 + 1
                    val dl = dl0[i0] + (dl0[i1].toDouble() - dl0[i0]) * f
                    val dr = dr0[i0] + (dr0[i1].toDouble() - dr0[i0]) * f
                    dl0[w] = (xl + dl * 0.6).toFloat(); dr0[w] = (xr + dr * 0.6).toFloat()
                    w += 1; if (w == dn) w = 0
                    el = (xl + dl * depth) / (1 + 0.6 * depth); er = (xr + dr * depth) / (1 + 0.6 * depth)
                } else if (fx == FxKind.FILTER || fx == FxKind.HPF || fx == FxKind.LPF) {
                    if ((i and 31) == 0 || !s.cfReady) {
                        if (fx == FxKind.FILTER) {
                            // LFO low-pass sweep, one cycle per BEAT setting; LEVEL/DEPTH sets how low it dips
                            val ph = beat / max(0.25, s.beats)
                            val f = 20000 * 2.0.pow(-9 * depth * (0.5 - 0.5 * cos(2 * Math.PI * ph)))
                            biq(s.cf, false, f, 2.2, sr)
                        } else if (fx == FxKind.HPF) biq(s.cf, true, 20 * 2.0.pow(9.5 * depth), 1.1, sr)
                        else biq(s.cf, false, 20000 * 2.0.pow(-9.5 * depth), 1.1, sr)
                        s.cfReady = true
                    }
                    val c0 = s.cf[0]; val c1 = s.cf[1]; val c2 = s.cf[2]; val c3 = s.cf[3]; val c4 = s.cf[4]
                    el = c0 * xl + c1 * s.fl[0] + c2 * s.fl[1] - c3 * s.fl[2] - c4 * s.fl[3]
                    s.fl[1] = s.fl[0]; s.fl[0] = xl; s.fl[3] = s.fl[2]; s.fl[2] = el
                    er = c0 * xr + c1 * s.fr[0] + c2 * s.fr[1] - c3 * s.fr[2] - c4 * s.fr[3]
                    s.fr[1] = s.fr[0]; s.fr[0] = xr; s.fr[3] = s.fr[2]; s.fr[2] = er
                } else if (fx == FxKind.TRANS) {
                    // gate: on for the first half of each BEAT-long step, cut (by LEVEL/DEPTH) for the second half
                    val st = max(1.0 / 32, s.beats)
                    val ph = beat / st
                    val frc = ph - floor(ph)
                    val want2 = if (frc < 0.5) 1.0 else 1 - depth
                    val tg = s.tg?.let { it + (want2 - it) * 0.02 } ?: want2     // ~1 ms smoothing
                    s.tg = tg
                    el = xl * tg; er = xr * tg
                } else if (fx == FxKind.ROLL) {
                    // repeat the last BEAT-long slice, lined up with the grid (it starts on the slice the playhead is in)
                    if (!s.rollOn && on) {
                        val len = max(64, min(hn - 256, jsRound(s.beats * spb * sr).toInt()))
                        val st = max(1.0 / 32, s.beats)
                        val frc = beat / st - floor(beat / st)
                        val into = jsRound(frc * len).toInt()      // samples since the slice began
                        val nowIdx = histEnd - N + i
                        var start = nowIdx - into; while (start < 0) start += hn
                        s.rollOn = true; s.rollStart = start; s.rollLen = len; s.rollPos = into
                    }
                    if (s.rollOn) {
                        var j = s.rollStart + (s.rollPos % s.rollLen); if (j >= hn) j -= hn
                        el = hL[j].toDouble(); er = hR[j].toDouble(); s.rollPos += 1
                    }
                    if (!on && g < 0.001) s.rollOn = false
                }
                val mix = if (fx == FxKind.ROLL) max(depth, 0.001) else 1.0
                yl = xl + (el - xl) * g * mix; yr = xr + (er - xr) * g * mix
            }
            oL[i] = yl.toFloat(); oR[i] = yr.toFloat()
        }
        s.g = g; s.inG = inG; s.w = w
        // done ringing out? (off, faded, and the delay lines / reverb have gone quiet for half a second)
        if (!on && g < 0.0005 && inG < 0.0005) {
            if (delayFamily || fx == FxKind.REVERB) {
                if (peak < 1e-4) s.quiet += N else s.quiet = 0
                if (s.quiet > 0.5 * sr) s.active = false
            } else s.active = false
        }
    }
}
