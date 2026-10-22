package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

// Track analysis: BPM and beat grid, phrases, key and the waveform. A line-by-line port of CrateboxKit
// Analysis.swift, which ports the web app's ANALYZER (cratebox.html), so a track gets the same grid, key and
// phrases on Android as in the browser; tested against the JS on the synthetic test tracks
// (Fixtures/analysis.json, ios/tools/analysis_oracle.js). Where the JS keeps numbers in a Float32Array, this
// keeps them in FloatArray (same rounding). Kotlin's sortedWith/sortedBy are stable, like JS Array.sort.

data class Phrase(val start: Double, val bars: Int, val label: String)

class Waveform(
    val duration: Double, val wps: Int,
    val peak: ByteArray, val rms: ByteArray, val low: ByteArray, val mid: ByteArray, val high: ByteArray,
) {
    override fun equals(other: Any?) = other is Waveform && duration == other.duration && wps == other.wps &&
        peak.contentEquals(other.peak) && rms.contentEquals(other.rms) && low.contentEquals(other.low) &&
        mid.contentEquals(other.mid) && high.contentEquals(other.high)
    override fun hashCode() = peak.contentHashCode()
}

data class AnalysisResult(
    val wave: Waveform?, val bpm: Double, val firstBeat: Double, val gridConf: Double,
    val key: Int, val keyConf: Double, val phrases: List<Phrase>,
)

data class GridResult(val bpm: Double, val firstBeat: Double, val conf: Double)
data class KeyResult(val key: Int, val keyConf: Double)

fun jsFloor(x: Double) = floor(x)
fun jsCeil(x: Double) = ceil(x)

object Analysis {
    /** The app's downmix before analysis: mono, decimated by whole samples to about `target` Hz. */
    fun monoFor(chs: List<FloatArray>, length: Int, sampleRate: Double, target: Double = 11025.0): Pair<FloatArray, Double> {
        val f = max(1, jsRound(sampleRate / target).toInt())
        val n = length / f
        val out = FloatArray(n)
        val use = chs.take(2)
        val k = 1 / (f * use.size).toDouble()
        for (i in 0 until n) {
            var s = 0.0
            for (ch in use) for (j in 0 until f) s += ch[i * f + j]
            out[i] = (s * k).toFloat()
        }
        return out to sampleRate / f
    }

    fun analyze(
        x: FloatArray, fs: Double, range: Pair<Double, Double> = 88.0 to 176.0, waveSource: Pair<FloatArray, Double>? = null,
        noWave: Boolean = false, grid: Pair<Double, Double>? = null,
    ): AnalysisResult {
        val wave = if (noWave) null else waveform(waveSource?.first ?: x, waveSource?.second ?: fs)
        val g = grid?.let { GridResult(it.first, it.second, 0.0) } ?: beatGrid(x, fs, range)
        val phrases = phraseAnalysis(x, fs, g.bpm, g.firstBeat)
        val k = detectKey(x, fs)
        return AnalysisResult(wave, g.bpm, g.firstBeat, g.conf, k.key, k.keyConf, phrases)
    }

    // ---- waveform: 300 points per second, peak and RMS (the shape) and three band RMS (the colour) ----
    fun waveform(x: FloatArray, fs: Double): Waveform {
        val n = x.size
        val WPS = 300.0
        val hop = fs / WPS
        val frames = jsCeil(n / hop).toInt()
        val pk = FloatArray(frames); val rm = FloatArray(frames); val lo = FloatArray(frames); val mi = FloatArray(frames); val hi = FloatArray(frames)
        fun coef(lp: Boolean, f0: Double): DoubleArray {
            val w = 2 * Math.PI * f0 / fs
            val c = cos(w)
            val al = sin(w) / (2 * 0.7071)
            val a0 = 1 + al
            val b = if (lp) doubleArrayOf((1 - c) / 2, 1 - c, (1 - c) / 2) else doubleArrayOf((1 + c) / 2, -(1 + c), (1 + c) / 2)
            return doubleArrayOf(b[0] / a0, b[1] / a0, b[2] / a0, -2 * c / a0, (1 - al) / a0)
        }
        val L = coef(true, 200.0)
        val H = coef(false, 2500.0)
        var l1a = 0.0; var l1b = 0.0; var l2a = 0.0; var l2b = 0.0; var h1a = 0.0; var h1b = 0.0; var h2a = 0.0; var h2b = 0.0
        var f = 0
        var next = hop
        var sP = 0.0; var sR = 0.0; var sL = 0.0; var sM = 0.0; var sH = 0.0; var cnt = 0.0
        for (i in 0 until n) {
            val s = x[i].toDouble()
            var y = L[0] * s + l1a; l1a = L[1] * s - L[3] * y + l1b; l1b = L[2] * s - L[4] * y
            val low = L[0] * y + l2a; l2a = L[1] * y - L[3] * low + l2b; l2b = L[2] * y - L[4] * low
            y = H[0] * s + h1a; h1a = H[1] * s - H[3] * y + h1b; h1b = H[2] * s - H[4] * y
            val high = H[0] * y + h2a; h2a = H[1] * y - H[3] * high + h2b; h2b = H[2] * y - H[4] * high
            val mid = s - low - high
            val a = if (s < 0) -s else s
            if (a > sP) sP = a
            sR += s * s; sL += low * low; sM += mid * mid; sH += high * high; cnt += 1
            if ((i + 1).toDouble() >= next || i == n - 1) {
                if (f < frames) {
                    pk[f] = sP.toFloat(); rm[f] = sqrt(sR / cnt).toFloat(); lo[f] = sqrt(sL / cnt).toFloat()
                    mi[f] = sqrt(sM / cnt).toFloat(); hi[f] = sqrt(sH / cnt).toFloat()
                }
                f += 1; next += hop; sP = 0.0; sR = 0.0; sL = 0.0; sM = 0.0; sH = 0.0; cnt = 0.0
            }
        }
        val fr = min(f, frames)
        fun top(arr: FloatArray, q: Double): Double {
            val t = arr.copyOfRange(0, fr).also { it.sort() }
            if (t.isEmpty()) return 1e-9
            val v = t[min(t.size - 1, jsFloor(t.size * q).toInt())].toDouble()
            return if (v == 0.0) 1e-9 else v
        }
        fun bytes(arr: FloatArray, ref: Double, gamma: Double): ByteArray = ByteArray(fr) { i ->
            val v = min(255.0, jsRound(255 * (arr[i] / ref).pow(gamma)))
            if (v.isNaN() || v < 0) 0 else v.toInt().toByte()
        }
        val pref = top(pk, 0.999)
        return Waveform(n / fs, WPS.toInt(), bytes(pk, pref, 1.0), bytes(rm, pref, 1.0),
            bytes(lo, top(lo, 0.995), 0.9), bytes(mi, top(mi, 0.995), 0.9), bytes(hi, top(hi, 0.995), 0.9))
    }

