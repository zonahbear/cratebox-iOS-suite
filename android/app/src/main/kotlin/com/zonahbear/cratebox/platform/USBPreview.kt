// Cratebox USB's player (USBPreview.swift on iOS): a full Cratebox deck (core Core on its own Engine, mixed into
// the output by AudioHost) so a stick's track plays, scratches and loops exactly like in Performance Mode, with
// rekordbox's grid, phrases, cues and colour waveform. The cue and grid tools are the deck's own; what they
// change is recorded as the track's staged edit instead of going into Performance Mode's library.
package com.zonahbear.cratebox.platform

import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import com.zonahbear.cratebox.core.Analysis
import com.zonahbear.cratebox.core.Core
import com.zonahbear.cratebox.core.CueSet
import com.zonahbear.cratebox.core.CueStore
import com.zonahbear.cratebox.core.DeckAnalysis
import com.zonahbear.cratebox.core.DeckModel
import com.zonahbear.cratebox.core.MemoryPrefs
import com.zonahbear.cratebox.core.Phrase
import com.zonahbear.cratebox.core.RekordboxANLZ
import com.zonahbear.cratebox.core.SmoothClock
import com.zonahbear.cratebox.core.StickFS
import com.zonahbear.cratebox.core.TrackInfo
import com.zonahbear.cratebox.core.USBMemoryCue
import com.zonahbear.cratebox.core.USBTrack
import com.zonahbear.cratebox.core.Waveform

/** the preview deck's cues go to the stick's staged edits */
class USBCueStore : CueStore {
    var session: USBSession? = null
    private val main = Handler(Looper.getMainLooper())
    override fun load(id: String): CueSet? {
        val e = session?.edits?.edits?.get(id) ?: return null
        if (e.cue == null && e.hot == null) return null
        return CueSet(e.cue, e.hot ?: List(8) { null })
    }
    override fun save(id: String, cue: Double?, hot: List<Double?>) {
        val h = hot.toList()
        main.post { session?.edit(id) { it.copy(cue = cue, hot = h) } }
    }
}

class USBPreview(private val audio: AudioHost, private val prefs: AndroidPrefs) {
    var session: USBSession? = null
        set(v) { field = v; cueStore.session = v }
    private val cueStore = USBCueStore()
    private val main = Handler(Looper.getMainLooper())
    val core = Core(audio.preview, MemoryPrefs(), cueStore)
    private val clock = SmoothClock(core) { audio.latency }
    private var active = false
    private var frame = 0
    var key: String? = null; private set              // the track on the deck
    var loadingKey: String? = null; private set
    var onFrame: (() -> Unit)? = null                 // the screen redraws the deck (every 3rd frame while loaded)
    val deck: DeckModel get() = core.decks[0]

    init {
        core.mixer.master = 0.8; core.mixerChanged()
        core.clock = { clock.now() }
        core.onMain = { main.post(it) }
        core.onStatus = { s, _ -> session?.message(s) }
        // the grid tools edit the track's grid: record it as the staged edit
        core.trackChanged = { t ->
            val k = key
            if (t.gridManual && k != null && t.id == k) session?.edit(k) { it.copy(bpm = t.bpm, firstBeat = t.firstBeat) }
        }
    }

