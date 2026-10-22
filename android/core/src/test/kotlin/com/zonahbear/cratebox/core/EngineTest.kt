package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Port of EngineTests.swift: the mixer and engine, by measurement: tones through a deck, then what comes out where. */
class EngineTest {
    private val SR = 44100.0
    private fun tone(hz: Double, secs: Double = 2.0, amp: Float = 0.5f): PCMTrack {
        val n = (secs * SR).toInt()
        val t = PCMTrack(n, SR)
        for (i in 0 until n) { val v = amp * sin(2 * Math.PI * hz * i / SR).toFloat(); t.left[i] = v; t.right[i] = v }
        return t
    }
    /** RMS of each output channel over `secs` after `skip` seconds */
    private fun run(e: Engine, channels: Int = 2, skip: Double = 0.3, secs: Double = 0.5): List<Double> {
        val n = 512
        val outs = Array(channels) { FloatArray(n) }
        val sums = DoubleArray(channels)
        var cnt = 0
        for (b in 0 until ((skip + secs) * SR).toInt() / n) {
            e.render(outs, n)
            if (b * n >= skip * SR) { for (c in 0 until channels) for (j in 0 until n) sums[c] += outs[c][j].toDouble() * outs[c][j]; cnt += n }
        }
        return sums.map { sqrt(it / max(cnt, 1)) }
    }
    private fun engine(hz: Double, deck: Int = 0, m: (MixerState) -> Unit = {}): Engine {
        val e = Engine(SR)
        val ms = MixerState(); m(ms)
        e.post(listOf(EngineCommand.Track(deck, tone(hz)), EngineCommand.Deck(deck, DeckMessage.Load(false, null)),
            EngineCommand.Mixer(ms), EngineCommand.Deck(deck, DeckMessage.Play(true))))
        return e
    }

    @Test fun playsThrough() {
        val r = run(engine(440.0))
        assertTrue(r[0] > 0.2); assertTrue(r[1] > 0.2)
    }
    @Test fun eqKillsEachBand() {
        for ((hz, band) in listOf(80.0 to "low", 900.0 to "mid", 8000.0 to "hi")) {
            val open = run(engine(hz))[0]
            val killed = run(engine(hz) { m -> when (band) { "low" -> m.low[0] = 0.0; "mid" -> m.mid[0] = 0.0; else -> m.hi[0] = 0.0 } })[0]
            println("ENGINE eq $band kill at $hz Hz: ${20 * log10(killed / open)} dB")
            assertTrue(killed / open < 0.12, "$band kill")       // about -18 dB or more at the band's centre
        }
    }
    @Test fun crossfaderAndHiddenDecks() {
        assertTrue(run(engine(440.0) { it.xfader = 1.0 })[0] < 0.001, "deck 1 gone with the crossfader on the right")
        assertTrue(run(engine(440.0, deck = 1) { it.xfader = 1.0 })[0] > 0.2, "deck 2 still there")
        assertTrue(run(engine(440.0, deck = 2))[0] < 0.001, "deck 3 muted while 4-deck mode is off")
        assertTrue(run(engine(440.0, deck = 2) { it.active.fill(true) })[0] > 0.2, "deck 3 plays in 4-deck mode")
    }
    @Test fun headphonesOnThreeAndFour() {
        val e = engine(440.0) { it.pfl[0] = true; it.fader[0] = 0.0 }
        e.post(EngineCommand.Output(OutputMode.QUAD))
        val r = run(e, channels = 4)
        println("ENGINE quad: master ${r[0]} ${r[1]}, headphones ${r[2]} ${r[3]}")
        assertTrue(r[0] < 0.001, "fader down: nothing on the master")
        assertTrue(r[2] > 0.2, "CUE: in the headphones (pre-fader)")
        val e2 = engine(440.0) { it.headMix = 1.0 }
        e2.post(EngineCommand.Output(OutputMode.QUAD))
        val r2 = run(e2, channels = 4)
        assertTrue(r2[2] > 0.2, "CUE/MASTER right: master in the headphones")
        assertTrue(r2[0] > 0.2)
    }
    @Test fun limiterHoldsTheMaster() {
        val e = engine(440.0) { it.trim[0] = 1.0; it.hi[0] = 1.0; it.mid[0] = 1.0; it.low[0] = 1.0; it.master = 1.0 }
        val n = 512
        val outs = Array(2) { FloatArray(n) }
        var peak = 0f
        for (b in 0 until 200) { e.render(outs, n); if (b > 20) for (j in 0 until n) peak = max(peak, abs(outs[0][j])) }
        println("ENGINE limiter peak $peak")
        assertTrue(peak < 0.99f, "never over full scale")
    }
    @Test fun reportsPosition() {
        val e = engine(440.0)
        run(e, skip = 0.0, secs = 1.0)
        val s = e.snapshot()
        assertTrue(s.decks[0].playing)
        assertEquals(s.time, s.decks[0].pos / SR, 0.05)
    }
}
