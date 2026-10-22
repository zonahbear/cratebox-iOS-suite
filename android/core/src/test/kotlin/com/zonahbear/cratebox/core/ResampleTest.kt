package com.zonahbear.cratebox.core

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The decoder's rate conversion and the recorder's WAV writer (Android only: iOS has these in AVFoundation). */
class ResampleTest {
    private fun sine(f: Double, sr: Double, n: Int, phase: Double = 0.0) = FloatArray(n) { sin(2 * PI * f * it / sr + phase).toFloat() }

    @Test fun convertsASineCleanly() {
        for ((from, to) in listOf(44100.0 to 48000.0, 96000.0 to 48000.0, 22050.0 to 48000.0)) {
            val x = sine(1000.0, from, (from * 0.5).toInt())
            val y = Resample.resample(x, from, to)
            assertEquals(kotlin.math.ceil(x.size * to / from).toInt(), y.size, "$from → $to")
            val want = sine(1000.0, to, y.size)
            // away from the ends (the filter's half-length), within -80 dB
            var err = 0.0
            for (j in 200 until y.size - 200) err = max(err, abs((y[j] - want[j]).toDouble()))
            assertTrue(err < 1e-4, "$from → $to: max error $err")
        }
    }

    @Test fun removesWhatTheNewRateCantHold() {
        // 30 kHz at 96 kHz has no place at 48 kHz: it must come out (almost) silent, not fold down to 18 kHz
        val y = Resample.resample(sine(30000.0, 96000.0, 48000), 96000.0, 48000.0)
        var peak = 0.0
        for (j in 200 until y.size - 200) peak = max(peak, abs(y[j].toDouble()))
        assertTrue(peak < 1e-3, "alias at ${20 * kotlin.math.log10(peak)} dB")
    }

    @Test fun sameRateIsACopy() {
        val x = sine(440.0, 48000.0, 1000)
        assertContentEquals(x, Resample.resample(x, 48000.0, 48000.0))
    }

    @Test fun wavWriterRoundTrips() {
        val f = File.createTempFile("cratebox-rec", ".wav")
        try {
            WavWriter(RandomAccessFile(f, "rw"), 48000).use { w ->
                w.write(arrayOf(floatArrayOf(0f, 0.5f, -1f, 2f), floatArrayOf(1f, -0.5f, 0.25f, -2f)), 4)
                w.write(arrayOf(FloatArray(40000) { 0.1f }, FloatArray(40000) { -0.1f }), 40000)
            }
            val b = ByteBuffer.wrap(f.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(44 + 40004 * 4, f.length().toInt())
            assertEquals(36 + 40004 * 4, b.getInt(4)); assertEquals(40004 * 4, b.getInt(40))
            assertEquals(48000, b.getInt(24)); assertEquals(16, b.getShort(34).toInt())
            val s = (0 until 8).map { b.getShort(44 + 2 * it).toInt() }
            assertEquals(listOf(0, 32767, 16384, -16383, -32767, 8192, 32767, -32767), s)
            val fmt = AudioSniffer.sniff(f.readBytes().copyOf(64))
            assertEquals(AudioFacts(AudioCodec.WAV, 48000, 16, 2), fmt)
        } finally { f.delete() }
    }
}
