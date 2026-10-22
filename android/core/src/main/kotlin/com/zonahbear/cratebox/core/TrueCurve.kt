package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.doubleOrNull
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

// TrueCurve mini: heat curves for a Puffco Peak Pro / Proxy. A port of ios/CrateboxKit TrueCurve.swift, which
// ports cratebox.html's TC section, itself a cut-down copy of zonahbear/truecurve web/index.html: same curve
// maths (monotone cubic or straight lines), predictive driver, heater-model learning, Lorax byte formats and
// safety rules. UI-free and Bluetooth-free so it can be tested on the JVM; the app does BluetoothGatt and the
// runner. Temperatures are °F, times are seconds. Keep names parallel with the Swift and web code.
object TrueCurve {
    /** targets are clamped to this range; a reading at or above [CUTOFF_F] stops the run */
    const val MIN_F = 350.0
    const val MAX_F = 590.0
    const val CUTOFF_F = 600.0
    /** curves run on profile slot 4 (index 3), backed up first and restored after */
    const val SLOT: Int = 3
    /** Proxy reports "ready" (10) for most of a heat cycle, not just "heating" (8) */
    val heating = setOf(7, 8, 10)
    fun cToF(c: Double) = c * 9 / 5 + 32
    fun fToC(f: Double) = (f - 32) * 5 / 9
    internal fun clamp(v: Double, lo: Double, hi: Double) = min(hi, max(lo, v))

    data class Point(val t: Double, val f: Double)
    /** the clipboard / saved form: {name: {points: [{t, f}], smooth}}, same as TrueCurve's tc_curves */
    data class CurveDef(val points: List<Point>, val smooth: Boolean)

    /** TrueCurve's presets, in menu order; Quartz Banger (starts at 520 and trails off to 450) is the default */
    const val DEFAULT_NAME = "Quartz Banger"
    val presets: List<Pair<String, List<Pair<Double, Double>>>> = listOf(
        "Quartz Banger" to listOf(0.0 to 520.0, 10.0 to 508.0, 25.0 to 485.0, 45.0 to 462.0, 65.0 to 450.0),
        "Terp Ramp" to listOf(0.0 to 450.0, 20.0 to 480.0, 40.0 to 520.0, 55.0 to 550.0),
        "Hot Start, Cool Finish" to listOf(0.0 to 540.0, 15.0 to 520.0, 35.0 to 480.0, 55.0 to 460.0),
        "Wave" to listOf(0.0 to 470.0, 15.0 to 520.0, 30.0 to 480.0, 45.0 to 540.0, 60.0 to 505.0),
        "Slow Climb" to listOf(0.0 to 430.0, 50.0 to 510.0, 80.0 to 560.0),
        "Flat 500" to listOf(0.0 to 500.0, 45.0 to 500.0),
    )
    fun preset(name: String): CurveDef? =
        presets.firstOrNull { it.first == name }?.let { p -> CurveDef(p.second.map { Point(it.first, it.second) }, true) }

    // ---- curve maths ----

    /** monotone cubic (Fritsch–Butland: never overshoots between points) or straight lines */
    class Curve private constructor(
        private val xs: DoubleArray, private val ys: DoubleArray, private val hh: DoubleArray,
        private val d: DoubleArray, private val m: DoubleArray, val smooth: Boolean,
    ) {
        val end: Double = xs[xs.size - 1]

        companion object {
            /** null with fewer than two distinct times */
            fun of(points: List<Point>, smooth: Boolean): Curve? {
                val pts = ArrayList<Point>()
                for (p in points.filter { it.t.isFinite() && it.f.isFinite() }.sortedBy { it.t }) if (pts.lastOrNull()?.t != p.t) pts.add(p)
                if (pts.size < 2) return null
                val n = pts.size
                val xs = DoubleArray(n) { pts[it].t }
                val ys = DoubleArray(n) { pts[it].f }
                val hh = DoubleArray(n - 1)
                val d = DoubleArray(n - 1)
                val m = DoubleArray(n)
                for (i in 0 until n - 1) { hh[i] = xs[i + 1] - xs[i]; d[i] = (ys[i + 1] - ys[i]) / hh[i] }
                for (i in 1 until n - 1) if (d[i - 1] * d[i] > 0) {
                    val w1 = 2 * hh[i] + hh[i - 1]
                    val w2 = hh[i] + 2 * hh[i - 1]
                    m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
                }
                return Curve(xs, ys, hh, d, m, smooth)
            }
        }

        private fun seg(t: Double): Int { var i = 0; while (i < xs.size - 2 && t > xs[i + 1]) i++; return i }

        fun at(t0: Double): Double {
            val t = clamp(t0, 0.0, end)
            val i = seg(t)
            val s = (t - xs[i]) / hh[i]
            if (!smooth) return ys[i] + s * (ys[i + 1] - ys[i])
            val s2 = s * s
            val s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * ys[i] + (s3 - 2 * s2 + s) * hh[i] * m[i] + (-2 * s3 + 3 * s2) * ys[i + 1] + (s3 - s2) * hh[i] * m[i + 1]
        }

        fun slope(t: Double): Double {
            if (t <= 0 || t >= end) return 0.0
            val i = seg(t)
            val s = (t - xs[i]) / hh[i]
            if (!smooth) return d[i]
            val s2 = s * s
            return ((6 * s2 - 6 * s) * ys[i] + (-6 * s2 + 6 * s) * ys[i + 1]) / hh[i] + (3 * s2 - 4 * s + 1) * m[i] + (3 * s2 - 2 * s) * m[i + 1]
        }
    }