    // ---- phrases ----
    private class BarF(val e: Double, val low: Double, val high: Double, val mid: Double, var kick: Double)
    private class Seg(val a: Int, var b: Int, val level: Double, val kick: Double, val low: Double, val rise: Double, var label: String)

    fun phraseAnalysis(x: FloatArray, fs: Double, bpm: Double, firstBeat: Double): List<Phrase> {
        val n = x.size
        val spb = 60 / bpm
        val barLen = 4 * spb
        val nBarsD = jsFloor((n / fs - firstBeat) / barLen)
        if (!(nBarsD >= 8)) return emptyList()
        val nBars = nBarsD.toInt()
        val hop = jsRound(fs / 200).toInt()
        val ER = fs / hop
        val m = n / hop
        val eAll = FloatArray(m); val eLow = FloatArray(m); val eHigh = FloatArray(m); val eMid = FloatArray(m)
        val aL = 1 - exp(-2 * Math.PI * 150 / fs)
        val aH = 1 - exp(-2 * Math.PI * 2500 / fs)
        var l1 = 0.0; var l2 = 0.0; var h1 = 0.0
        for (j in 0 until m) {
            var sa = 0.0; var sl = 0.0; var sh = 0.0; var sm = 0.0
            for (i in (j * hop) until (j * hop + hop)) {
                val s = x[i].toDouble()
                l1 += aL * (s - l1); l2 += aL * (l1 - l2)
                h1 += aH * (s - h1)
                val hiV = s - h1
                val md = h1 - l2
                sa += s * s; sl += l2 * l2; sh += hiV * hiV; sm += md * md
            }
            val hd = hop.toDouble()
            eAll[j] = sqrt(sa / hd).toFloat(); eLow[j] = sqrt(sl / hd).toFloat()
            eHigh[j] = sqrt(sh / hd).toFloat(); eMid[j] = sqrt(sm / hd).toFloat()
        }
        fun db(v: Double) = 20 * log10(v + 1e-6)
        val F = ArrayList<BarF>()
        for (b in 0 until nBars) {
            val t0 = firstBeat + b * barLen
            val j0 = jsFloor(t0 * ER).toInt()
            val j1 = jsFloor((t0 + barLen) * ER).toInt()
            var sa = 0.0; var sl = 0.0; var sh = 0.0; var sm = 0.0; var c = 0.0
            var j = j0
            while (j < j1 && j < m) {
                if (j >= 0) {
                    sa += eAll[j].toDouble().pow(2); sl += eLow[j].toDouble().pow(2); sh += eHigh[j].toDouble().pow(2); sm += eMid[j].toDouble().pow(2)
                }
                c += 1; j += 1
            }
            var rises = ArrayList<Double>()
            for (k in 0 until 16) {
                val jb = jsFloor((t0 + k * spb / 4) * ER).toInt()
                var before = Double.POSITIVE_INFINITY
                var after = 0.0
                for (q in -6 until 0) { val ix = jb + q; if (ix in 0 until m) { val v = eLow[ix].toDouble(); if (v < before) before = v } }
                for (q in 0 until 6) { val ix = jb + q; if (ix in 0 until m) { val v = eLow[ix].toDouble(); if (v > after) after = v } }
                rises.add(if (before != Double.POSITIVE_INFINITY) max(0.0, after - before) else 0.0)
            }
            rises = ArrayList(rises.sortedWith { p, q -> q.compareTo(p) })
            val cc = if (c == 0.0) 1.0 else c
            F.add(BarF(db(sqrt(sa / cc)), db(sqrt(sl / cc)), db(sqrt(sh / cc)), db(sqrt(sm / cc)), (rises[0] + rises[1]) / 2))
        }
        fun pct(arr: List<Double>, q: Double): Double { val t = arr.sorted(); return t[min(t.size - 1, jsFloor(q * t.size).toInt())] }
        val eHi = pct(F.map { it.e }, 0.85)
        val eLo = pct(F.map { it.e }, 0.15)
        val lowHi = pct(F.map { it.low }, 0.85)
        var kRef = pct(F.map { it.kick }, 0.9); if (kRef == 0.0) kRef = 1e-6
        for (bf in F) bf.kick /= kRef
        fun mean(a: Int, b: Int, key: (BarF) -> Double): Double {
            var s = 0.0; var c = 0.0
            var i = max(0, a)
            while (i < min(nBars, b)) { s += key(F[i]); c += 1; i += 1 }
            return if (c > 0) s / c else 0.0
        }
        val E: (BarF) -> Double = { it.e }; val LOW: (BarF) -> Double = { it.low }; val HIGH: (BarF) -> Double = { it.high }
        val MID: (BarF) -> Double = { it.mid }; val KICK: (BarF) -> Double = { it.kick }
        fun kickOn(v: Double) = min(1.0, max(0.0, (v - 0.2) / 0.3))
        val nov = ArrayList<Pair<Int, Double>>()
        var bb = 4
        while (bb < nBars - 2) {
            val w = 4; val b = bb
            val d = abs(mean(b, b + w, E) - mean(b - w, b, E)) / 4 +
                abs(mean(b, b + w, LOW) - mean(b - w, b, LOW)) / 5 +
                abs(mean(b, b + w, HIGH) - mean(b - w, b, HIGH)) / 6 +
                abs(mean(b, b + w, MID) - mean(b - w, b, MID)) / 5 +
                1.5 * abs(kickOn(mean(b, b + w, KICK)) - kickOn(mean(b - w, b, KICK)))
            nov.add(b to d); bb += 4
        }
        var cuts = arrayListOf(0)
        val dMed = if (nov.isEmpty()) 0.0 else pct(nov.map { it.second }, 0.5)
        val thr = max(0.45, 3 * dMed)
        val cand = nov.withIndex().filter { (i, v) ->
            v.second > thr && (i == 0 || v.second >= nov[i - 1].second) && (i == nov.size - 1 || v.second >= nov[i + 1].second)
        }.map { it.value }.sortedWith { p, q -> q.second.compareTo(p.second) }
        for (c in cand) if (cuts.all { x -> abs(x - c.first) >= 8 || (c.second > 4 * thr && abs(x - c.first) >= 4) }) cuts.add(c.first)
        cuts = ArrayList(cuts.sorted()); cuts.add(nBars)
        val segs = ArrayList<Seg>()
        for (i in 0 until cuts.size - 1) {
            val a = cuts[i]; val b = cuts[i + 1]
            val e = mean(a, b, E); val kick = kickOn(mean(a, b, KICK)); val low = mean(a, b, LOW)
            val level = (e - eLo) / max(3.0, eHi - eLo)
            val rise = if (b - a >= 4) (mean(b - 2, b, E) - mean(a, a + 2, E)) + (mean(b - 2, b, HIGH) - mean(a, a + 2, HIGH)) * 0.5 else 0.0
            segs.add(Seg(a, b, level, kick, low, rise, ""))
        }
        for (s in segs) {
            val full = s.kick > 0.5 && s.low > lowHi - 4
            s.label = if (full && s.level > 0.78) "Drop" else if (s.kick > 0.5) "Groove" else "Breakdown"
        }
        var i = 0
        while (i + 1 < segs.size) {
            val s = segs[i]
            if (segs[i + 1].label != "Drop" || s.label == "Drop" || s.b - s.a < 16) { i += 1; continue }
            val c = s.b - 8
            val ramp = (mean(c, s.b, E) - mean(s.a, c, E)) + 0.5 * (mean(c, s.b, HIGH) - mean(s.a, c, HIGH))
            if (ramp > 3) {
                segs.add(i + 1, Seg(c, s.b, s.level, s.kick, s.low, ramp, "Build"))
                s.b = c; i += 1
            }
            i += 1
        }
        for (k in segs.indices) {
            val s = segs[k]
            if (k + 1 < segs.size) {
                val nx = segs[k + 1]
                if (s.label != "Drop" && nx.label == "Drop" && (s.rise > 3 || (s.kick < 0.5 && s.b - s.a <= 8)) && s.b - s.a <= 16) s.label = "Build"
            }
        }
        if (segs.size > 1 && (segs[0].label != "Drop" || segs[0].level < 0.95)) segs[0].label = "Intro"
        val li = segs.size - 1
        if (segs.size > 2 && segs[li].label != "Drop" && segs[li].level < 0.8 && segs[li].b - segs[li].a <= 32) segs[li].label = "Outro"
        data class M(val a: Int, var b: Int, val label: String)
        val merged = ArrayList<M>()
        for (s in segs) { val p = merged.lastOrNull(); if (p != null && p.label == s.label) p.b = s.b else merged.add(M(s.a, s.b, s.label)) }
        val out = ArrayList<Phrase>()
        for (s in merged) {
            var a = s.a
            while (s.b - a > 32) { out.add(Phrase(firstBeat + a * barLen, 16, s.label)); a += 16 }
            out.add(Phrase(firstBeat + a * barLen, s.b - a, s.label))
        }
        return out
    }

