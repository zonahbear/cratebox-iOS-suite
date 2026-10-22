// Set recording (Recorder.swift on iOS): the master output after the limiter (exactly what the speakers get), to a
// WAV (16-bit, lossless) or an AAC .m4a (256 kbps), saved to Music/Cratebox where the Files app and any player
// find it. A tracklist is kept while recording: every track that could be heard, with the time it came in.
// The audio thread only copies into a ring; a writer thread encodes into the app's cache, and on stop the file
// is copied into the phone's music library.
package com.zonahbear.cratebox.platform

import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import com.zonahbear.cratebox.core.Core
import com.zonahbear.cratebox.core.Engine
import com.zonahbear.cratebox.core.EngineCommand
import com.zonahbear.cratebox.core.MixerCurves
import com.zonahbear.cratebox.core.WavWriter
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.min

class Recorder(context: Context) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    @Volatile var recording = false; private set
    @Volatile var seconds = 0.0; private set
    var lastFile: Uri? = null; private set
    var lastName = ""; private set
    val tracklist = ArrayList<Pair<Double, String>>()
    var status: (String, Double) -> Unit = { _, _ -> }
    /** wav or aac */
    var format: String
        get() = prefs.getString("cb.recFmt", "wav") ?: "wav"
        set(v) { prefs.edit().putString("cb.recFmt", v).apply() }

    private val rate = AudioHost.SAMPLE_RATE
    private val cap = rate * 8
    private val ringL = FloatArray(cap); private val ringR = FloatArray(cap)
    @Volatile private var w = 0
    private var r = 0
    @Volatile private var stopFlag = false
    private var writer: Thread? = null
    private var temp: File? = null
    private var name = ""
    private val noted = HashSet<String>()

    private val tap: (FloatArray, FloatArray, Int) -> Unit = { l, rr, n ->
        var wi = w
        for (j in 0 until n) { ringL[wi] = l[j]; ringR[wi] = rr[j]; wi++; if (wi == cap) wi = 0 }
        w = wi                                                   // one writer, one reader: a volatile index is enough
    }

    fun start(engine: Engine) {
        if (recording) return
        val ext = if (format == "aac") "m4a" else "wav"
        name = "Cratebox set ${SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.US).format(Date())}.$ext"
        val f = File(app.cacheDir, "recording.$ext")
        val sink = try { if (ext == "m4a") AacSink(f, rate) else WavSink(f, rate) }
                   catch (e: Exception) { status("Couldn't start recording (${e.message})", 4.0); return }
        temp = f; w = 0; r = 0; seconds = 0.0; tracklist.clear(); noted.clear()
        stopFlag = false; recording = true
        engine.post(EngineCommand.SetRecordTap(tap))
        writer = Thread({ drainLoop(sink) }, "cratebox-recorder").also { it.start() }
        status("Recording to $name", 4.0)
    }

    private fun drainLoop(sink: Sink) {
        val bl = FloatArray(rate); val br = FloatArray(rate)
        var total = 0L
        try {
            while (true) {
                val done = stopFlag
                val wi = w
                var n = (wi - r + cap) % cap
                while (n > 0) {
                    val m = min(n, rate)
                    for (j in 0 until m) { val k = (r + j) % cap; bl[j] = ringL[k]; br[j] = ringR[k] }
                    sink.write(bl, br, m)
                    r = (r + m) % cap; n -= m; total += m
                }
                seconds = total.toDouble() / rate
                if (done) break
                Thread.sleep(100)
            }
        } finally { runCatching { sink.close() } }
    }

    fun stop(engine: Engine) {
        if (!recording) return
        engine.post(EngineCommand.SetRecordTap(null))
        Thread.sleep(50)                                         // the audio thread drops the tap at its next block
        stopFlag = true
        writer?.join(10_000); writer = null
        recording = false
        val f = temp ?: return
        val uri = publish(f, name)
        f.delete()
        if (uri == null) { status("Couldn't save the recording to Music/Cratebox", 8.0); return }
        lastFile = uri; lastName = name
        saveTracklist()
        status("Saved $name (Music → Cratebox)", 8.0)
    }

    /** into the shared music library, Music/Cratebox */
    private fun publish(f: File, display: String, mime: String? = null): Uri? {
        val type = mime ?: if (display.endsWith(".m4a")) "audio/mp4" else "audio/wav"
        val cr = app.contentResolver
        val coll = if (type.startsWith("audio/")) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Files.getContentUri("external")
        val cv = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, display)
            put(MediaStore.MediaColumns.MIME_TYPE, type)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_MUSIC}/Cratebox")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = cr.insert(coll, cv) ?: return null
        return try {
            cr.openOutputStream(uri)!!.use { out -> f.inputStream().use { it.copyTo(out) } }
            cr.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            uri
        } catch (e: Exception) { runCatching { cr.delete(uri, null, null) }; null }
    }

    /** call about once a second while recording */
    fun noteAudible(core: Core) {
        if (!recording) return
        for (d in core.decks) {
            if (!d.playing || !d.loaded) continue
            val i = d.i
            val heard = core.deckActive(i) && core.mixer.fader[i] > 0.05 && MixerCurves.xfGain(i, core.mixer.xfader) > 0.05
            val t = d.track ?: continue
            if (!heard || !noted.add(t.id)) continue
            tracklist.add(seconds to (if (t.artist.isEmpty()) t.title else "${t.artist} - ${t.title}"))
        }
    }

    fun tracklistText(): String =
        tracklist.joinToString("\n") { (s, n) -> String.format(Locale.US, "%d:%02d  ", s.toInt() / 60, s.toInt() % 60) + n } + "\n"

    private fun saveTracklist() {
        if (tracklist.isEmpty()) return
        val f = File(app.cacheDir, "tracklist.txt")
        f.writeText(tracklistText())
        publish(f, name.substringBeforeLast('.') + ".txt", "text/plain")
        f.delete()
    }

    private interface Sink { fun write(l: FloatArray, r: FloatArray, n: Int); fun close() }

    private class WavSink(f: File, rate: Int) : Sink {
        private val wav = WavWriter(RandomAccessFile(f, "rw"), rate, 2)
        private val planes = arrayOf(FloatArray(0), FloatArray(0))
        override fun write(l: FloatArray, r: FloatArray, n: Int) { planes[0] = l; planes[1] = r; wav.write(planes, n) }
        override fun close() = wav.close()
    }

    /** AAC-LC 256 kbps in an .m4a, through the phone's own encoder */
    private class AacSink(f: File, private val rate: Int) : Sink {
        private val codec: MediaCodec
        private val muxer = MediaMuxer(f.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        private var trackIx = -1
        private var framesIn = 0L
        private val info = MediaCodec.BufferInfo()

        init {
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 2).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 256_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        }

        override fun write(l: FloatArray, r: FloatArray, n: Int) {
            var j = 0
            while (j < n) {
                val i = codec.dequeueInputBuffer(10_000)
                if (i < 0) { drain(false); continue }
                val buf = codec.getInputBuffer(i)!!.order(ByteOrder.LITTLE_ENDIAN)
                buf.clear()
                val m = min(n - j, buf.capacity() / 4)
                for (k in 0 until m) {
                    buf.putShort(Math.round(l[j + k].coerceIn(-1f, 1f) * 32767f).toShort())
                    buf.putShort(Math.round(r[j + k].coerceIn(-1f, 1f) * 32767f).toShort())
                }
                codec.queueInputBuffer(i, 0, m * 4, framesIn * 1_000_000L / rate, 0)
                framesIn += m; j += m
                drain(false)
            }
        }

        private fun drain(end: Boolean) {
            var waits = 0
            while (true) {
                val o = codec.dequeueOutputBuffer(info, if (end) 10_000 else 0)
                when {
                    o == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!end || ++waits > 200) return      // 2 s for the last frames
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { trackIx = muxer.addTrack(codec.outputFormat); muxer.start() }
                    o >= 0 -> {
                        val b: ByteBuffer = codec.getOutputBuffer(o)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && trackIx >= 0) { b.position(info.offset); b.limit(info.offset + info.size); muxer.writeSampleData(trackIx, b, info) }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        override fun close() {
            try {
                val i = codec.dequeueInputBuffer(100_000)
                if (i >= 0) codec.queueInputBuffer(i, 0, 0, framesIn * 1_000_000L / rate, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                drain(true)
            } finally {
                runCatching { codec.stop() }; codec.release()
                runCatching { if (trackIx >= 0) muxer.stop() }; muxer.release()
            }
        }
    }
}