    // ---- heater model, driver, learner ----

    /** bowl temp follows the heater target as a first-order lag capped by heating power; it can only cool passively */
    data class HeaterModel(
        var tau: Double = 4.0, var heatMax: Double = 12.0, var coolK: Double = 0.015, var dead: Double = 0.6, var runs: Int = 0,
    )

    fun plantStep(y: Double, u: Double, dt: Double, p: HeaterModel, extraCool: Double = 0.0): Double {
        val rate = if (u > y) min((u - y) / p.tau, p.heatMax) else max((u - y) / p.tau, -p.coolK * (y - 70))
        return y + (rate - extraCool) * dt
    }

    /** look ahead by dead time + BLE latency and invert the lag; live correction only trims (big asks can make
     *  the firmware abort the session) */
    class Driver(private val c: Curve, private val m: HeaterModel) {
        private var integ = 0.0

        fun command(t: Double, y: Double?, dt: Double): Double {
            val tl = t + m.dead + 0.25
            val r = c.at(t)
            val ff = c.at(tl) + m.tau * (if (tl < c.end) c.slope(tl) else 0.0)
            var corr = 0.0
            var i = integ
            var unsat = true
            if (y != null) {
                val e = r - y
                if (abs(e) < 30) i = clamp(i + 0.1 * e * dt, -12.0, 12.0)
                val raw = 0.6 * clamp(e, -30.0, 30.0) + i
                corr = clamp(raw, -15.0, 20.0); unsat = corr == raw
            }
            val u = ff + corr
            val uc = clamp(u, max(MIN_F, r - 40), min(MAX_F, r + 30))
            if (unsat && abs(uc - u) < 0.01) integ = i
            return uc
        }
    }

    /** learns tau / max heat rate / cooling from a run, like TrueCurve (stored per device) */
    class Learner(model: HeaterModel) {
        val m: HeaterModel = model.copy()
        var n = 0; private set
        private data class S(val t: Double, val y: Double, val u: Double)
        private val s = ArrayDeque<S>()

        fun add(t: Double, y: Double?, u: Double) {
            if (y == null) return
            s.addLast(S(t, y, u))
            while (s.isNotEmpty() && t - s.first().t > 1.4) s.removeFirst()
            if (s.size < 4) return
            val k = s.size.toDouble()
            val mt = s.sumOf { it.t } / k
            val my = s.sumOf { it.y } / k
            var num = 0.0
            var den = 0.0
            for (v in s) { num += (v.t - mt) * (v.y - my); den += (v.t - mt) * (v.t - mt) }
            if (den < 0.2) return
            val dy = num / den
            val ta = t - m.dead - 0.2
            var uD: Double? = null
            for (v in s) if (v.t <= ta) uD = v.u
            val gap = (uD ?: s.first().u) - my
            if (gap > 10 && dy > 1) {
                if (gap / m.tau < 0.7 * m.heatMax) m.tau += 0.04 * (clamp(gap / dy, 1.5, 15.0) - m.tau)
                else m.heatMax += (if (dy > m.heatMax) 0.15 else 0.03) * (clamp(dy, 3.0, 40.0) - m.heatMax)
                n++
            } else if (gap < -10 && dy < -0.5 && my > 150 && -gap / m.tau > 1.3 * m.coolK * (my - 70)) {
                m.coolK += 0.05 * (clamp(-dy / (my - 70), 0.003, 0.06) - m.coolK); n++
            }
        }
    }

    /** the simulator's heater (the app's Simulator device and the tests): a "truth" model that differs from the
     *  driver's default, a dead time on live targets, and a device that ends its own cycle after the slot's time */
    class SimHeater {
        data class Slot(var temp: Double, var time: Double)
        var truth = HeaterModel(tau = 3.0, heatMax = 15.0, coolK = 0.011, dead = 0.45)
        var y = 74.0
        var u = 74.0
        var state = 5
        var slotIdx = 0
        val slots = MutableList(4) { Slot(485.0, 45.0) }
        var clock = 0.0; private set
        private val cmds = ArrayDeque<Pair<Double, Double>>()
        private var endAt = 0.0

