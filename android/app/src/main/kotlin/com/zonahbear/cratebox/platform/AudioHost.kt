// The Android side of the audio (AudioHost.swift on iOS): one AudioTrack in float, low-latency mode, fed by a
// render thread whose only source is Cratebox's own engine (core Engine). With a 4-channel USB output (the FLX4)
// the master goes to 1/2 and the headphone mix to 3/4, like the web app's "FLX4 jack" headphone setting; on a
// plain stereo output, headphones can go on a splitter cable (mono master left, mono cue right).
package com.zonahbear.cratebox.platform

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import com.zonahbear.cratebox.core.Engine
import com.zonahbear.cratebox.core.EngineCommand
import com.zonahbear.cratebox.core.OutputMode
import kotlin.math.max
import kotlin.math.min

class AudioHost(context: Context) {
    companion object {
        const val SAMPLE_RATE = 48000
        private const val BLOCK = 256                       // frames per render: about 5 ms
        private const val PREVIEW_CHUNK = 1024
    }
    private val app = context.applicationContext
    private val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val prefs = app.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())

    val engine = Engine(SAMPLE_RATE.toDouble())
    /** Cratebox USB's preview player: a second engine mixed in on top of the decks, only while it's on */
    val preview = Engine(SAMPLE_RATE.toDouble())
    @Volatile var previewOn = false

    @Volatile private var track: AudioTrack? = null
    private var thread: Thread? = null
    @Volatile private var stopRender = false
    @Volatile private var framesWritten = 0L

    var outputChannels = 2; private set
    var routeName = ""; private set
    var lastError = ""; private set
    var diagnostics = ""; private set
    /** how far behind the audio clock you hear things (the output's latency plus the buffer): with Bluetooth
     *  this is 150-300 ms. The screen shows positions this much later, so waveforms match what you hear. */
    @Volatile var latency = 0.0; private set
    var wireless = false; private set
    var onRoute: (() -> Unit)? = null
    val running get() = track?.playState == AudioTrack.PLAYSTATE_PLAYING

    /** auto, swapped (headphones on 1/2), stereo */
    val routing: String get() = prefs.getString("cb.routing", "auto") ?: "auto"

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) { if (added.any { it.isSink }) restart() }
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) { if (removed.any { it.isSink }) restart() }
    }

    fun start() {
        am.registerAudioDeviceCallback(deviceCallback, main)
        build()
    }

    fun shutdown() {
        am.unregisterAudioDeviceCallback(deviceCallback)
        stopTrack()
    }

    private var building = false
    fun restart() {
        if (building) return
        building = true
        try { stopTrack(); build() } finally { building = false }
    }

    /** the USB output with 4 or more channels (a DJ controller's audio interface), if one is plugged in */
    private fun quadDevice(): AudioDeviceInfo? = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { d ->
        (d.type == AudioDeviceInfo.TYPE_USB_DEVICE || d.type == AudioDeviceInfo.TYPE_USB_HEADSET) &&
            (d.channelCounts.any { it >= 4 } || d.channelIndexMasks.any { Integer.bitCount(it) >= 4 })
    }

    private fun build() {
        val quad = if (routing != "stereo") quadDevice() else null
        // the controller's 4 outputs first (master 1/2, headphones 3/4), then plain stereo
        val tries = if (quad != null) listOf(4 to quad, 2 to null) else listOf(2 to null)
        for ((ch, dev) in tries) {
            if (attach(ch, dev)) { outputChannels = ch; lastError = ""; describe(); onRoute?.invoke(); return }
        }
        outputChannels = 2
        describe()
        onRoute?.invoke()
    }

    private fun attach(ch: Int, device: AudioDeviceInfo?): Boolean {
        return try {
            val fmt = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(SAMPLE_RATE).apply {
                // an index mask, so channel 3 really is the controller's output 3 (a positional mask can get re-mapped)
                if (ch >= 4) setChannelIndexMask((1 shl ch) - 1) else setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            }.build()
            val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
            val minBytes = AudioTrack.getMinBufferSize(SAMPLE_RATE, if (ch >= 4) AudioFormat.CHANNEL_OUT_QUAD else AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
            val t = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(fmt)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .setBufferSizeInBytes(max(minBytes, BLOCK * 4 * ch * 4))
                .build()
            if (t.state != AudioTrack.STATE_INITIALIZED) { t.release(); lastError = "the output wouldn't open with $ch channels"; return false }
            if (device != null && !t.setPreferredDevice(device)) { t.release(); lastError = "couldn't route to ${device.productName}"; return false }
            // the smallest buffer that doesn't glitch: start at two bursts, the render loop grows it on underruns
            runCatching { t.bufferSizeInFrames = min(t.bufferCapacityInFrames, max(BLOCK * 2, t.bufferSizeInFrames / 2)) }
            track = t
            framesWritten = 0
            engine.post(EngineCommand.Output(outputMode(ch)))
            preview.post(EngineCommand.Output(outputMode(ch)))
            t.play()
            startRender(t, ch)
            routeName = device?.productName?.toString() ?: currentOutputName()
            true
        } catch (e: Exception) {
            lastError = e.message ?: e.toString()
            false
        }
    }

    private fun startRender(t: AudioTrack, ch: Int) {
        stopRender = false
        val th = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val outs = Array(ch) { FloatArray(BLOCK) }
            val scratch = Array(ch) { FloatArray(PREVIEW_CHUNK) }
            val inter = FloatArray(BLOCK * ch)
            var underruns = t.underrunCount
            var lastLatency = 0L
            while (!stopRender) {
                engine.render(outs, BLOCK)
                if (previewOn) {
                    // Cratebox USB's preview, added on top (preallocated buffers: nothing allocated here)
                    preview.render(scratch, BLOCK)
                    for (c in 0 until ch) { val o = outs[c]; val x = scratch[c]; for (k in 0 until BLOCK) o[k] += x[k] }
                }
                var j = 0
                for (k in 0 until BLOCK) for (c in 0 until ch) { inter[j++] = outs[c][k] }
                val w = t.write(inter, 0, inter.size, AudioTrack.WRITE_BLOCKING)
                if (w < 0) break
                framesWritten += w / ch
                // a glitch: give the output a little more room
                val u = t.underrunCount
                if (u != underruns) { underruns = u; runCatching { t.bufferSizeInFrames = min(t.bufferCapacityInFrames, t.bufferSizeInFrames + BLOCK) } }
                val now = System.nanoTime()
                if (now - lastLatency > 1_000_000_000L) { lastLatency = now; measureLatency(t) }
            }
        }, "cratebox-audio")
        thread = th
        th.start()
    }

    private val ts = AudioTimestamp()
    /** frames written but not yet heard, from the output's own timestamp; the buffer's length when there's none */
    private fun measureLatency(t: AudioTrack) {
        val sr = SAMPLE_RATE.toDouble()
        latency = if (t.getTimestamp(ts)) {
            val ahead = framesWritten - ts.framePosition
            val since = (System.nanoTime() - ts.nanoTime) / 1e9
            (ahead / sr - since).coerceIn(0.0, 0.6)
        } else (t.bufferSizeInFrames / sr).coerceIn(0.0, 0.6)
    }

    private fun stopTrack() {
        stopRender = true
        val t = track; track = null
        runCatching { t?.pause(); t?.flush() }
        thread?.join(500); thread = null
        runCatching { t?.stop(); t?.release() }
    }

    private fun currentOutputName(): String {
        val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val kinds = mutableSetOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        if (Build.VERSION.SDK_INT >= 31) { kinds.add(AudioDeviceInfo.TYPE_BLE_HEADSET); kinds.add(AudioDeviceInfo.TYPE_BLE_SPEAKER) }
        val routed = track?.routedDevice
        wireless = routed?.type in kinds
        return routed?.productName?.toString() ?: outs.firstOrNull()?.productName?.toString() ?: ""
    }

    private fun describe() {
        val t = track
        val d = t?.routedDevice
        diagnostics = if (t == null) "no output ($lastError)" else
            "${d?.productName ?: "?"} (type ${d?.type ?: -1}) · $outputChannels ch at ${t.sampleRate} Hz · buffer ${t.bufferSizeInFrames}/${t.bufferCapacityInFrames} frames · " +
                "device channels ${d?.channelCounts?.joinToString(",") ?: "?"}"
        routeName = currentOutputName()
    }

    /** headphones on a plain stereo output: mono master left, mono cue right (a splitter cable) */
    fun setSplit(on: Boolean) {
        prefs.edit().putBoolean("cb.split", on).apply()
        val m = if (on) OutputMode.SPLIT else outputMode(outputChannels)
        engine.post(EngineCommand.Output(m)); preview.post(EngineCommand.Output(m))
    }
    fun outputMode(ch: Int): OutputMode {
        if (ch >= 4) return if (routing == "swapped") OutputMode.QUAD_SWAPPED else OutputMode.QUAD
        return if (prefs.getBoolean("cb.split", false)) OutputMode.SPLIT else OutputMode.STEREO
    }
    fun setRouting(r: String) { prefs.edit().putString("cb.routing", r).apply(); restart() }
}
