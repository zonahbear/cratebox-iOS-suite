package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertTrue

/** Port of SyncSoakTests.swift: synced decks over minutes, the way the phone runs them: 48 kHz, big audio
 *  buffers, the screen's tick at its own pace and an audio clock estimated from the last buffer. */
class SyncSoakTest {
    private val SR = 48000.0
    private fun rnd(x: Double) = Math.rint(x)    // Swift .rounded() is half away from zero; only used on non-halves here

    private fun clicks(bpm: Double, secs: Double, first: Double = 0.0): PCMTrack {
        val n = (secs * SR).toInt(); val t = PCMTrack(n, SR); val spb = 60 / bpm
        for (i in 0 until n) {
            val s = i / SR - first
            val ph = if (s >= 0) s % spb else 1.0
            val v = if (ph < 0.004) (0.9 * sin(2 * Math.PI * 2000 * ph)).toFloat() else 0f
            t.left[i] = v; t.right[i] = v
        }
        return t
    }

    private fun soak(trueA: Double, gridA: Double, trueB: Double, gridB: Double, mt: Boolean, pitchA: Double, buffer: Int, secs: Double, appClock: Boolean, label: String): List<Double> {
        val e = Engine(SR); val c = Core(e)
        var wall = 0.0
        c.wallMs = { wall }
        // the app's clock: last buffer's audio time + host time since; buffers are rendered a little early
        var renderedAt = 0.0; var renderTime = 0.0; var host = 0.0
        c.clock = if (appClock) ({ renderTime + min(0.25, max(0.0, host - renderedAt)) }) else ({ e.time })
        val tA = clicks(trueA, secs + 30); val tB = clicks(trueB, secs + 30, 0.21)
        for ((k, x) in listOf(Triple(tA, gridA, 0.0), Triple(tB, gridB, 0.21)).withIndex()) {
            val info = TrackInfo("soak$k", "Soak $k")
            c.decks[k].beginLoad(info)
            c.decks[k].finishLoad(info, x.first, DeckAnalysis(x.second, x.third, 21, emptyList(), null, secs + 30), null)
            if (c.decks[k].mt != mt) c.decks[k].setMT(mt)
        }
        val outs = Array(2) { FloatArray(buffer) }
        val a = c.decks[0]; val b = c.decks[1]
        val worst = ArrayList<Double>(); var cur = 0.0
        val rng = Random(1)
        fun step(dt: Double) {
            // the screen ticks at 60 Hz; the audio thread renders whole buffers to stay ahead of real time
            val target = host + dt
            while (host < target) {
                host = min(target, host + 1.0 / 60)
                while (e.time < host + buffer / SR) {
                    e.render(outs, buffer)
                    renderTime = e.time; renderedAt = host + rng.nextDouble(0.0, 0.004)
                }
                wall = host * 1000
                c.tick()
            }
        }
        step(0.1)
        a.setPitch(pitchA); a.togglePlay(); step(1.0)
        b.seek(10.0); step(0.1)
        b.setSync(true); b.togglePlay()
        var t = 0.0
        while (t < secs) {
            step(0.25); t += 0.25
            // where the players really are, in each one's own (grid) beats
            val pa = e.decks[0].pos / SR; val pb = e.decks[1].pos / SR
            var err = (pb - 0.21) / (60 / gridB) - b.syncMult * pa / (60 / gridA)
            err -= rnd(err)
            val ms = err * 60 / (gridB * b.rate()) * 1000
            cur = max(cur, abs(ms))
            if ((t * 4).toInt() % 120 == 0) { worst.add(cur); cur = 0.0 }
        }
        // the soak means nothing unless deck 2 really played through it
        assertTrue(b.playing && e.decks[1].pos / SR > 10 + secs * 0.9, "deck 2 played")
        println("SYNC $label: worst offset per 30 s (ms) ${worst.joinToString(" ") { fmt("%.3f", it) }} · trim ${fmt("%.5f", b.syncTrim)} phaseErr ${fmt("%.4f", b.phaseErr ?: -1.0)}")
        return worst
    }

    @Test fun syncHoldsOverMinutes() {
        val w1 = soak(128.0, 128.0, 126.0, 126.0, true, 0.3, 1024, 180.0, true, "MT on, 1024 buffers, app clock")
        val w2 = soak(128.0, 128.0, 126.0, 126.0, false, 0.3, 1024, 180.0, true, "MT off, 1024 buffers, app clock")
        val w3 = soak(174.0, 174.0, 87.3, 87.3, true, -0.2, 512, 120.0, false, "halftime, MT on")
        soak(128.0, 128.0, 126.05, 126.0, true, 0.0, 1024, 180.0, true, "deck 2's grid 0.05 BPM off")
        assertTrue((w1.maxOrNull() ?: 99.0) < 8); assertTrue((w2.maxOrNull() ?: 99.0) < 8); assertTrue((w3.maxOrNull() ?: 99.0) < 8)
    }

