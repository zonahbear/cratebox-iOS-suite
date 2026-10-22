package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/** Port of AnalysisTests.swift: track analysis against the web app's (Fixtures/analysis.json, from
 *  ios/tools/analysis_oracle.js) on the synthetic test tracks. Make them with
 *  `python3 tests/make_tracks.py <dir>` (checked against Fixtures/music.md5) and pass the folder as CRATEBOX_MUSIC. */
class AnalysisTest {
    private fun wav(f: File): Pair<List<FloatArray>, Double> {
        val b = f.readBytes()
        fun u16(o: Int) = (b[o].toInt() and 0xff) or ((b[o + 1].toInt() and 0xff) shl 8)
        fun u32(o: Int) = u16(o) or (u16(o + 2) shl 16)
        var o = 12; var fmt = 0; var data = 0; var size = 0
        while (o + 8 <= b.size) {
            val id = String(b, o, 4, Charsets.US_ASCII); val sz = u32(o + 4)
            if (id == "fmt ") fmt = o + 8
            if (id == "data") { data = o + 8; size = sz; break }
            o += 8 + sz + (sz and 1)
        }
        val ch = u16(fmt + 2); val sr = u32(fmt + 4).toDouble(); val n = size / (2 * ch)
        val chs = List(ch) { FloatArray(n) }
        for (i in 0 until n) for (c in 0 until ch) chs[c][i] = u16(data + 2 * (i * ch + c)).toShort() / 32768f
        return chs to sr
    }

    @Test fun matchesTheWebApp() {
        val dir = System.getenv("CRATEBOX_MUSIC")
        assumeTrue(dir != null, "CRATEBOX_MUSIC not set")
        val want = Json.parseToJsonElement(Fixtures.text("analysis.json")).jsonObject
        assertEquals(4, want.size)
        for (name in want.keys.sorted()) {
            val w = want[name]!!.jsonObject
            val (chs, sr) = wav(File(dir, name))
            val t0 = System.nanoTime()
            val (mono, fs) = Analysis.monoFor(chs, chs[0].size, sr)
            val r = Analysis.analyze(mono, fs)
            val secs = (System.nanoTime() - t0) / 1e9
            fun num(k: String) = w[k]!!.jsonPrimitive.double
            assertEquals(w["n"]!!.jsonPrimitive.int, mono.size, name)
            assertEquals(num("monoSum"), mono.fold(0.0) { a, v -> a + v }, 1e-6, name)
            val wantPh = w["phrases"]!!.jsonArray.map { val p = it.jsonObject; Phrase(p["start"]!!.jsonPrimitive.double, p["bars"]!!.jsonPrimitive.int, p["label"]!!.jsonPrimitive.content) }
            println("ANALYSIS $name: bpm ${r.bpm} (web ${num("bpm")}), first beat ${r.firstBeat} (web ${num("firstBeat")}), key ${r.key} (web ${w["key"]}), " +
                "phrases ${r.phrases.map { "${it.label} ${it.bars}" }} (web ${wantPh.map { "${it.label} ${it.bars}" }}), ${"%.2f".format(secs)} s")
            assertEquals(num("bpm"), r.bpm, 1e-9, name)
            assertEquals(num("firstBeat"), r.firstBeat, 1e-6, name)
            assertEquals(num("gridConf"), r.gridConf, 1e-6, name)
            assertEquals(w["key"]!!.jsonPrimitive.int, r.key, name)
            assertEquals(num("keyConf"), r.keyConf, 1e-6, name)
            assertEquals(wantPh.size, r.phrases.size, name)
            for ((a, b) in r.phrases.zip(wantPh)) { assertEquals(b.label, a.label, name); assertEquals(b.bars, a.bars, name); assertEquals(b.start, a.start, 1e-6, name) }
            val ww = w["wave"]!!.jsonObject
            val wv = r.wave!!
            for ((k, got) in listOf("peak" to wv.peak, "rms" to wv.rms, "low" to wv.low, "mid" to wv.mid, "high" to wv.high)) {
                val exp = ww[k]!!.jsonArray.map { it.jsonPrimitive.int }
                assertEquals(exp.size, got.size, "$name $k")
                val off = got.indices.count { (got[it].toInt() and 0xff) != exp[it] }
                println("ANALYSIS $name wave $k: $off of ${exp.size} bytes differ")
                assertEquals(0, off, "$name waveform $k")
            }
        }
    }
}
