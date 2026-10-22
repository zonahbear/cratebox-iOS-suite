package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

// Deck player: a line-by-line port of CrateboxKit DeckPlayer.swift, itself a port of the web app's DeckPlayer
// (the WORKLET in cratebox.html), so a deck sounds the same on Android. Tested sample for sample against the JS
// (ios/CrateboxKit/Tests/.../Fixtures/dsp, made by ios/tools/dsp_oracle.js). Real-time safe: render() doesn't
// allocate or lock.
//
// With master tempo (keylock) on, the playhead still moves at the tempo rate, but the sound is rebuilt
// from 46 ms grains played at normal speed (WSOLA): each new grain is taken near the playhead, at the
// offset that best lines up with the previous grain's tail.

/** JS Math.round: halves go up (toward +infinity). */
fun jsRound(x: Double): Double = floor(x + 0.5)

sealed class DeckMessage {
    object Unload : DeckMessage()
    /** the audio itself is given with setTrack */
    data class Load(val mt: Boolean? = null, val spin: Double? = null) : DeckMessage()
    data class Play(val v: Boolean) : DeckMessage()
    data class Rate(val v: Double) : DeckMessage()
    data class Seek(val v: Double, val seq: Int) : DeckMessage()
    data class Bend(val v: Double) : DeckMessage()
    data class Scratch(val v: Boolean, val noCoast: Boolean) : DeckMessage()
    data class Spin(val v: Double) : DeckMessage()
    data class Jog(val v: Double) : DeckMessage()
    data class Loop(val on: Boolean, val a: Double, val b: Double) : DeckMessage()
    data class Mt(val v: Boolean) : DeckMessage()
}

/** Decoded stereo audio, 32-bit float. */
class PCMTrack(val left: FloatArray, val right: FloatArray, val sampleRate: Double) {
    val count: Int = min(left.size, right.size)
    constructor(count: Int, sampleRate: Double) : this(FloatArray(max(count, 1)), FloatArray(max(count, 1)), sampleRate)
}

class DeckPlayer(val sampleRate: Double) {
    // the track: owned by whoever loaded it
    var track: PCMTrack? = null; private set
    private var L: FloatArray? = null
    private var R: FloatArray? = null
    var len = 0; private set
    var pos = 0.0; private set
    var playing = false; private set
    var rate = 1.0; private set
    private var bend = 0.0
    var scratching = false; private set
    private var target = 0.0
    private var vel = 0.0
    private var loopOn = false
    private var loopIn = 0.0
    private var loopOut = 0.0
    private var amp = 0.0
    var ended = false; private set
    var coast = false; private set
    private var spinA = 9 / 2.5
    var seq = 0; private set
    // keylock
    var mt = false; private set
    private val H = jsRound(0.023 * sampleRate).toInt()
    private val Nw = 2 * H
    private val S = jsRound(0.013 * sampleRate).toInt()
    private val ramp = jsRound(0.002 * sampleRate).toInt()
    private val win = FloatArray(Nw) { (0.5 - 0.5 * cos(2 * Math.PI * it / Nw)).toFloat() }
    private val gS = DoubleArray(2)
    private val gK = IntArray(2)
    private val gF = IntArray(2)
    private var cur = 0
    private var ph = 0
    private var prevS = 0.0
    private var fresh = true
    private val buf = FloatArray(2 * S + H + 8)
    private val tpl = FloatArray(H)

    init { flush() }

    private fun flush() { gK[0] = Nw; gK[1] = Nw; ph = 0; fresh = true }

    /** The audio to play (call `handle(Load)` right after, like the JS "load" message). */
    fun setTrack(t: PCMTrack?) { track = t; L = t?.left; R = t?.right; len = t?.count ?: 0 }

    fun handle(m: DeckMessage) {
        when (m) {
            is DeckMessage.Unload -> { track = null; L = null; R = null; len = 0; playing = false; amp = 0.0 }
            is DeckMessage.Load -> {
                pos = 0.0; target = 0.0
                playing = false; loopOn = false; amp = 0.0; vel = 0.0; ended = false
                m.mt?.let { mt = it }
                m.spin?.let { if (it != 0.0) spinA = 9 / it }
                coast = false; flush()
            }
            is DeckMessage.Play -> { playing = m.v; if (m.v) ended = false }
            is DeckMessage.Rate -> rate = m.v
            is DeckMessage.Seek -> { seq = m.seq; pos = max(0.0, min((len - 2).toDouble(), m.v)); target = pos; vel = 0.0; coast = false; flush() }
            is DeckMessage.Bend -> bend = max(-0.6, min(0.6, bend + m.v))
            is DeckMessage.Scratch -> {
                if (m.v) { vel = if (coast) vel else (if (playing) rate else 0.0); coast = false }
                else {
                    // let go mid-fling (backwards, or well off the motor speed): keep spinning and coast back
                    val goal = if (playing) rate else 0.0
                    vel = max(-10.0, min(10.0, vel))
                    coast = !m.noCoast && (vel < -0.5 || abs(vel - goal) > 1.5)
                    if (!coast) vel = 0.0
                }
                scratching = m.v; target = pos; flush()
            }
            is DeckMessage.Spin -> spinA = 9 / m.v
            is DeckMessage.Jog -> target += m.v
            is DeckMessage.Loop -> { loopOn = m.on; loopIn = m.a; loopOut = m.b }
            is DeckMessage.Mt -> { mt = m.v; flush() }
        }
    }