    // ---- FFT (radix 2, tables per size) ----
    internal class FFTTables(n: Int) {
        val rev = IntArray(n)
        val cosT = DoubleArray(n / 2) { cos(-2 * Math.PI * it / n) }
        val sinT = DoubleArray(n / 2) { sin(-2 * Math.PI * it / n) }
        init {
            var j = 0
            for (i in 0 until n) { rev[i] = j; var bit = n shr 1; while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }; j = j xor bit }
        }
    }

    internal fun fft(re: DoubleArray, im: DoubleArray, t: FFTTables) {
        val n = re.size
        for (i in 0 until n) { val j = t.rev[i]; if (i < j) { var x = re[i]; re[i] = re[j]; re[j] = x; x = im[i]; im[i] = im[j]; im[j] = x } }
        var len = 2
        while (len <= n) {
            val h = len shr 1
            val step = n / len
            var i = 0
            while (i < n) {
                var w = 0
                for (k in 0 until h) {
                    val a = i + k; val b = a + h; val cr = t.cosT[w]; val ci = t.sinT[w]
                    val tr = re[b] * cr - im[b] * ci
                    val ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti
                    w += step
                }
                i += len
            }
            len = len shl 1
        }
    }

    internal fun splitMags(re: DoubleArray, im: DoubleArray, k0: Int, k1: Int, ma: DoubleArray, mb: DoubleArray) {
        val n = re.size
        if (k1 < k0) return
        for (k in k0..k1) {
            val zr = re[k]; val zi = im[k]; val cr = re[n - k]; val ci = -im[n - k]
            val ar = (zr + cr) / 2; val ai = (zi + ci) / 2; val br = (zi - ci) / 2; val bi = (cr - zr) / 2
            ma[k] = sqrt(ar * ar + ai * ai); mb[k] = sqrt(br * br + bi * bi)
        }
    }

    // ---- beat grid ----
    private const val W_KS = 0.5
    private const val W_NOV = 20.0
    private const val W_START = 2.0
    private const val W_ENTRY = 0.0

    /** Swift's max (y >= x ? y : x, in order), which the JS port matched; differs from kotlin.math.max on NaN */
    private fun smax(vararg v: Double): Double { var m = v[0]; for (i in 1 until v.size) if (v[i] >= m) m = v[i]; return m }

    private class Fit(var b: Double, val score: Double, var phase: Double, var P: Double, var contrast: Double = 0.0, var total: Double = 0.0)
    private class Peak(val f: Double, val v: Double)

    fun beatGrid(x: FloatArray, fs: Double, range: Pair<Double, Double>): GridResult {
        val n = x.size
        val N = 512
        val hop = 64
        val FPS = fs / hop
        val frames = max(0, (n - N) / hop + 1)
        if (frames < FPS * 4) return GridResult(120.0, 0.0, 0.0)
        val win = DoubleArray(N) { 0.5 - 0.5 * cos(2 * Math.PI * it / N) }
        val binHz = fs / N
        fun bin(f: Double) = max(1, jsRound(f / binHz).toInt())
        val b0 = bin(30.0); val b1 = bin(150.0); val b2 = bin(2000.0); val b3 = min(N / 2 - 1, bin(5000.0))
        val fLow = FloatArray(frames); val fMid = FloatArray(frames); val fHigh = FloatArray(frames); val rms = FloatArray(frames)
        val NB = 16
        val bandOf = IntArray(N / 2) { -1 }
        for (k in b0 until b2) bandOf[k] = min(NB - 1, jsFloor(NB * ln(k.toDouble() / b0) / ln(b2.toDouble() / b0)).toInt())
        val spec = FloatArray(frames * NB)
        val re = DoubleArray(N); val im = DoubleArray(N); val ma = DoubleArray(N / 2); val mb = DoubleArray(N / 2)
        var prev = FloatArray(N / 2)
        var cur = FloatArray(N / 2)
        val tables = FFTTables(N)
        fun frameOut(t: Int, mag: DoubleArray) {
            var lo = 0.0; var mi = 0.0; var hi = 0.0
            for (k in b0..b3) {
                val Lg = ln(1 + 100 * mag[k])
                cur[k] = Lg.toFloat()
                // the flux and the spectrum use L as a double (cur[k] is a Float32Array slot in the JS)
                val dd = Lg - prev[k]
                if (dd > 0) { if (k < b1) lo += dd else if (k < b2) mi += dd else hi += dd }
                val bb = bandOf[k]
                if (bb >= 0) spec[t * NB + bb] = (spec[t * NB + bb] + Lg).toFloat()
            }
            fLow[t] = (lo / (b1 - b0)).toFloat(); fMid[t] = (mi / (b2 - b1)).toFloat(); fHigh[t] = (hi / (b3 - b2 + 1)).toFloat()
            val tmp = prev; prev = cur; cur = tmp
        }
        var t = 0
        while (t < frames) {
            val sa = t * hop; val sb = sa + hop; val two = t + 1 < frames
            var ea = 0.0; var eb = 0.0
            if (two) { for (i in 0 until N) { val v = x[sa + i].toDouble(); val w = x[sb + i].toDouble(); re[i] = v * win[i]; im[i] = w * win[i]; ea += v * v; eb += w * w } }
            else { for (i in 0 until N) { val v = x[sa + i].toDouble(); re[i] = v * win[i]; im[i] = 0.0; ea += v * v } }
            rms[t] = sqrt(ea / N).toFloat()
            if (two) rms[t + 1] = sqrt(eb / N).toFloat()
            fft(re, im, tables)
            splitMags(re, im, b0, b3, ma, mb)
            frameOut(t, ma)
            if (two) frameOut(t + 1, mb)
            t += 2
        }
        fLow[0] = 0f; fMid[0] = 0f; fHigh[0] = 0f
        val W = jsRound(0.15 * FPS).toInt()
        fun clean(a: FloatArray): FloatArray {
            val out = FloatArray(frames)
            var s = 0.0
            for (tt in 0 until min(frames, W)) s += a[tt]
            var tot = 0.0
            for (tt in 0 until frames) {
                val hiI = tt + W; val loI = tt - W - 1
                if (hiI < frames) s += a[hiI]
                if (loI >= 0) s -= a[loI]
                val cnt = min(frames - 1, hiI) - max(0, loI + 1) + 1
                val v = a[tt] - s / cnt
                out[tt] = if (v > 0) v.toFloat() else 0f; tot += out[tt]
            }
            var m = tot / frames; if (m == 0.0 || m.isNaN()) m = 1.0
            for (tt in 0 until frames) out[tt] = (out[tt] / m).toFloat()
            return out
        }
        val oL = clean(fLow); val oM = clean(fMid); val oH = clean(fHigh)
        val odf = FloatArray(frames); val beatOdf = FloatArray(frames)
        for (tt in 0 until frames) {
            odf[tt] = (oL[tt].toDouble() + oM[tt].toDouble() + 0.6 * oH[tt]).toFloat()
            beatOdf[tt] = (oL[tt].toDouble() + 0.8 * oM[tt] + 0.15 * oH[tt]).toFloat()
        }
        // ---- tempo candidates from the autocorrelation
        var mean = 0.0
        for (tt in 0 until frames) mean += odf[tt]
        mean /= frames
        val z = FloatArray(frames) { (odf[it] - mean).toFloat() }
        val maxLag = min(frames - 1, jsCeil(FPS * 60 / 55 * 4).toInt() + 2)
        val ac = FloatArray(maxLag + 1)
        for (lag in 1..maxLag) {
            var s = 0.0
            for (i in lag until frames) s += z[i].toDouble() * z[i - lag]
            ac[lag] = (s / (frames - lag)).toFloat()
        }
        fun acAt(Lg: Double): Double {
            val i = jsFloor(Lg).toInt()
            val f = Lg - i
            if (i < 1 || i + 2 > maxLag) return 0.0
            val a = ac[i] + (ac[i + 1].toDouble() - ac[i]) * f
            return smax(a, ac[i - 1] * 0.9, ac[i + 2] * 0.9)
        }
        fun acScore(b: Double): Double { val P = FPS * 60 / b; return acAt(P) + acAt(2 * P) + acAt(4 * P) }
        val tempos = ArrayList<Pair<Double, Double>>()
        var bt = 60.0
        while (bt <= 200) { tempos.add(bt to acScore(bt)); bt += 0.1 }
        var peaks = ArrayList<Pair<Double, Double>>()
        for (i in 1 until tempos.size - 1) if (tempos[i].second >= tempos[i - 1].second && tempos[i].second > tempos[i + 1].second) peaks.add(tempos[i])
        peaks = ArrayList(peaks.sortedWith { p, q -> q.second.compareTo(p.second) })
        fun fold(b0: Double): Double { var b = b0; while (b < range.first) b *= 2; while (b >= range.second) b /= 2; return b }
        val cands = ArrayList<Double>()
        fun addCand(b0: Double) { val b = fold(b0); if (cands.none { abs(it / b - 1) < 0.004 }) cands.add(b) }
        for (p in peaks.take(5)) addCand(p.first)
        for (p in peaks.take(2)) for (r in doubleArrayOf(2.0 / 3, 3.0 / 2, 3.0 / 4, 4.0 / 3)) addCand(p.first * r)
        // ---- grid quality: fold onsets into a beat-phase histogram
        val HB = 64
        val hist = DoubleArray(HB)
        fun fit(b: Double): Fit {
            val P = FPS * 60 / b
            for (k in 0 until HB) hist[k] = 0.0
            for (tt in 0 until frames) {
                val v = beatOdf[tt].toDouble()
                if (v <= 0) continue
                val ph = (tt / P) % 1.0 * HB
                val i0 = jsFloor(ph).toInt()
                val f = ph - i0
                hist[i0 % HB] += v * (1 - f); hist[(i0 + 1) % HB] += v * f
            }
            var mx = -1.0; var mi = 0; var tot = 0.0
            for (k in 0 until HB) {
                val s = hist[k] + 0.5 * (hist[(k + 1) % HB] + hist[(k + HB - 1) % HB])
                tot += hist[k]
                if (s > mx) { mx = s; mi = k }
            }
            var den = 2 * tot / HB; if (den == 0.0 || den.isNaN()) den = 1.0
            return Fit(b, mx / den, (mi.toDouble() / HB) * P, P)
        }
        fun bestNear(b: Double, span: Double, step: Double): Fit {
            var best = fit(b)
            var bb = b
            var c = b - span
            while (c <= b + span + 1e-9) { val f = fit(c); if (f.score > best.score) { best = f; bb = c }; c += step }
            best.b = bb
            return best
        }
        var odfMean = 0.0
        for (tt in 0 until frames) odfMean += beatOdf[tt]
        odfMean /= frames; if (odfMean == 0.0 || odfMean.isNaN()) odfMean = 1.0
        fun at(arr: FloatArray, i: Int): Double? = if (i >= 0 && i < arr.size) arr[i].toDouble() else null
        fun contrast(P: Double, ph: Double): Double {
            var s = 0.0; var c = 0.0
            var f = ph
            while (f < (frames - 3).toDouble()) {
                val i = jsRound(f).toInt()
                s += smax(at(beatOdf, i - 2) ?: 0.0, at(beatOdf, i - 1) ?: 0.0, at(beatOdf, i) ?: Double.NaN, at(beatOdf, i + 1) ?: Double.NaN, at(beatOdf, i + 2) ?: Double.NaN)
                c += 1; f += P
            }
            return if (c > 0) s / c / odfMean else 0.0
        }
        val acMax = max(1e-9, if (peaks.isEmpty()) 1.0 else peaks[0].second)
        fun peakNear(arr: FloatArray, f: Double, w: Double): Peak? {
            val lo = max(1, jsFloor(f - w).toInt())
            val hi = min(frames - 2, jsCeil(f + w).toInt())
            var bi = -1; var bv = 0.0
            if (lo <= hi) for (i in lo..hi) if (arr[i] > bv) { bv = arr[i].toDouble(); bi = i }
            if (bi < 0) return null
            val a = arr[bi - 1].toDouble(); val c = arr[bi + 1].toDouble(); val d = a - 2 * bv + c
            return Peak(bi + (if (d < 0) 0.5 * (a - c) / d else 0.0), bv)
        }
        var P = 0.0
        var a0 = 0.0
        val sortedOdf = beatOdf.filter { it > 0 }.sorted()
        val thr = if (sortedOdf.isEmpty()) 0.0 else sortedOdf[jsFloor(sortedOdf.size * 0.6).toInt()].toDouble()
        fun regress(winFrac: Double): Boolean {
            val k0 = jsCeil(-a0 / P).toInt()
            val k1 = jsFloor(((frames - 1) - a0) / P).toInt()
            val ks = ArrayList<Double>(); val fs_ = ArrayList<Double>(); val ws = ArrayList<Double>()
            if (k0 <= k1) for (k in k0..k1) {
                val p = peakNear(beatOdf, a0 + k * P, P * winFrac) ?: continue
                if (p.v < thr) continue
                ks.add(k.toDouble()); fs_.add(p.f); ws.add(min(p.v, 4 * thr + 1e-9))
            }
            if (ks.size < 16) return false
            var keep = BooleanArray(ks.size) { true }
            repeat(3) {
                var sw = 0.0; var sk = 0.0; var sf = 0.0; var skk = 0.0; var skf = 0.0
                for (i in ks.indices) if (keep[i]) { val w = ws[i]; sw += w; sk += w * ks[i]; sf += w * fs_[i]; skk += w * ks[i] * ks[i]; skf += w * ks[i] * fs_[i] }
                val den = sw * skk - sk * sk
                if (den <= 0) return false
                val slope = (sw * skf - sk * sf) / den
                val icpt = (sf - slope * sk) / sw
                val res = DoubleArray(ks.size) { abs(fs_[it] - (icpt + slope * ks[it])) }
                val sr = res.indices.filter { keep[it] }.map { res[it] }.sorted()
                // (JS: an empty list gives NaN, which keeps nothing)
                keep = if (sr.isEmpty()) BooleanArray(ks.size) else { val cut = max(1.5, 3 * sr[sr.size / 2]); BooleanArray(ks.size) { res[it] <= cut } }
                P = slope; a0 = icpt
            }
            return true
        }
        var pick: Fit? = null
        for (c in cands) {
            val r = bestNear(c, c * 0.004, c * 0.0005)
            val prior = max(0.0, acScore(r.b)) / acMax
            P = r.P; a0 = r.phase
            if (regress(0.12)) regress(0.06)
            if (abs(P / r.P - 1) > 0.01) { P = r.P; a0 = r.phase }
            r.P = P; r.phase = a0; r.b = 60 * FPS / P
            r.contrast = contrast(r.P, ((r.phase % P) + P) % P)
            r.total = r.contrast * (0.6 + 0.4 * prior)
            if (pick == null || r.total > pick.total) pick = r
        }
        val pk = pick ?: return GridResult(120.0, 0.0, 0.0)
        P = pk.P; a0 = pk.phase
        // ---- on the beat, or between the beats?
        fun sumAt(arr: FloatArray, off: Double): Double {
            var s = 0.0
            var k = jsCeil(-(a0 + off) / P).toInt()
            while (a0 + off + k * P < (frames - 2).toDouble()) { peakNear(arr, a0 + off + k * P, 2.0)?.let { s += it.v }; k += 1 }
            return s
        }
        val lm = FloatArray(frames) { max(0.0, oL[it].toDouble() + oM[it] - 0.5 * oH[it]).toFloat() }
        if (sumAt(lm, P / 2) > 1.1 * sumAt(lm, 0.0)) { a0 += P / 2; regress(0.06) }
        // ---- round to a whole (or half) BPM only when it can't cause audible drift
        val nBeats = frames / P
        var bpm = 60 * FPS / P
        for (q in doubleArrayOf(1.0, 2.0, 100.0)) {
            val r = jsRound(bpm * q) / q
            val Pr = 60 * FPS / r
            val driftMs = abs(Pr - P) * nBeats / FPS * 1000
            if (driftMs < (if (q == 100.0) 2 else 5)) { bpm = r; break }
        }
        P = 60 * FPS / bpm
        run {
            var s = 0.0; var w = 0.0
            var k = jsCeil(-a0 / P).toInt()
            while (a0 + k * P < (frames - 2).toDouble()) {
                val p = peakNear(beatOdf, a0 + k * P, P * 0.05)
                if (p != null && p.v >= thr) { s += (p.f - (a0 + k * P)) * p.v; w += p.v }
                k += 1
            }
            if (w != 0.0) a0 += s / w
        }
        fun beatTime(k: Int): Double = (a0 + k * P) / FPS + 0.75 * N / fs
        // ---- downbeat vote
        val kFirst = jsCeil(-a0 / P).toInt()
        val kLast = jsFloor(((frames - 1) - a0) / P).toInt() - 1
        val nb = kLast - kFirst + 1
        val vote = DoubleArray(4)
        fun mod4(v: Int) = ((v % 4) + 4) % 4
        if (nb >= 16) {
            val fKick = FloatArray(nb); val fSnare = FloatArray(nb); val fChange = FloatArray(nb); val fEntry = FloatArray(nb); val loud = FloatArray(nb)
            val avgSpec = FloatArray(nb * NB)
            for (j in 0 until nb) {
                val k = kFirst + j
                val f0 = a0 + k * P
                val pkk = peakNear(oL, f0, 3.0); val ps = peakNear(oM, f0, 3.0)
                fKick[j] = (pkk?.v ?: 0.0).toFloat(); fSnare[j] = (ps?.v ?: 0.0).toFloat()
                val s = max(0, jsRound(f0).toInt()); val e = min(frames, jsRound(f0 + P).toInt())
                var r = 0.0
                if (s < e) for (tt in s until e) {
                    r += rms[tt]
                    for (q in 0 until NB) avgSpec[j * NB + q] = (avgSpec[j * NB + q].toDouble() + spec[tt * NB + q]).toFloat()
                }
                val c = max(1, e - s).toDouble()
                loud[j] = (r / c).toFloat()
                for (q in 0 until NB) avgSpec[j * NB + q] = (avgSpec[j * NB + q] / c).toFloat()
            }
            if (nb > 1) for (j in 1 until nb) {
                var d = 0.0
                for (q in 0 until NB) d += abs(avgSpec[j * NB + q].toDouble() - avgSpec[(j - 1) * NB + q])
                fChange[j] = d.toFloat()
            }
            if (nb > 8) for (j in 4 until nb - 4) {
                var a = 0.0; var b = 0.0
                for (q in 0 until 4) { a += loud[j + q]; b += loud[j - 4 + q] }
                val r = ln((a + 1e-6) / (b + 1e-6))
                fEntry[j] = (if (r > 0.4) r else 0.0).toFloat()
            }
            fun zs(v: FloatArray): FloatArray {
                var m = 0.0; var s = 0.0
                for (a in v) m += a
                m /= v.size
                for (a in v) s += (a - m).pow(2)
                s = sqrt(s / v.size); if (s == 0.0 || s.isNaN()) s = 1.0
                return FloatArray(v.size) { ((v[it] - m) / s).toFloat() }
            }
            val zK = zs(fKick); val zS = zs(fSnare)
            zs(fChange)
            val nov = DoubleArray(4)
            for (r in 0 until 4) {
                val j0 = mod4(r - kFirst)
                var prevBar: FloatArray? = null
                var cnt = 0.0
                var j = j0
                while (j + 4 <= nb) {
                    val bar = FloatArray(NB)
                    for (q in 0 until 4) for (u in 0 until NB) bar[u] = (bar[u].toDouble() + avgSpec[(j + q) * NB + u].toDouble() / 4).toFloat()
                    prevBar?.let { pb -> var d = 0.0; for (u in 0 until NB) d += abs(bar[u].toDouble() - pb[u]); nov[r] += d; cnt += 1 }
                    prevBar = bar; j += 4
                }
                nov[r] /= if (cnt == 0.0) 1.0 else cnt
            }
            val ks = DoubleArray(4); val ksn = DoubleArray(4)
            for (j in 0 until nb) { val r = mod4(kFirst + j); ks[r] += zK[j].toDouble() - zS[j]; ksn[r] += 1 }
            for (r in 0 until 4) ks[r] /= if (ksn[r] == 0.0) 1.0 else ksn[r]
            val lsorted = loud.sorted()
            val lmed = lsorted[nb / 2].toDouble()
            var jStart = 0
            while (jStart < nb - 1 && loud[jStart] < 0.25 * lmed) jStart += 1
            var novMean = (nov[0] + nov[1] + nov[2] + nov[3]) / 4; if (novMean == 0.0 || novMean.isNaN()) novMean = 1.0
            for (r in 0 until 4) vote[r] = W_KS * ks[r] + W_NOV * (nov[r] / novMean - 1)
            vote[mod4(kFirst + jStart)] += W_START
            for (j in 0 until nb) vote[mod4(kFirst + j)] += W_ENTRY * fEntry[j]
        }
        var best = 0
        for (r in 1 until 4) if (vote[r] > vote[best]) best = r
        var k = best
        while (beatTime(k - 4) >= 0) k -= 4
        while (beatTime(k) < 0) k += 4
        return GridResult(bpm, beatTime(k), pk.contrast)
    }

    // ---- musical key ----
    private val tpn = arrayOf(
        doubleArrayOf(5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0),
        doubleArrayOf(5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 4.0, 1.5),
    )

    fun detectKey(x: FloatArray, fs: Double): KeyResult {
        val prom = 3.0; val powE = 2.0; val harm = 5; val hdecay = 0.8; val thrF = 0.02; val fmax = 2100.0; val split = 52.0; val bw = 0.5
        val N = 8192
        val n = x.size
        val hop = max(N / 2, (n - N) / 360)
        val win = DoubleArray(N) { 0.5 - 0.5 * cos(2 * Math.PI * it / N) }
        val re = DoubleArray(N); val im = DoubleArray(N); val magA = DoubleArray(N / 2); val magB = DoubleArray(N / 2)
        val kLo = jsCeil(50.0 * N / fs).toInt()
        val kHi = min(N / 2 - 2, jsFloor(fmax * N / fs).toInt())
        val pm = ArrayList<Double>(); val pw = ArrayList<Double>()
        val R = 24
        val kM0 = max(1, kLo - R - 1)
        val kM1 = min(N / 2 - 1, kHi + R + 1)
        val starts = ArrayList<Int>()
        var s0 = 0
        while (s0 + N <= n) { starts.add(s0); s0 += hop }
        val tables = FFTTables(N)
        fun frameOut(mag: DoubleArray) {
            var mx = 0.0
            for (k in (kLo - 1)..(kHi + 1)) if (mag[k] > mx) mx = mag[k]
            if (mx < 1e-4) return
            val thr = mx * thrF
            var run = 0.0
            for (k in (kLo - R)..(kLo + R)) run += if (k >= kM0) mag[k] else 0.0
            for (k in kLo..kHi) {
                if (k > kLo) { val a = k + R; val b0 = k - R - 1; run += (if (a <= kM1) mag[a] else 0.0) - (if (b0 >= kM0) mag[b0] else 0.0) }
                val b = mag[k]
                if (b < thr || b <= mag[k - 1] || b < mag[k + 1]) continue
                if (b < prom * run / (2 * R + 1)) continue
                val la = ln(mag[k - 1] + 1e-12); val lb = ln(b); val lc = ln(mag[k + 1] + 1e-12)
                val den = la - 2 * lb + lc
                val p = k + (if (den < 0) 0.5 * (la - lc) / den else 0.0)
                val f = p * fs / N
                pm.add(69 + 12 * log2(f / 440)); pw.add((b / mx).pow(powE))
            }
        }
        var q = 0
        while (q < starts.size) {
            val sa = starts[q]; val two = q + 1 < starts.size; val sb = if (two) starts[q + 1] else 0
            if (two) { for (i in 0 until N) { re[i] = x[sa + i] * win[i]; im[i] = x[sb + i] * win[i] } }
            else { for (i in 0 until N) { re[i] = x[sa + i] * win[i]; im[i] = 0.0 } }
            fft(re, im, tables)
            splitMags(re, im, kM0, kM1, magA, magB)
            frameOut(magA)
            if (two) frameOut(magB)
            q += 2
        }
        var cs = 0.0; var sn = 0.0
        for (i in pm.indices) { val a = 2 * Math.PI * pm[i]; cs += pw[i] * cos(a); sn += pw[i] * sin(a) }
        val tune = atan2(sn, cs) / (2 * Math.PI)
        val bass = DoubleArray(12); val high = DoubleArray(12)
        for (i in pm.indices) {
            val m = pm[i] - tune
            val r = jsRound(m)
            val dev = abs(m - r)
            if (dev > 0.4) continue
            val w = pw[i] * (1 - dev / 0.4 * 0.5)
            for (hh in 1..harm) {
                val mf = m - 12 * log2(hh.toDouble())
                val rr = jsRound(mf)
                if (abs(mf - rr) > 0.4) continue
                val ri = rr.toInt()
                val pc = ((ri % 12) + 12) % 12
                val ww = w * hdecay.pow((hh - 1).toDouble())
                if (rr < split) bass[pc] += ww else high[pc] += ww
            }
        }
        fun norm(v: DoubleArray): DoubleArray { var s = 0.0; for (a in v) s += a; val d = if (s == 0.0) 1.0 else s; return DoubleArray(v.size) { v[it] / d } }
        val nb = norm(bass); val nh = norm(high)
        val chroma = DoubleArray(12) { nh[it] + bw * nb[it] }
        fun corr(c: DoubleArray, p: DoubleArray, rot: Int): Double {
            var mc = 0.0; var mp = 0.0
            for (i in 0 until 12) { mc += c[i]; mp += p[i] }
            mc /= 12; mp /= 12
            var sxy = 0.0; var sxx = 0.0; var syy = 0.0
            for (i in 0 until 12) { val a = c[(i + rot) % 12] - mc; val b = p[i] - mp; sxy += a * b; sxx += a * a; syy += b * b }
            val d = sxx * syy
            return sxy / sqrt(if (d == 0.0 || d.isNaN()) 1.0 else d)
        }
        val scores = ArrayList<Double>()
        for (m in 0 until 2) for (t in 0 until 12) scores.add(corr(chroma, tpn[m], t))
        var best = 0
        for (k in 1 until 24) if (scores[k] > scores[best]) best = k
        val sorted = scores.sortedDescending()
        return KeyResult(best, sorted[0] - sorted[1])
    }
}
