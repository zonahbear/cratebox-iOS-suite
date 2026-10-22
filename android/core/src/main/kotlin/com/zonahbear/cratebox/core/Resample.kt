// Sample-rate conversion for decoded tracks (iOS uses AVAudioConverter at its best quality; Android's decoders
// give each file's own rate, so Cratebox converts to the engine's 48 kHz itself). A Kaiser-windowed sinc,
// band-limited to the lower of the two rates, through a table of 512 sub-sample phases with linear interpolation
// between them: about -100 dB images, 24 zero crossings a side. Plain loops, nothing allocated per sample.
package com.zonahbear.cratebox.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

object Resample {
    private const val ZEROS = 24             // zero crossings each side of the centre
    private const val PHASES = 512
    private const val BETA = 9.0             // Kaiser window shape

    private fun bessel0(x: Double): Double {
        var sum = 1.0; var term = 1.0; var k = 1
        while (term > 1e-12 * sum) { val h = x / (2 * k); term *= h * h; sum += term; k++ }
        return sum
    }

    /** the filter at PHASES + 1 sub-sample offsets, each 2 × ZEROS taps, for a cut-off of `cut` (fraction of the input Nyquist) */
    private fun table(cut: Double): Array<FloatArray> {
        val i0b = bessel0(BETA)
        return Array(PHASES + 1) { p ->
            val frac = p.toDouble() / PHASES
            FloatArray(2 * ZEROS) { k ->
                val x = (k - ZEROS + 1) - frac          // taps at -ZEROS+1 … ZEROS around the sample point
                val t = x * cut
                val sinc = if (abs(t) < 1e-12) 1.0 else sin(PI * t) / (PI * t)
                val r = x / ZEROS
                val w = if (abs(r) >= 1) 0.0 else bessel0(BETA * sqrt(1 - r * r)) / i0b
                (cut * sinc * w).toFloat()
            }
        }
    }

    /** `x` at `from` Hz → at `to` Hz (the same samples back when the rates match) */
    fun resample(x: FloatArray, from: Double, to: Double): FloatArray {
        if (from == to || x.isEmpty()) return x.copyOf()
        val ratio = from / to                                   // input samples per output sample
        val cut = min(1.0, to / from) * 0.97                    // a little under the lower Nyquist
        val tab = table(cut)
        val n = ceil(x.size / ratio).toInt()
        val out = FloatArray(n)
        val taps = 2 * ZEROS
        for (j in 0 until n) {
            val pos = j * ratio
            val i = floor(pos).toInt()
            val f = (pos - i) * PHASES
            val p = f.toInt(); val a = (f - p).toFloat()
            val h0 = tab[p]; val h1 = tab[min(PHASES, p + 1)]
            var s = 0f
            val base = i - ZEROS + 1
            if (base >= 0 && base + taps <= x.size) {
                for (k in 0 until taps) s += x[base + k] * (h0[k] + a * (h1[k] - h0[k]))
            } else {
                for (k in 0 until taps) { val q = base + k; if (q >= 0 && q < x.size) s += x[q] * (h0[k] + a * (h1[k] - h0[k])) }
            }
            out[j] = s
        }
        return out
    }
}

/** A 16-bit PCM WAV file written as it goes (the set recorder's lossless format, like iOS's), sizes filled in on close. */
class WavWriter(private val file: java.io.RandomAccessFile, val sampleRate: Int, val channels: Int = 2) : AutoCloseable {
    private var frames = 0L
    private val buf = java.nio.ByteBuffer.allocate(65536).order(java.nio.ByteOrder.LITTLE_ENDIAN)

    init { file.setLength(0); file.write(header(0)) }

    private fun header(dataBytes: Long): ByteArray {
        val b = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt((36 + dataBytes).toInt()).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(channels.toShort()).putInt(sampleRate)
            .putInt(sampleRate * channels * 2).putShort((channels * 2).toShort()).putShort(16)
        b.put("data".toByteArray()).putInt(dataBytes.toInt())
        return b.array()
    }

    /** n frames of planar float (−1…1, clipped) */
    fun write(planes: Array<FloatArray>, n: Int) {
        for (j in 0 until n) {
            if (buf.remaining() < channels * 2) flush()
            for (c in 0 until channels) {
                val v = planes[c][j].coerceIn(-1f, 1f)
                buf.putShort(Math.round(v * 32767f).toShort())
            }
        }
        frames += n
    }

    private fun flush() { file.write(buf.array(), 0, buf.position()); buf.clear() }

    override fun close() {
        flush()
        file.seek(0); file.write(header(frames * channels * 2))
        file.close()
    }
}