    private val tick = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!active) return
            core.tick()
            frame++
            if (frame % 3 == 0 && deck.loaded) onFrame?.invoke()
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    fun setActive(on: Boolean) {
        if (on) {
            audio.previewOn = true
            if (!active) { active = true; Choreographer.getInstance().postFrameCallback(tick) }
        } else {
            if (deck.playing) deck.setPlaying(false)
            active = false
            // let the stop reach the engine before it's switched off
            main.postDelayed({ if (!active) audio.previewOn = false }, 100)
        }
    }

    fun unload() {
        if (deck.playing) deck.setPlaying(false)
        key = null
    }

    /** what rekordbox's analysis files say about a track: grid (beat by beat when it changes tempo), phrases,
     *  cues, memory cues and the colour waveform */
    class RBAnalysis {
        var bpm: Double? = null; var firstBeat: Double? = null; var beats: List<Double>? = null; var beat0 = 0
        var phrases: List<Phrase> = emptyList()
        var cue: Double? = null; var hot: List<Double?> = List(8) { null }
        var memory: List<USBMemoryCue> = emptyList()
        var wave: Waveform? = null
    }

    companion object {
        fun readAnalysis(fs: StickFS, t: USBTrack): RBAnalysis {
            val r = RBAnalysis()
            if (t.anlzPath.isEmpty()) return r
            val datRel = t.anlzPath.trimStart('/')
            val a = RekordboxANLZ.parse(fs.read(datRel) ?: ByteArray(0))
            val extRel = (if (datRel.substringAfterLast('/').contains('.')) datRel.substringBeforeLast('.') else datRel) + ".EXT"
            val extBytes = fs.read(extRel) ?: ByteArray(0)
            val ext = RekordboxANLZ.parse(extBytes).copy(beats = a.beats)
            RekordboxANLZ.grid(a.beats)?.let { r.bpm = it.bpm; r.firstBeat = it.firstBeat }
            if (a.beats.map { it.bpm }.toSet().size > 1) { r.beats = a.beats.map { it.ms / 1000.0 }; r.beat0 = a.beats.indexOfFirst { it.n == 1 }.coerceAtLeast(0) }
            r.phrases = RekordboxANLZ.phrases(ext) ?: emptyList()
            val src = if (ext.hot.isNotEmpty() || ext.memory.isNotEmpty()) ext else a
            val c = RekordboxANLZ.cues(src)
            r.cue = c.cue; r.hot = c.hot
            r.memory = src.memory.sortedBy { it.ms }.map { USBMemoryCue(it.ms / 1000.0, it.loopMs?.let { l -> l / 1000.0 }) }
            r.wave = RekordboxANLZ.waveform(extBytes, t.duration)
            return r
        }
    }

    fun load(t: USBTrack) {
        val s = session ?: return
        val fs = s.fs ?: return
        val d = deck
        if (d.playing) d.setPlaying(false)
        val info = TrackInfo(t.key, t.title, t.artist, bpm = if (t.bpm > 0) t.bpm else null, key = RekordboxANLZ.keyIndex(t.keyName), duration = t.duration)
        info.keyFromRekordbox = info.key >= 0
        val edit = s.edits.edits[t.key]
        d.beginLoad(info)
        loadingKey = t.key; key = t.key
        val range = prefs.bpmRange
        Thread({
            val rb = readAnalysis(fs, t)
            try {
                val uri = fs.documentUri(t.path.trimStart('/')) ?: throw AudioDecoder.Failure("the file isn't on the stick")
                val pcm = AudioDecoder.decode(s.context, uri)
                val m = AudioDecoder.mono(pcm, 11025.0)
                val dur = pcm.count / pcm.sampleRate
                val bpm = edit?.bpm ?: rb.bpm; val fb = edit?.firstBeat ?: rb.firstBeat
                val a: DeckAnalysis
                if (bpm != null && fb != null) {
                    val wave = rb.wave ?: AudioDecoder.mono(pcm, 22050.0).let { Analysis.waveform(it.first, it.second) }
                    a = DeckAnalysis(bpm, fb, if (info.key >= 0) info.key else Analysis.detectKey(m.first, m.second).key,
                        rb.phrases.ifEmpty { Analysis.phraseAnalysis(m.first, m.second, bpm, fb) }, wave, dur)
                    val beats = rb.beats
                    if (edit?.bpm == null && edit?.firstBeat == null && beats != null && beats.size >= 2) { a.beats = beats.toDoubleArray(); a.beat0 = rb.beat0 }
                    info.rbGrid = rb.bpm != null
                } else {
                    // not analysed by rekordbox: Cratebox's own analysis, so the grid tools have something to work on
                    val w = AudioDecoder.mono(pcm, 22050.0)
                    val r = Analysis.analyze(m.first, m.second, range, w)
                    a = DeckAnalysis(r.bpm, r.firstBeat, if (info.key >= 0) info.key else r.key, r.phrases, rb.wave ?: r.wave, dur)
                }
                info.autoBpm = rb.bpm ?: a.bpm; info.autoFirst = rb.firstBeat ?: a.firstBeat
                info.rbCues = CueSet(rb.cue, rb.hot)
                val memory = rb.memory
                main.post {
                    d.finishLoad(info, pcm, a, m)
                    // the memory cues start as rekordbox's, unless you've edited them
                    if (s.edits.edits[t.key]?.memory == null && memory.isNotEmpty()) s.edits.rbMemory[t.key] = memory
                    if (loadingKey == t.key) loadingKey = null
                    s.changed()
                }
            } catch (e: Throwable) {
                // OutOfMemoryError included: a very long file shouldn't take the app down
                main.post { d.failLoad(info, e.message ?: e.toString()); if (loadingKey == t.key) loadingKey = null; s.changed() }
            }
        }, "cratebox-usb-load").start()
    }
}