        fun advance(dt: Double) {
            clock += dt
            while (cmds.isNotEmpty() && cmds.first().first <= clock) u = cmds.removeFirst().second
            val heating = state == 7 || state == 8
            y = plantStep(y, if (heating) u else 70.0, dt, truth)
            if (state == 7 && y >= u - 6) { state = 8; endAt = clock + slots[slotIdx].time }
            if (state == 8 && clock >= endAt) state = 5
        }
        fun start() { state = 7; u = slots[slotIdx].temp; cmds.clear() }
        fun stop() { state = 5 }
        fun setLiveTarget(f: Double) { cmds.addLast(clock + truth.dead to clamp(f, MIN_F, MAX_F)) }
    }

    /** TrueCurve's "Copy curves for Cratebox" JSON ({name: {points: [{t, f}], smooth}}); null if it isn't that.
     *  Points are clamped like the web app's paste (t 0–110 s, f 350–590°F), names cut to 24 characters. */
    fun parseCurves(text: String): Map<String, CurveDef>? {
        val obj = try { Json.parseToJsonElement(text.trim()) as? JsonObject } catch (_: Exception) { null } ?: return null
        fun num(v: Any?): Double? {
            val p = v as? JsonPrimitive ?: return null
            return if (p.isString) p.content.trim().toDoubleOrNull() else p.doubleOrNull
        }
        val out = LinkedHashMap<String, CurveDef>()
        for ((k, v) in obj) {
            val c = v as? JsonObject ?: continue
            val raw = c["points"] as? JsonArray ?: continue
            val pts = raw.mapNotNull { p ->
                val o = p as? JsonObject ?: return@mapNotNull null
                val t = num(o["t"]) ?: return@mapNotNull null
                val f = num(o["f"]) ?: return@mapNotNull null
                if (!t.isFinite() || !f.isFinite()) null else Point(clamp(t, 0.0, 110.0), clamp(f, MIN_F, MAX_F))
            }
            val smooth = (c["smooth"] as? JsonPrimitive)?.booleanOrNull != false
            if (pts.size >= 2) out[prefixCodePoints(k, 24)] = CurveDef(pts, smooth)
        }
        return out
    }

    /** the saved curves as the same JSON parseCurves reads (and TrueCurve's tc_curves) */
    fun encodeCurves(c: Map<String, CurveDef>): String = buildJsonObject {
        for ((k, v) in c) put(k, buildJsonObject {
            put("points", buildJsonArray { for (p in v.points) add(buildJsonObject { put("t", p.t); put("f", p.f) }) })
            put("smooth", v.smooth)
        })
    }.toString()

    /** a learned model as stored per device (the iOS app's Codable keys) */
    fun encodeModel(m: HeaterModel): String = buildJsonObject {
        put("tau", m.tau); put("heatMax", m.heatMax); put("coolK", m.coolK); put("dead", m.dead); put("runs", m.runs)
    }.toString()
    fun parseModel(text: String?): HeaterModel? {
        val o = try { text?.let { Json.parseToJsonElement(it) as? JsonObject } } catch (_: Exception) { null } ?: return null
        fun d(k: String) = (o[k] as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() }
        val m = HeaterModel(tau = d("tau") ?: return null, heatMax = d("heatMax") ?: return null, coolK = d("coolK") ?: return null,
                            dead = d("dead") ?: return null, runs = d("runs")?.toInt() ?: 0)
        return m
    }

    private fun prefixCodePoints(s: String, n: Int): String =
        if (s.codePointCount(0, s.length) <= n) s else s.substring(0, s.offsetByCodePoints(0, n))
}

/** The Puffco Lorax protocol's bytes, same as TrueCurve's PuffcoBle: frames are [seq lo, seq hi, op, payload],
 *  replies [seq lo, seq hi, status, data]. Ops: 0 seed, 1 unlock, 16 read, 17 write. Temperatures on the wire
 *  are °C, as float32 (Peak Pro) or int32 tenths (Proxy, "i10"). Bytes are Ints 0-255 in lists, as in Swift. */
object Lorax {
    const val SERVICE = "e276967f-ea8a-478a-a92e-d78f5dd15dd5"
    const val SERVICE_LEGACY = "06caf9c0-74d3-454f-9be9-e30cd999c17a"
    const val CMD = "60133d5c-5727-4f2c-9697-d842c5292a3c"
    const val REPLY = "8dc5ec05-8f7d-45ad-99db-3fbde65dbd9c"
    const val VERSION = "05434bca-cc7f-4ef6-bbb3-b1c520b9800c"
    private val key = intArrayOf(0x64, 0xc6, 0x45, 0x62, 0x56, 0xf2, 0x6f, 0x5b, 0x1c, 0xa1, 0x27, 0x37, 0xa5, 0xdd, 0x71, 0xfb)