    /** what you hear against where the player says it is: with MT on (time-stretched), the clicks in the
     *  output should stay a fixed distance from the reported position, not wander off */
    @Test fun heardMatchesPosition() {
        for (mt in listOf(true, false)) {
            val p = DeckPlayer(SR); val bpm = 125.0; val spb = 60 / bpm
            p.setTrack(clicks(bpm, 200.0))
            p.handle(DeckMessage.Load(mt, 1.5)); p.handle(DeckMessage.Rate(1.037)); p.handle(DeckMessage.Play(true))
            val n = 512; val l = FloatArray(n); val r = FloatArray(n)
            var outT = 0.0; var last = -1.0; val offs = ArrayList<Double>()
            repeat((150 * SR).toInt() / n) {
                val pos0 = p.pos
                p.render(l, r, n)
                for (j in 0 until n) if (abs(l[j]) > 0.3 && outT + j / SR - last > spb / 2) {
                    last = outT + j / SR
                    // the track time of the beat heard, and the player's position at that moment
                    val at = pos0 / SR + (p.pos - pos0) / SR * j / n
                    val beat = rnd(at / spb)
                    offs.add((at - beat * spb) * 1000)
                }
                outT += n / SR
            }
            val k = max(1, min(20, offs.size))
            val head = offs.take(20).sum() / k; val tail = offs.takeLast(20).sum() / k
            println("SYNC heard vs position, MT ${if (mt) "on" else "off"}: ${offs.size} clicks, offset at start ${fmt("%.2f", head)} ms, after 150 s ${fmt("%.2f", tail)} ms, spread ${fmt("%.2f", (offs.maxOrNull() ?: 0.0) - (offs.minOrNull() ?: 0.0))} ms")
            assertTrue(abs(tail - head) < 5, "what's heard stays with the reported position")
        }
    }

    /** a track whose tempo wanders (like a live drummer, or rekordbox's dynamic grids): synced on rekordbox's
     *  beat-by-beat grid it stays on the beat; on a single BPM it can't */
    @Test fun variableTempoFollowsTheBeats() {
        for (perBeat in listOf(true, false)) {
            val e = Engine(SR); val c = Core(e)
            var wall = 0.0
            c.wallMs = { wall }
            c.clock = { e.time }
            val secs = 150.0
            val a = clicks(126.0, secs + 30)
            // deck 2: beats whose spacing swings 0.4% around 126 BPM over about a minute
            val beats = ArrayList<Double>(); var t = 0.3
            while (t < secs + 25) { beats.add(t); t += 60.0 / 126 * (1 + 0.004 * sin(t / 9)) }
            val n = ((secs + 30) * SR).toInt(); val tb = PCMTrack(n, SR)
            for (bt in beats) { val s0 = (bt * SR).toInt(); for (k in 0 until (0.004 * SR).toInt()) if (s0 + k < n) { val v = (0.9 * sin(2 * Math.PI * 2000 * k / SR)).toFloat(); tb.left[s0 + k] = v; tb.right[s0 + k] = v } }
            val anB = DeckAnalysis(126.0, 0.3, 21, emptyList(), null, secs + 30).also { if (perBeat) it.beats = beats.toDoubleArray() }
            for ((k, x) in listOf(a to DeckAnalysis(126.0, 0.0, 21, emptyList(), null, secs + 30), tb to anB).withIndex()) {
                val info = TrackInfo("var$k$perBeat", "Var $k")
                c.decks[k].beginLoad(info); c.decks[k].finishLoad(info, x.first, x.second, null)
            }
            val outs = Array(2) { FloatArray(512) }
            fun run(s: Double) { repeat((s * SR / 512).toInt()) { e.render(outs, 512); wall += 512 / SR * 1000; c.tick() } }
            run(0.1); c.decks[0].togglePlay(); run(1.0)
            c.decks[1].seek(10.0); run(0.1); c.decks[1].setSync(true); c.decks[1].togglePlay()
            var worst = 0.0
            repeat((secs * 2).toInt()) {
                run(0.5)
                val pb = e.decks[1].pos / SR; val pa = e.decks[0].pos / SR
                var i = 0; while (i + 1 < beats.size && beats[i + 1] <= pb) i += 1
                val trueB = i + (pb - beats[i]) / (beats[min(i + 1, beats.size - 1)] - beats[i])
                var err = trueB - pa / (60.0 / 126)
                err -= rnd(err)
                worst = max(worst, abs(err) * 60 / 126 * 1000)
            }
            println("SYNC wandering tempo, ${if (perBeat) "beat-by-beat grid" else "one BPM"}: worst offset ${fmt("%.1f", worst)} ms over ${secs.toInt()} s")
            if (perBeat) assertTrue(worst < 8)
        }
    }
}
