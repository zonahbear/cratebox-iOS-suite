// Decoding for the decks and the analysis (AudioDecoder in iOS's Library.swift): the whole file, as 32-bit
// float stereo at the engine's rate. MediaExtractor + MediaCodec read whatever the phone can (MP3, AAC/M4A, WAV,
// FLAC, AIFF on most, ALAC on Android 10+ devices that ship it); core Resample converts to 48 kHz.
// Memory: a 6-minute track is about 140 MB as float stereo, as on iOS; the manifest asks for a large heap.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import com.zonahbear.cratebox.core.Analysis
import com.zonahbear.cratebox.core.PCMTrack
import com.zonahbear.cratebox.core.Resample
import java.nio.ByteOrder

object AudioDecoder {
    class Failure(message: String) : Exception(message)

    /** a growing float array, without boxing */
    private class Grow(cap: Int) {
        var a = FloatArray(maxOf(cap, 4096)); var n = 0
        fun add(v: Float) { if (n == a.size) a = a.copyOf(a.size + a.size / 2); a[n++] = v }
        fun trimmed() = if (n == a.size) a else a.copyOf(n)
    }

    fun decode(context: Context, uri: Uri, rate: Int = AudioHost.SAMPLE_RATE, cancelled: () -> Boolean = { false }): PCMTrack {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(context, uri, null)
            return decode(ex, rate, cancelled)
        } finally { ex.release() }
    }

    fun decode(path: String, rate: Int = AudioHost.SAMPLE_RATE, cancelled: () -> Boolean = { false }): PCMTrack {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            return decode(ex, rate, cancelled)
        } finally { ex.release() }
    }

    private fun decode(ex: MediaExtractor, rate: Int, cancelled: () -> Boolean): PCMTrack {
        val ti = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            ?: throw Failure("no audio in the file")
        ex.selectTrack(ti)
        val fmt = ex.getTrackFormat(ti)
        val mime = fmt.getString(MediaFormat.KEY_MIME)!!
        var srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val durUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else 0L
        // ask for float; decoders that can't give it keep 16-bit, which the output format says
        fmt.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_FLOAT)
        val codec = MediaCodec.createDecoderByType(mime)
        val cap = (durUs / 1e6 * srcRate).toInt() + 4096
        val left = Grow(cap); val right = Grow(cap)
        try {
            codec.configure(fmt, null, null, 0)
            codec.start()
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            runCatching { codec.outputFormat }.getOrNull()?.let { of ->
                if (of.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = of.getInteger(MediaFormat.KEY_PCM_ENCODING)
            }
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var idle = 0
            while (!outputDone) {
                if (cancelled()) throw Failure("cancelled")
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) { codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val of = codec.outputFormat
                        srcRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        encoding = if (of.containsKey(MediaFormat.KEY_PCM_ENCODING)) of.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                    }
                    o >= 0 -> {
                        idle = 0
                        val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
                        buf.position(info.offset); buf.limit(info.offset + info.size)
                        val ch = maxOf(1, channels)
                        when (encoding) {
                            AudioFormat.ENCODING_PCM_FLOAT -> {
                                val f = buf.asFloatBuffer()
                                val frames = f.remaining() / ch
                                for (k in 0 until frames) { val b = k * ch; left.add(f.get(b)); right.add(f.get(if (ch > 1) b + 1 else b)) }
                            }
                            else -> {
                                val s = buf.asShortBuffer()
                                val frames = s.remaining() / ch
                                for (k in 0 until frames) { val b = k * ch; left.add(s.get(b) / 32768f); right.add(s.get(if (ch > 1) b + 1 else b) / 32768f) }
                            }
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                    else -> if (inputDone && ++idle > 300) outputDone = true      // a decoder that never signals the end
                }
            }
        } finally {
            runCatching { codec.stop() }
            codec.release()
        }
        if (left.n == 0) throw Failure("the file decoded to nothing")
        var l = left.trimmed(); var r = right.trimmed()
        if (srcRate != rate) {
            l = Resample.resample(l, srcRate.toDouble(), rate.toDouble())
            r = Resample.resample(r, srcRate.toDouble(), rate.toDouble())
        }
        return PCMTrack(l, r, rate.toDouble())
    }

    /** the analysis's mono signal, at about `target` Hz */
    fun mono(t: PCMTrack, target: Double): Pair<FloatArray, Double> = Analysis.monoFor(listOf(t.left, t.right), t.count, t.sampleRate, target)
}
