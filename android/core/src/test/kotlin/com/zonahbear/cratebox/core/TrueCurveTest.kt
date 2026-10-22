package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Port of ios/CrateboxKit TrueCurveTests.swift. Expected numbers come from running cratebox.html's TC code in
// node (makeCurve, Driver, the simulator's plant) and Node's crypto for the unlock token.
class TrueCurveTest {
    private val tc = TrueCurve
    private val banger = tc.preset("Quartz Banger")!!

    @Test fun curveMatchesWeb() {
        val c = TrueCurve.Curve.of(banger.points, smooth = true)!!
        assertEquals(65.0, c.end)
        for ((t, f) in listOf(0.0 to 520.0, 10.0 to 508.0, 25.0 to 485.0, 45.0 to 462.0, 65.0 to 450.0, 5.0 to 515.669, 30.0 to 478.424))
            assertEquals(f, c.at(t), 0.001, "t=$t")
        assertEquals(-1.4661, c.slope(5.0), 1e-4)
        assertEquals(-1.2954, c.slope(30.0), 1e-4)
        val lin = TrueCurve.Curve.of(banger.points, smooth = false)!!
        assertEquals(514.0, lin.at(5.0), 0.001)
        assertEquals(479.25, lin.at(30.0), 0.001)
        assertEquals(520.0, c.at(-5.0)); assertEquals(450.0, c.at(99.0))
        assertNull(TrueCurve.Curve.of(listOf(TrueCurve.Point(3.0, 500.0), TrueCurve.Point(3.0, 510.0)), smooth = true))
    }

    @Test fun curveNeverOvershoots() {
        for ((name, _) in tc.presets) {
            val def = tc.preset(name)!!
            val c = TrueCurve.Curve.of(def.points, smooth = true)!!
            for (i in 0 until def.points.size - 1) {
                val a = def.points[i]; val b = def.points[i + 1]
                val lo = minOf(a.f, b.f) - 1e-9; val hi = maxOf(a.f, b.f) + 1e-9
                for (k in 0..20) { val v = c.at(a.t + (b.t - a.t) * k / 20); assertTrue(v >= lo && v <= hi, "$name $v") }
            }
        }
    }

    @Test fun driverStaysInSafeBand() {
        val c = TrueCurve.Curve.of(banger.points, smooth = true)!!
        val d = TrueCurve.Driver(c, TrueCurve.HeaterModel())
        for (k in 0 until 400) {
            val t = k * 0.2; val r = c.at(t)
            for (y in listOf(null, 70.0, r - 50, r, r + 50, 640.0)) {
                val u = d.command(t, y, 0.2)
                assertTrue(u >= max(tc.MIN_F, r - 40) - 1e-9 && u <= minOf(tc.MAX_F, r + 30) + 1e-9)
            }
        }
    }

    /** the runner's loop against the simulator: preheat, then 5 Hz commands with the web app's send rules */
    @Test fun closedLoopTracksQuartzBanger() {
        val c = TrueCurve.Curve.of(banger.points, smooth = true)!!
        val sim = TrueCurve.SimHeater()
        val drv = TrueCurve.Driver(c, TrueCurve.HeaterModel())
        val learner = TrueCurve.Learner(TrueCurve.HeaterModel())
        sim.slots[3] = TrueCurve.SimHeater.Slot(520.0, 75.0); sim.slotIdx = 3; sim.start()
        fun adv(dt: Double) { repeat((dt / 0.05).roundToInt()) { sim.advance(0.05) } }
        var pt = 0.0
        while (sim.y < 512 && pt < 70) { adv(0.25); pt += 0.25 }
        assertTrue(pt < 60, "preheat")
        var sent = 520.0; var sentAt = -9.0; var err = 0.0; var n = 0.0; var worst = 0.0; var t = 0.0
        while (t < c.end) {
            val y = Math.round(sim.y * 10) / 10.0
            val u = Math.round(drv.command(t, y, 0.2) * 10) / 10.0
            val diff = abs(u - sent)
            if (diff >= 1.5 || (diff >= 0.5 && t - sentAt > 1.5)) { sim.setLiveTarget(u); sent = u; sentAt = t }
            learner.add(t, y, sent)
            if (t > 1) { val e = abs(y - c.at(t)); err += e; n += 1; worst = max(worst, e) }
            assertTrue(y < tc.CUTOFF_F)
            adv(0.2); t += 0.2
        }
        // node gives 0.27 average, 4.2 worst
        assertTrue(err / n < 2, "average ${err / n}")
        assertTrue(worst < 10, "worst $worst")
        assertTrue(sim.state in tc.heating, "the device should still be in its cycle")
        assertTrue(learner.m.tau.isFinite() && learner.m.heatMax.isFinite() && learner.m.coolK.isFinite())
    }