    // source index for keylock reads: wraps inside an active loop; -1 = silence
    private fun idx(p0: Double): Int {
        var p = p0
        if (loopOn && loopOut > loopIn && p >= loopOut) {
            val w = loopOut - loopIn
            p = loopIn + (p - loopIn) % w
        }
        val j = p.toInt()                                   // JS p | 0
        return if (j in 0 until len) j else -1
    }
    private fun mono(p: Double): Double {
        val j = idx(p)
        return if (j < 0) 0.0 else L!![j].toDouble() + R!![j].toDouble()
    }

    private fun score(o: Int, step: Int): Double {
        var c = 0.0
        var e = 1e-9
        var k = 0
        while (k < H) { val y = buf[o + k].toDouble(); c += tpl[k].toDouble() * y; e += y * y; k += step }
        return c / sqrt(e)
    }

    private fun startGrain(pos: Double, v: Double) {
        cur = cur xor 1
        val slot = cur
        if (fresh) {
            val s = jsRound(pos)
            gS[slot] = s; gK[slot] = 0; gF[slot] = 1; gK[slot xor 1] = Nw
            prevS = s; fresh = false; return
        }
        val s0 = jsRound(pos + (v - 1) * H)               // keeps each grain centred on the playhead
        val nat = prevS + H                                // where the previous grain would continue
        var best = 0.0
        val Sd = S.toDouble()
        if (nat >= s0 - Sd && nat <= s0 + Sd && abs(v - 1) < 1e-6) best = nat - s0
        else {
            val base = s0 - Sd
            var te = 0.0
            for (k in 0 until H) { val x = mono(nat + k); tpl[k] = x.toFloat(); te += x * x }
            if (te > 1e-9) {
                val B = 2 * S + H
                for (k in 0 until B) buf[k] = mono(base + k).toFloat()
                var bs = Double.NEGATIVE_INFINITY
                var bo = S
                var o = 0
                while (o <= 2 * S) { val sc = score(o, 8); if (sc > bs) { bs = sc; bo = o }; o += 4 }
                val lo = max(0, bo - 4)
                val hi = min(2 * S, bo + 4)
                bs = Double.NEGATIVE_INFINITY
                var fo = bo
                for (o2 in lo..hi) { val sc = score(o2, 1); if (sc > bs) { bs = sc; fo = o2 } }
                best = (fo - S).toDouble()
            }
        }
        val s = s0 + best
        gS[slot] = s; gK[slot] = 0; gF[slot] = 0; prevS = s
    }

    /** Renders `n` frames into oL/oR (overwritten, from index 0). */
    fun render(oL: FloatArray, oR: FloatArray, n: Int) {
        for (i in 0 until n) { oL[i] = 0f; oR[i] = 0f }
        val L = L ?: return
        val R = R ?: return
        if (!playing && !scratching && !coast && amp == 0.0) return
        val sr = sampleRate
        var pos = this.pos
        var vel = this.vel
        var amp = this.amp
        val follow = 1 / (0.012 * sr)      // scratch: catch up with the hand in about 12 ms
        val ampStep = 1 / (0.005 * sr)     // 5 ms fades on start/stop: no clicks
        val useMT = mt && !scratching && !coast
        val spinStep = spinA / sr
        val lenD = len.toDouble()
        for (i in 0 until n) {
            var v: Double
            val want: Double
            if (scratching) {
                vel += ((target - pos) * follow - vel) * 0.02
                v = vel; want = 1.0
            } else if (coast) {
                val goal = if (playing) rate else 0.0
                vel = if (vel < goal) min(goal, vel + spinStep) else max(goal, vel - spinStep)
                if (vel == goal) coast = false
                v = vel; want = 1.0
            } else {
                want = if (playing) 1.0 else 0.0
                v = if (playing) rate * (1 + bend) else (if (amp > 0) rate else 0.0)
            }
            if (want > amp) amp = min(want, amp + ampStep) else if (want < amp) amp = max(want, amp - ampStep)
            if (amp > 0.0001 && pos >= 0 && pos < lenD - 1) {
                if (useMT) {
                    if (ph == 0) startGrain(pos, v)
                    var l = 0.0
                    var r = 0.0
                    for (g in 0 until 2) {
                        val k = gK[g]
                        if (k >= Nw) continue
                        val j = idx(gS[g] + k)
                        if (j >= 0) {
                            val w: Double = if (gF[g] != 0 && k < H) (if (k < ramp) k.toDouble() / ramp else 1.0) else win[k].toDouble()
                            l += L[j] * w; r += R[j] * w
                        }
                        gK[g] = k + 1
                    }
                    oL[i] = (l * amp).toFloat(); oR[i] = (r * amp).toFloat()
                    ph += 1; if (ph >= H) ph = 0
                } else {
                    val i0 = pos.toInt()
                    val f = pos - i0
                    val a0 = L[i0].toDouble(); val a1 = L[i0 + 1].toDouble(); val b0 = R[i0].toDouble(); val b1 = R[i0 + 1].toDouble()
                    oL[i] = ((a0 + (a1 - a0) * f) * amp).toFloat()
                    oR[i] = ((b0 + (b1 - b0) * f) * amp).toFloat()
                }
            } else if (useMT && !fresh) flush()
            pos += v
            if (loopOn && v > 0 && pos >= loopOut && loopOut > loopIn) {
                val w = loopOut - loopIn
                pos -= w
                if (scratching) target -= w
            }
            if (pos < 0) { pos = 0.0; if (target < 0) target = 0.0 }
            if (pos >= lenD - 1) { pos = lenD - 1; if (playing) { playing = false; ended = true } }
        }
        this.pos = pos; this.vel = vel; this.amp = amp
        bend *= 0.96
        if (abs(bend) < 1e-5) bend = 0.0
    }

    /** What the deck's moving at (the JS report's `speed`). */
    val speed: Double get() = if (scratching || coast) vel else (if (playing) rate * (1 + bend) else 0.0)
}
