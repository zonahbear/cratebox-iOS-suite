package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Port of CoreTests.swift: decks, sync and the FLX4 mapping, offline: the engine is rendered by hand and the clock is its own. */
class CoreTest {
    private val SR = 44100.0

    class Rig(val core: Core) : ControlTarget {
        val midi = MIDIEngine()
        val sent = ArrayList<List<Int>>()
        init { midi.target = this; midi.send = { sent.add(it) }; midi.use(Profiles.byId("ddj-flx4")!!) }
        override val fourDecks get() = core.four
        override fun absValue(name: String, deck: Int) = core.mixerValue(name, deck)
        override fun setAbs(name: String, deck: Int, v: Double) { if (name == "tempo") core.decks[deck].setPitch(v * 2 - 1) else core.setMixer(name, deck, v) }
        override fun press(name: String, arg: String, deck: Int, on: Boolean) {
            val d = if (deck >= 0) core.decks[deck] else null
            when (name) {
                "play" -> if (on) d?.togglePlay()
                "cue" -> if (on) d?.cueDown() else d?.cueUp()
                "sync" -> if (on && d != null) d.setSync(!d.sync)
                "hot" -> if (on) d?.hotcue(arg.toInt())
                "loop" -> if (on) d?.beatLoop(arg.toDouble())
                "touch" -> d?.jogTouch(on)
            }
        }
        override fun relative(name: String, deck: Int, ticks: Int) {}
        override fun led(name: String, arg: String, deck: Int, blink: Boolean): Int? = if (name == "play") (if (core.decks[deck].playing) 127 else 0) else null
        override fun vu(deck: Int) = 0.0
        override fun controllerStatus(s: String) {}
    }

    private fun makeCore(): Pair<Core, Engine> {
        val e = Engine(SR)
        val c = Core(e)
        c.clock = { e.time }
        var wall = 0.0
        c.wallMs = { wall += 1; wall }
        return c to e
    }
    private fun clickTrack(bpm: Double, secs: Double = 20.0): PCMTrack {
        val n = (secs * SR).toInt(); val t = PCMTrack(n, SR); val spb = 60 / bpm
        for (i in 0 until n) { val ph = (i / SR) % spb; val v = if (ph < 0.01) 0.8f else 0f; t.left[i] = v; t.right[i] = v }
        return t
    }
    private fun load(c: Core, deck: Int, bpm: Double) {
        val info = TrackInfo("t$deck-$bpm", "Click $bpm")
        val d = c.decks[deck]
        d.beginLoad(info)
        d.finishLoad(info, clickTrack(bpm), DeckAnalysis(bpm, 0.0, 21, emptyList(), null, 20.0), null)
    }
    private fun render(e: Engine, c: Core, secs: Double) {
        val n = 256; val outs = Array(2) { FloatArray(n) }
        repeat((secs * SR).toInt() / n) { e.render(outs, n); c.tick() }
    }

    @Test fun playCueHotcueLoop() {
        val (c, e) = makeCore(); load(c, 0, 120.0)
        render(e, c, 0.1)
        val d = c.decks[0]
        assertTrue(d.loaded)
        d.togglePlay(); render(e, c, 1.0)
        assertEquals(1.0, d.now(), 0.05)
        d.hotcue(0)                                 // set A on the beat (Q on): 1.0 s at 120 BPM
        assertEquals(1.0, d.hot[0]!!, 1e-9)
        d.beatLoop(1.0); render(e, c, 2.0)          // a 1-beat loop: stays inside it
        assertTrue(d.loop.on)
        assertTrue(d.now() >= d.loop.a!! - 0.02); assertTrue(d.now() <= d.loop.b!! + 0.02)
        d.cueDown(); render(e, c, 0.1)              // playing: back to the cue point and stop
        assertFalse(d.playing)
    }
    @Test fun syncHalftimeAndBeatLock() {
        val (c, e) = makeCore(); load(c, 0, 140.0); load(c, 1, 70.5)
        render(e, c, 0.1)
        c.decks[0].togglePlay(); render(e, c, 0.5)
        val d = c.decks[1]
        d.setSync(true)
        assertEquals(0.5, d.syncMult, "70.5 against 140: half the master's tempo (halftime), not sped up to 140")
        assertEquals(70.0, d.bpm * d.rate(), 0.05)
        d.seek(5.0); render(e, c, 0.05)
        d.togglePlay(); render(e, c, 4.0)
        assertNotNull(d.phaseErr)
        assertTrue(abs(d.phaseErr ?: 1.0) < 0.005, "beat lock holds the phase")
    }
    @Test fun flx4Messages() {
        val (c, e) = makeCore(); load(c, 0, 120.0)
        render(e, c, 0.1)
        val rig = Rig(c)
        rig.midi.receive(listOf(0x90, 0x0b, 0x7f)); rig.midi.receive(listOf(0x90, 0x0b, 0x00))   // PLAY
        assertTrue(c.decks[0].playing)
        rig.midi.receive(listOf(0xb0, 0x13, 0x40)); rig.midi.receive(listOf(0xb0, 0x33, 0x00))   // channel fader, 14 bit
        assertEquals((0x40 shl 7) / 16383.0, c.mixer.fader[0], 1e-9)
        rig.midi.receive(listOf(0xb0, 0x00, 0x7f)); rig.midi.receive(listOf(0xb0, 0x20, 0x7f))   // tempo fader to the bottom: faster
        assertEquals(1.0, c.decks[0].pitch, 1e-6)
        rig.midi.updateLeds(false)
        assertTrue(listOf(0x90, 0x0b, 0x7f) in rig.sent, "PLAY light on")
        rig.midi.connected()
        assertTrue(Profiles.FLX4_KEEPALIVE in rig.sent, "keep-alive sent")
    }
    @Test fun layersAndSoftTakeover() {
        val (c, _) = makeCore(); c.setFour(true)
        val rig = Rig(c)
        c.mixer.fader[2] = 0.3
        rig.midi.receive(listOf(0xb0, 0x13, 0x7f))        // deck 1 fader up
        assertEquals(1.0, c.mixer.fader[0], 0.01)
        rig.midi.toggleSide(0)                            // left side -> deck 3
        rig.midi.receive(listOf(0xb0, 0x13, 0x7e))        // the hardware fader is still up: deck 3 doesn't jump
        assertEquals(0.3, c.mixer.fader[2], 1e-9)
        rig.midi.receive(listOf(0xb0, 0x13, 0x30)); rig.midi.receive(listOf(0xb0, 0x13, 0x26))    // moved down past 0.3: takes over
        assertEquals(0x26 / 127.0, c.mixer.fader[2], 0.01)
        assertEquals(1.0, c.mixer.fader[0], 0.01, "deck 1 left alone")
    }
    @Test fun profilesAndKeys() {
        assertEquals("ddj-flx4", Profiles.profile("DDJ-FLX4").id)
        assertEquals("ddj-400", Profiles.profile("DDJ-400").id)
        assertEquals("ddj-rekordbox", Profiles.profile("DDJ-FLX6").id)
        assertEquals("learn", Profiles.profile("Some Keyboard").id)
        assertTrue(Profiles.mixxx.isNotEmpty(), "Mixxx maps bundled")
        assertEquals("8B", Keys.camelot(0)?.label); assertEquals("8A", Keys.camelot(21)?.label); assertEquals("4A", Keys.camelot(17)?.label)
        assertTrue(Keys.mixes(21, 0)); assertTrue(Keys.mixes(21, 16)); assertFalse(Keys.mixes(21, 1))
    }
    @Test fun version() { assertTrue(CrateboxKit.VERSION.endsWith("-android")) }
}