    @Test fun pasteFromTrueCurve() {
        val txt = """ {"Mine": {"points": [{"t": 0, "f": 700}, {"t": "20", "f": 480}, {"t": 999, "f": 300}, {"t": "x", "f": 1}], "smooth": false},""" +
            """ "Bad": {"points": [{"t": 0, "f": 500}]}, "A name that is far too long for the menu": {"points": [{"t": 0, "f": 500}, {"t": 9, "f": 510}]}} """
        val got = tc.parseCurves(txt)!!
        assertEquals(TrueCurve.CurveDef(listOf(TrueCurve.Point(0.0, 590.0), TrueCurve.Point(20.0, 480.0), TrueCurve.Point(110.0, 350.0)), false), got["Mine"])
        assertNull(got["Bad"])
        assertEquals(true, got["A name that is far too l"]?.smooth)
        assertEquals(2, got.size)
        assertNull(tc.parseCurves("not json"))
    }

    @Test fun loraxBytes() {
        assertEquals(hex("cc4af4246a24eb8bb512bc7dc5157b9c"), Lorax.token((0 until 16).toList()))
        assertEquals(hex("398e8743"), Lorax.encodeC(tc.fToC(520.0), Lorax.Fmt.F32))
        assertEquals(hex("970a0000"), Lorax.encodeC(tc.fToC(520.0), Lorax.Fmt.I10))
        assertEquals(271.111, Lorax.decodeC(hex("398e8743"), Lorax.Fmt.F32)!!, 0.001)
        assertEquals(271.1, Lorax.decodeC(hex("970a0000"), Lorax.Fmt.I10))
        assertEquals(271.1, Lorax.decodeC(hex("970a0000"), null))   // a tiny denormal float: read as tenths
        assertEquals(listOf(0, 0, 4, 0) + "/p/x".map { it.code }, Lorax.readPayload("/p/x", 4))
        assertEquals(listOf(0, 0, 0) + "/p/x".map { it.code } + listOf(0, 9), Lorax.writePayload("/p/x", listOf(9)))
        assertEquals(listOf(2, 1, 16, 7), Lorax.frame(0x0102, 16, listOf(7)))
        assertEquals(Lorax.Fmt.F32, Lorax.detectFormat(hex("398e8743"), isProxy = true))
        assertEquals(Lorax.Fmt.I10, Lorax.detectFormat(hex("970a0000"), isProxy = false))
        assertEquals(Lorax.Fmt.I10, Lorax.detectFormat(null, isProxy = true))
        val soc = Lorax.SocDecoder()
        assertEquals(87, soc.decode(Lorax.f32Bytes(0.87)))
        assertEquals(53, soc.decode(listOf(0x12, 0x02, 0, 0)))   // 530 = 53.0 %
        assertEquals(5, soc.decode(listOf(53)))                  // the scale sticks once seen
        assertNotNull(Lorax.detectLiveFormat(hex("398e8743")))
    }

    private fun hex(s: String): List<Int> = (s.indices step 2).map { s.substring(it, it + 2).toInt(16) }

    @Test fun curvesAndModelRoundTrip() {
        val c = mapOf("Mine" to TrueCurve.CurveDef(listOf(TrueCurve.Point(0.0, 500.0), TrueCurve.Point(30.5, 455.0)), false))
        assertEquals(c, TrueCurve.parseCurves(TrueCurve.encodeCurves(c)))
        val m = TrueCurve.HeaterModel(tau = 3.5, heatMax = 13.0, coolK = 0.012, dead = 0.5, runs = 4)
        assertEquals(m, TrueCurve.parseModel(TrueCurve.encodeModel(m)))
        // what iOS's JSONEncoder writes
        assertEquals(m, TrueCurve.parseModel("""{"dead":0.5,"runs":4,"tau":3.5,"coolK":0.012,"heatMax":13}"""))
        assertEquals(null, TrueCurve.parseModel("""{"tau":1}"""))
    }
}
