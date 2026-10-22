package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.abs
import kotlin.math.max
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/** Port of DSPTests.swift: the Kotlin deck player and FX unit against the web app's own (Fixtures/dsp, rendered
 *  in node by ios/tools/dsp_oracle.js from cratebox.html's WORKLET): same scenarios, same samples. */
class DSPTest {
    private val SR = 44100.0

    private data class Result(val maxErr: Float, val at: Int, val n: Int)

    private fun runScenario(name: String, sc: JsonObject, sigL: FloatArray, sigR: FloatArray): Result {
        val blocks = sc["blocks"]!!.jsonPrimitive.int
        val input = sc["input"]!!.jsonPrimitive.boolean
        val proc = sc["proc"]!!.jsonPrimitive.content
        val steps = sc["steps"]!!.jsonArray.map { it.jsonObject }
        val want = Fixtures.floats("dsp/$name.f32")
        val total = blocks * 128
        val outL = FloatArray(total); val outR = FloatArray(total)
        val deck = DeckPlayer(SR); val fx = FxUnit(SR)
        val track = PCMTrack(sigL, sigR, SR)
        fun num(m: JsonObject, k: String): Double? = (m[k] as? JsonPrimitive)?.doubleOrNull
        fun bool(m: JsonObject, k: String): Boolean? = (m[k] as? JsonPrimitive)?.booleanOrNull
        val bl = FloatArray(128); val br = FloatArray(128)
        for (b in 0 until blocks) {
            val time = b * 128 / SR
            for (s in steps) {
                if (s["block"]!!.jsonPrimitive.int != b) continue
                val m = s["msg"]!!.jsonObject
                val t = m["t"]!!.jsonPrimitive.content
                if (proc == "deck-player") {
                    when (t) {
                        "load" -> { deck.setTrack(track); deck.handle(DeckMessage.Load(bool(m, "mt"), num(m, "spin"))) }
                        "play" -> deck.handle(DeckMessage.Play(bool(m, "v")!!))
                        "rate" -> deck.handle(DeckMessage.Rate(num(m, "v")!!))
                        "seek" -> deck.handle(DeckMessage.Seek(num(m, "v")!!, 0))
                        "bend" -> deck.handle(DeckMessage.Bend(num(m, "v")!!))
                        "scratch" -> deck.handle(DeckMessage.Scratch(bool(m, "v")!!, bool(m, "noCoast") ?: false))
                        "jog" -> deck.handle(DeckMessage.Jog(num(m, "v")!!))
                        "loop" -> deck.handle(DeckMessage.Loop(bool(m, "on")!!, num(m, "a")!!, num(m, "b")!!))
                        "mt" -> deck.handle(DeckMessage.Mt(bool(m, "v")!!))
                        else -> fail("unknown deck message $t")
                    }
                } else {
                    if (t == "clock") fx.clock = FxClock(num(m, "t0")!!, num(m, "beat0")!!, num(m, "bps")!!, num(m, "spb")!!)
                    else {
                        val slot = if (m["slot"]!!.jsonPrimitive.content == "beat") fx.beat else fx.pad
                        slot.set((m["fx"] as? JsonPrimitive)?.content?.let { FxKind.of(it) }, num(m, "beats"), num(m, "depth"), bool(m, "on"))
                    }
                }
            }
            if (proc == "deck-player") deck.render(bl, br, 128)
            else {
                for (i in 0 until 128) { bl[i] = if (input) sigL[b * 128 + i] else 0f; br[i] = if (input) sigR[b * 128 + i] else 0f }
                fx.process(bl, br, 128, time)
            }
            for (i in 0 until 128) { outL[b * 128 + i] = bl[i]; outR[b * 128 + i] = br[i] }
        }
        var maxErr = 0f
        var at = -1
        for (i in 0 until total) {
            val e = max(abs(outL[i] - want[i]), abs(outR[i] - want[total + i]))
            if (e > maxErr) { maxErr = e; if (at < 0 && e > 1e-4f) at = i }
        }
        return Result(maxErr, at, total)
    }

    @Test fun matchesTheWebApp() {
        val all = Fixtures.floats("dsp/signal.f32")
        val half = all.size / 2
        val sigL = all.copyOfRange(0, half); val sigR = all.copyOfRange(half, all.size)
        val index = Json.parseToJsonElement(Fixtures.text("dsp/scenarios.json")).jsonObject
        assertEquals(15, index.size)
        for (name in index.keys.sorted()) {
            val r = runScenario(name, index[name]!!.jsonObject, sigL, sigR)
            println("DSP $name: max error ${r.maxErr} (first > 1e-4 at sample ${r.at}) over ${r.n} samples")
            assertTrue(r.maxErr < 1e-4f, "$name: differs from the web app, first at sample ${r.at}")
        }
    }
}