    object Path {
        const val MODE = "/p/app/mc"
        const val STATE = "/p/app/stat/id"
        const val TEMP = "/p/app/htr/temp"
        const val TEMP_ALT = "/p/htr/temp"
        const val LIVE = "/p/app/thc/temp"
        const val SLOT = "/p/app/hcs"
        const val SOC = "/p/bat/soc"
        fun pTemp(s: Int) = "/u/app/hc/$s/temp"
        fun pTime(s: Int) = "/u/app/hc/$s/time"
    }
    enum class Fmt { F32, I10 }

    private fun utf8(s: String) = s.toByteArray(Charsets.UTF_8).map { it.toInt() and 0xff }

    fun frame(seq: Int, op: Int, payload: List<Int>): List<Int> = listOf(seq and 0xff, (seq shr 8) and 0xff, op) + payload
    fun readPayload(path: String, max: Int): List<Int> = listOf(0, 0, max and 0xff, (max shr 8) and 0xff) + utf8(path)
    fun writePayload(path: String, bytes: List<Int>): List<Int> = listOf(0, 0, 0) + utf8(path) + listOf(0) + bytes
    /** unlock token: the first 16 bytes of SHA-256(key + the 16-byte seed) */
    fun token(seed: List<Int>): List<Int> {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(ByteArray(key.size) { key[it].toByte() })
        md.update(ByteArray(min(16, seed.size)) { seed[it].toByte() })
        return md.digest().take(16).map { it.toInt() and 0xff }
    }

    private fun u32(b: List<Int>): Int = (b[0] and 0xff) or ((b[1] and 0xff) shl 8) or ((b[2] and 0xff) shl 16) or ((b[3] and 0xff) shl 24)
    private fun le(v: Int): List<Int> = listOf(v and 0xff, (v shr 8) and 0xff, (v shr 16) and 0xff, (v ushr 24) and 0xff)
    fun f32(b: List<Int>): Double = java.lang.Float.intBitsToFloat(u32(b)).toDouble()
    fun i32(b: List<Int>): Int = u32(b)
    fun f32Bytes(v: Double): List<Int> = le(java.lang.Float.floatToRawIntBits(v.toFloat()))

    /** a °C reading: float unless the device is known to be i10 or the float is implausible */
    fun decodeC(b: List<Int>?, fmt: Fmt?): Double? {
        if (b == null || b.size < 4) return null
        val f = f32(b)
        if (fmt != Fmt.I10 && f.isFinite() && f > -80 && f < 520 && !(f != 0.0 && abs(f) < 1e-3)) return f
        val i = i32(b)
        return if (abs(i) <= 6000) i / 10.0 else null
    }
    fun encodeC(c: Double, fmt: Fmt): List<Int> = if (fmt == Fmt.I10) le((c * 10).roundToLong().toInt()) else f32Bytes(c)
    /** what a profile temperature reads back as */
    fun decodeAs(b: List<Int>, fmt: Fmt): Double = if (fmt == Fmt.I10) i32(b) / 10.0 else f32(b)
    /** slot 0's profile temperature tells the format (a profile is 100–350 °C) */
    fun detectFormat(b: List<Int>?, isProxy: Boolean): Fmt {
        if (b != null && b.size >= 4) {
            val f = f32(b)
            val i = i32(b)
            if (f.isFinite() && f >= 100 && f <= 350) return Fmt.F32
            if (i in 1000..3600) return Fmt.I10
        }
        return if (isProxy) Fmt.I10 else Fmt.F32
    }
    /** the live target (/p/app/thc/temp) can be in a different format from the profiles */
    fun detectLiveFormat(b: List<Int>?): Fmt? {
        if (b == null || b.size < 4) return null
        val f = f32(b)
        val i = i32(b)
        if (f.isFinite() && f >= 150 && f <= 400) return Fmt.F32
        if (i in 1500..4000) return Fmt.I10
        return null
    }

    /** /p/bat/soc: float on Peak Pro, integer (sometimes tenths/hundredths of a percent) on Proxy */
    class SocDecoder {
        private var scale = 0
        fun decode(b: List<Int>?): Int? {
            if (b.isNullOrEmpty()) return null
            if (b.size >= 4) {
                val f = f32(b)
                if (f.isFinite() && f >= 1e-3 && f < 1) return (f * 100).roundToInt()
                if (f.isFinite() && f >= 1 && f <= 100) return f.roundToInt()
            }
            val i = if (b.size >= 4) i32(b) else if (b.size >= 2) (b[0] and 0xff) or ((b[1] and 0xff) shl 8) else b[0] and 0xff
            if (i < 0 || i > 10000) return null
            if (i > 1000) scale = 100 else if (i > 100 && scale != 100) scale = 10
            return (i.toDouble() / max(scale, 1)).roundToInt()
        }
    }
}
