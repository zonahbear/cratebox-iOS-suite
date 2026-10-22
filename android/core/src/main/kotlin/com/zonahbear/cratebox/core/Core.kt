package com.zonahbear.cratebox.core

import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min

// The app's brain: decks (cue, hot cues, loops, beat jump, sync and beat lock, grid editing, tempo), the
// mixer and Beat FX / Pad FX state, on top of the audio engine. A port of CrateboxKit Core.swift (itself the
// web app's Deck class and the mixer/FX functions around it, cratebox.html), kept close to the original so
// they behave alike. UI-free and not observable: the app redraws from it every frame (it calls tick() ~60
// times a second anyway), the controller drives it, the tests run it offline. Call it from one thread.

val RANGES = doubleArrayOf(6.0, 10.0, 16.0, 100.0)
val LOOP_SIZES = doubleArrayOf(0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0)
val JUMPS = doubleArrayOf(-1.0, 1.0, -2.0, 2.0, -4.0, 4.0, -8.0, 8.0)
internal fun clamp(v: Double, a: Double, b: Double) = min(b, max(a, v))
/** "%.2f" etc. with a dot whatever the phone's language */
internal fun fmt(f: String, vararg a: Any?) = String.format(Locale.US, f, *a)

/** Saved cue points: CUE and hot cues A-H */
data class CueSet(val cue: Double?, val hot: List<Double?>)

/** What the decks need to know about a track */
class TrackInfo(
    val id: String, var title: String, var artist: String = "", var bpm: Double? = null, var firstBeat: Double? = null,
    var key: Int = -1, var duration: Double = 0.0, var phrases: List<Phrase> = emptyList(),
) {
    var gridManual = false
    var autoBpm: Double? = null
    var autoFirst: Double? = null
    var keyFromRekordbox = false
    var rbCues: CueSet? = null
    /** rekordbox's own beat grid, beat by beat (seconds), and which beat is bar 1's first */
    var rbBeats: List<Double>? = null
    var rbBeat0 = 0
    var rbGrid = false            // the grid came from rekordbox
}

/** A deck's analysis (the web app's `ana`) */
data class DeckAnalysis(
    var bpm: Double, var firstBeat: Double, var key: Int, var phrases: List<Phrase>, var wave: Waveform?, var duration: Double,
    /** a beat-by-beat grid (rekordbox's): followed exactly instead of bpm + firstBeat, so a track whose
     *  tempo isn't a perfectly even number (or changes) stays locked. beat0: the index of bar 1's first beat */
    var beats: DoubleArray? = null, var beat0: Int = 0,
)

/** Saved cue points per track (CUE and hot cues A-H) */
interface CueStore {
    fun load(id: String): CueSet?
    fun save(id: String, cue: Double?, hot: List<Double?>)
}
class MemoryCueStore : CueStore {
    private val m = HashMap<String, CueSet>()
    override fun load(id: String) = m[id]
    override fun save(id: String, cue: Double?, hot: List<Double?>) { m[id] = CueSet(cue, hot.toList()) }
}

data class Loop(var on: Boolean = false, var a: Double? = null, var b: Double? = null)
enum class PadMode(val raw: String) { HOTCUE("hotcue"), BEATLOOP("beatloop"), BEATJUMP("beatjump"), PADFX("padfx"), PADFX2("padfx2") }

class DeckModel internal constructor(val i: Int, private val core: Core) {
    var track: TrackInfo? = null; private set
    var ana: DeckAnalysis? = null; private set
    var loading = false; private set
    var duration = 0.0; private set
    internal var sr = 44100.0
    // position: from the engine's reports, moved on by the clock in between
    internal var pos = 0.0
    internal var posT = 0.0
    internal var speed = 0.0
    var playing = false; private set
    var pitch = 0.0; private set          // -1...1 from the tempo fader (top = negative, Pioneer style)
    var rangeIdx = 0; private set
    var sync = false; private set
    internal var syncSince = 0.0
    internal var syncRate = 1.0
    var syncMult = 1.0; private set
    var syncTrim = 0.0; internal set
    var phaseErr: Double? = null; private set
    var cue = 0.0; private set
    val hot: Array<Double?> = arrayOfNulls(8)
    var loop = Loop(); private set
    var quant = true
    var padMode = PadMode.HOTCUE
    var previewing = false; private set
    var touch = false; private set
    private var loopInDown = 0.0
    private var sentRate: Double? = null
    internal var coasting = false
    private var coastHold = 0.0
    var startedAt = 0.0; private set
    var mt = core.prefs.bool("cb.mt$i", true); private set
    private var seekSeq = 0
    private var syncWith: DeckModel? = null
    private val taps = ArrayList<Double>()
    /** the analysis audio, kept to redo the phrases after a grid edit */
    var mono: Pair<FloatArray, Double>? = null

    private fun post(m: DeckMessage) = core.engine.post(EngineCommand.Deck(i, m))
    val loaded: Boolean get() = track != null && !loading && duration > 0
    val range: Double get() = RANGES[rangeIdx]
    val bpm: Double get() = ana?.bpm ?: 0.0
    /** seconds per beat where the playhead is (a beat-by-beat grid's tempo varies along the track) */
    val spb: Double get() { grid?.let { return windowSpb(it, now()) }; return if (bpm > 0) 60 / bpm else 0.5 }
    /** seconds per beat over the 16 beats around t. rekordbox stores beat times in whole milliseconds, so one
     *  beat at 140 BPM is 428 or 429 ms (140.19 / 139.86 BPM): tempo comes from the span, not single beats */
    private fun windowSpb(b: DoubleArray, t: Double): Double {
        val i = seg(b, t); val lo = max(0, i - 8); val hi = min(b.size - 1, i + 9)
        return max(0.05, (b[hi] - b[lo]) / (hi - lo))
    }
    /** the tempo at the playhead, from the grid */
    fun tempoNow(): Double { grid?.let { return 60 / windowSpb(it, now()) }; return bpm }
    private val grid: DoubleArray? get() = ana?.beats?.takeIf { it.size >= 2 }
    /** index of the beat segment holding t */
    private fun seg(b: DoubleArray, t: Double): Int {
        if (t <= b[0]) return 0
        if (t >= b[b.size - 1]) return b.size - 2
        var lo = 0; var hi = b.size - 1
        while (hi - lo > 1) { val m = (lo + hi) / 2; if (b[m] <= t) lo = m else hi = m }
        return lo
    }
    private val active: Boolean get() = core.deckActive(i)

    fun setMT(on: Boolean) {
        mt = on; core.prefs.set("cb.mt$i", on)
        post(DeckMessage.Mt(on))
        core.status("Deck ${i + 1}: master tempo ${if (on) "on (tempo changes keep the key)" else "off (vinyl: tempo changes the pitch)"}")
    }

    // ---- beat grid editing: every edit keeps the beat under the playhead, and firstBeat on a bar line ----
    fun setGrid(bpm: Double, firstBeat0: Double, why: String? = null) {
        val a = ana ?: return
        if (!(bpm > 20 && bpm < 400)) return
        track?.let { if (!it.gridManual) { it.autoBpm = a.bpm; it.autoFirst = a.firstBeat } }
        val bar = 4 * 60 / bpm
        val firstBeat = firstBeat0 - jsFloor(firstBeat0 / bar) * bar
        ana = a.copy(bpm = bpm, firstBeat = firstBeat, beats = null)
        track?.let { it.bpm = bpm; it.firstBeat = firstBeat; it.gridManual = true; core.trackChanged(it) }
        rephrase()
        if (sync) syncTick()
        for (d in core.decks) if (d !== this && d.sync) d.syncTick()
        sentRate = null; sendRate()
        if (why != null) core.status("Deck ${i + 1} grid: $why · ${fmt("%.2f", bpm)} BPM")
    }
    fun setBpm(b: Double, why: String? = null) {
        if (ana == null) return
        val bpm = jsRound(b * 1000) / 1000
        val t = now(); val beat = beatAt(t)
        setGrid(bpm, t - beat * (60 / bpm), why ?: "BPM set")
    }
    fun nudgeGrid(sec: Double) { ana?.let { setGrid(it.bpm, it.firstBeat + sec, "moved ${if (sec > 0) "later" else "earlier"} ${jsRound(abs(sec * 1000)).toInt()} ms") } }
    fun downbeatHere() { ana?.let { setGrid(it.bpm, now(), "bar 1 set at the playhead") } }
    fun beatHere() {
        val a = ana ?: return
        val t = now(); val b = jsRound(beatAt(t))
        setGrid(a.bpm, t - b * spb, "beat set at the playhead")
    }
    fun tap() {
        val nowMs = core.wallMs()
        if (taps.isEmpty() || nowMs - taps[taps.size - 1] > 2000) taps.clear()
        taps.add(nowMs)
        if (taps.size > 16) taps.removeAt(0)
        val n = taps.size.toDouble()
        if (taps.size < 4) { core.status("Tap ${taps.size}… keep tapping on the beat"); return }
        var sx = 0.0; var sy = 0.0; var sxx = 0.0; var sxy = 0.0
        for ((x, y) in taps.withIndex()) { val xd = x.toDouble(); sx += xd; sy += y; sxx += xd * xd; sxy += xd * y }
        val ms = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        setBpm(jsRound(60000 / ms * 100) / 100, "tapped (${taps.size} taps)")
    }
    private var rephraseCancel: (() -> Unit)? = null
    internal fun rephrase() {
        rephraseCancel?.invoke()
        val m = mono ?: return
        val a = ana ?: return
        val t = track; val bpm = a.bpm; val fb = a.firstBeat
        rephraseCancel = core.background(0.5) {
            val ph = Analysis.phraseAnalysis(m.first, m.second, bpm, fb)
            core.onMain {
                val cur = ana
                if (cur != null && cur.bpm == bpm && cur.firstBeat == fb) {
                    ana = cur.copy(phrases = ph)
                    t?.let { it.phrases = ph; core.trackChanged(it) }
                }
            }
        }
    }
    fun resetGrid() {
        val t = track ?: return
        val a = ana ?: return
        val ab = t.autoBpm; val af = t.autoFirst
        if (ab != null && af != null) { ana = a.copy(bpm = ab, firstBeat = af); t.bpm = ab; t.firstBeat = af }
        t.gridManual = false
        core.trackChanged(t)
        if (t.autoBpm == null) core.reanalyse(t)
        rephrase()
        core.status("Deck ${i + 1}: grid back to the analysis")
    }

    // ---- tempo ----
    fun master(): DeckModel? {
        // the deck to follow when synced. Two decks: the other one, unless it synced after us (then we lead).
        // Four decks: prefer one that isn't synced itself, then one that's playing, then the one playing longest.
        val c = core.decks.filter { o -> o !== this && core.deckActive(o.i) && o.loaded && o.bpm > 0 && !(o.sync && sync && o.syncSince > syncSince) }
        if (c.isEmpty()) return null
        fun score(o: DeckModel) = (if (o.sync) 0 else 4) + (if (o.playing) 2 else 0)
        return c.sortedWith { a, b ->
            if (score(a) != score(b)) return@sortedWith score(b) - score(a)
            val sa = if (a.startedAt > 0) a.startedAt else Double.POSITIVE_INFINITY
            val sb = if (b.startedAt > 0) b.startedAt else Double.POSITIVE_INFINITY
            if (sa != sb) return@sortedWith sa.compareTo(sb)
            a.i - b.i
        }[0]
    }
    fun rate(): Double {
        if (sync && master() != null && bpm > 0) return syncRate * (1 + syncTrim)
        return 1 + pitch * range / 100
    }
    fun effBpm(): Double = tempoNow() * rate() / (if (sync) 1 + syncTrim else 1.0)
    /** with master tempo off, speeding up raises the key: 6% is about a semitone */
    fun keyNow(): Int {
        val a = ana ?: return -1
        if (a.key < 0) return -1
        return if (mt) a.key else Keys.shift(a.key, jsRound(12 * log2(rate())).toInt())
    }
    internal fun onReport(d: DeckReport, time: Double) {
        if (d.seq < seekSeq) return          // a report from before our latest seek would undo it
        pos = d.pos; posT = time; speed = d.speed
        if (core.wallMs() > coastHold) coasting = d.coast
        if (playing && !d.playing && d.ended) playing = false
    }
    fun now(): Double {
        val t = pos / sr + (core.clock() - posT) * speed
        return clamp(t, 0.0, duration)
    }
    fun beatAt(t: Double): Double {
        val b = grid; val a = ana
        if (b != null && a != null) {
            val i = seg(b, t)
            return i + (t - b[i]) / max(0.05, b[i + 1] - b[i]) - a.beat0
        }
        return a?.let { (t - it.firstBeat) / (if (bpm > 0) 60 / bpm else 0.5) } ?: 0.0
    }
    fun timeOfBeat(x: Double): Double {
        val b = grid; val a = ana
        if (b != null && a != null) {
            val j = x + a.beat0; val n = b.size
            val i = max(0.0, min((n - 2).toDouble(), floor(j))).toInt()
            return b[i] + (j - i) * (b[i + 1] - b[i])
        }
        return a?.let { it.firstBeat + x * (if (bpm > 0) 60 / bpm else 0.5) } ?: 0.0
    }
    fun snap(t: Double): Double = if (quant && ana != null) timeOfBeat(jsRound(beatAt(t))) else t
    private fun sendRate() { val r = rate(); if (r != sentRate) { sentRate = r; post(DeckMessage.Rate(r)) } }

    // ---- loading: the app decodes and analyses, then hands the deck the result ----
    fun canLoad(): String? {
        if (!active) return "Deck ${i + 1} is hidden: turn on 4 DECKS first"
        if (playing && core.loadLock) return "Deck ${i + 1} is playing. Stop it before loading (or Settings → Load lock: Unlocked)."
        return null
    }
    fun beginLoad(t: TrackInfo) {
        if (playing) { previewing = false; setPlaying(false) }
        loading = true; track = t; ana = null; mono = null
        core.engine.post(listOf(EngineCommand.Deck(i, DeckMessage.Unload), EngineCommand.Track(i, null)))
    }
    fun failLoad(t: TrackInfo, err: String) {
        if (track !== t) return
        loading = false; track = null; ana = null; duration = 0.0
        core.status("Couldn't load that file: $err", 8.0)
    }
    fun finishLoad(t: TrackInfo, pcm: PCMTrack, a: DeckAnalysis, mono: Pair<FloatArray, Double>?) {
        if (track !== t) return
        sr = pcm.sampleRate; duration = pcm.count / pcm.sampleRate
        core.engine.post(listOf(EngineCommand.Track(i, pcm), EngineCommand.Deck(i, DeckMessage.Load(mt, core.spinSecs))))
        pos = 0.0; posT = core.clock(); speed = 0.0
        loop = Loop(); previewing = false
        this.mono = mono
        ana = a
        if (a.phrases.isEmpty()) rephrase()
        t.bpm = a.bpm; t.duration = duration; t.firstBeat = a.firstBeat; t.key = a.key; t.phrases = a.phrases
        core.trackChanged(t)
        val stored = core.cues.load(t.id)
        val saved = stored ?: t.rbCues ?: CueSet(null, List(8) { null })
        for (k in 0 until 8) hot[k] = saved.hot.getOrNull(k)
        cue = saved.cue ?: a.firstBeat
        seek(cue)
        sentRate = null; sendRate()
        loading = false
        core.status("Deck ${i + 1}: ${t.title} · ${fmt("%.2f", a.bpm)} BPM")
    }

    // jump somewhere: with Q on while playing, land on the same beat phase so a mix stays locked
    fun seekTo(t0: Double) {
        if (!loaded) return
        var t = t0
        if (playing && quant && bpm > 0) { val n = now(); t = n + jsRound((t - n) / spb) * spb }
        seek(t)
    }
    fun seek(t0: Double) {
        if (!loaded && duration == 0.0) return
        val t = clamp(t0, 0.0, max(0.0, duration - 0.01))
        seekSeq += 1
        post(DeckMessage.Seek(t * sr, seekSeq))
        pos = t * sr; posT = core.clock()
    }
    fun setPlaying(on: Boolean) {
        if (!loaded) return
        if (on && sync) master()?.let { if (it.playing) alignPhase() }
        if (on && !playing) { startedAt = core.wallMs(); core.playStarted() }
        playing = on
        previewing = false
        sendRate()
        post(DeckMessage.Play(on))
        speed = if (on) rate() else 0.0
        posT = core.clock()
    }
    fun togglePlay() = setPlaying(!playing)

    // CDJ-style CUE: while playing, back to the cue point and stop; while stopped, set it, or if already
    // on it, play for as long as it's held.
    fun cueDown() {
        if (!loaded) return
        if (playing) { setPlaying(false); seek(cue) }
        else if (abs(now() - cue) < 0.02) {
            previewing = true; playing = true
            sendRate(); post(DeckMessage.Play(true)); speed = rate()
        } else {
            cue = snap(now()); seek(cue); saveCues()
        }
    }
    fun cueUp() {
        if (previewing) { previewing = false; playing = false; post(DeckMessage.Play(false)); seek(cue) }
    }

    // ---- sync ----
    companion object {
        internal fun pickMult(r: Double): Double =
            doubleArrayOf(0.5, 1.0, 2.0).fold(1.0) { best, k -> if (abs(ln(r * k)) < abs(ln(r * best))) k else best }
    }
    fun setSync(on: Boolean) {
        if (on && (!loaded || bpm == 0.0)) return
        sync = on
        if (on) {
            syncSince = core.wallMs()
            val m = master()
            syncWith = m
            if (m != null) {
                // halftime / double time: of 1/2x, 1x and 2x the master's tempo, take the one nearest our own
                val r = m.effBpm() / tempoNow()
                syncMult = pickMult(r)
                syncRate = clamp(r * syncMult, 0.5, 2.0)
                syncTrim = 0.0
                sendRate()
                if (playing && m.playing) alignPhase()
                if (syncMult != 1.0) core.status("Deck ${i + 1} synced at ${if (syncMult < 1) "half" else "double"} time: ${fmt("%.2f", bpm * syncRate)} against ${fmt("%.2f", m.effBpm())}")
            } else core.status("Load a track on the other deck to sync to")
        } else { syncTrim = 0.0; phaseErr = null }
        sendRate()
    }
    private fun alignPhase() {
        val m = master() ?: return
        if (!(m.bpm > 0 && bpm > 0)) return
        val mb = m.beatAt(m.now()) * syncMult
        val frac = mb - jsFloor(mb)
        val myB = beatAt(now())
        var target = jsFloor(myB) + frac
        if (target - myB > 0.5) target -= 1
        if (myB - target > 0.5) target += 1
        seek(timeOfBeat(target))
    }
    internal fun syncTick() {
        if (!sync) return
        val m = master() ?: return
        if (!(bpm > 0)) return
        syncWith?.let { if (it !== m) syncMult = pickMult(m.effBpm() / tempoNow()) }
        syncWith = m
        val r = clamp(m.effBpm() * syncMult / tempoNow(), 0.5, 2.0)
        if (abs(r - syncRate) > 1e-7) { syncRate = r; sendRate() }
        lockPhase(m)
    }
    // Beat lock: while both decks play, measure how far our beats are from the master's and correct with a
    // tiny speed change. A deliberate offset of more than a quarter beat is left alone.
    private fun lockPhase(m: DeckModel) {
        val live = playing && m.playing && !touch && !m.touch && !coasting && !m.coasting && !previewing && loaded && m.loaded
        if (!live) { if (syncTrim != 0.0) { syncTrim = 0.0; sendRate() }; phaseErr = null; return }
        var err = beatAt(now()) - m.beatAt(m.now()) * syncMult
        err -= jsRound(err)
        val errSec = err * spb / max(0.05, rate())
        phaseErr = errSec
        var want = 0.0
        if (abs(err) < 0.25 && abs(errSec) > 0.0015) want = clamp(-errSec / 1.5, -0.006, 0.006)
        val trim = syncTrim + (want - syncTrim) * 0.2
        if (abs(trim - syncTrim) > 1e-6 || (want == 0.0 && syncTrim != 0.0)) { syncTrim = if (abs(trim) < 1e-5) 0.0 else trim; sendRate() }
    }
    fun cycleRange() {
        rangeIdx = (rangeIdx + 1) % RANGES.size
        sendRate()
        core.status("Deck ${i + 1} tempo range ±${if (range == 100.0) "WIDE" else "${range.toInt()}%"}")
    }
    fun setPitch(v: Double) { pitch = clamp(v, -1.0, 1.0); sendRate() }

    // ---- jog ----
    fun jogTouch(on: Boolean, noCoast: Boolean = false) {
        if (!loaded) return
        touch = on
        if (!on && !noCoast) { coasting = true; coastHold = core.wallMs() + 120 } else coasting = false
        post(DeckMessage.Scratch(on, noCoast))
    }
    enum class JogKind { SCRATCH, BEND, SEARCH }
    fun jogTicks(t0: Double, kind: JogKind, raw: Boolean = false) {
        if (!loaded) return
        val ticks = if (raw) t0 else t0 * core.jogSens
        val tickSec = 1.8 / 720                 // 33 1/3 RPM platter, 720 ticks per turn
        if (kind == JogKind.SCRATCH && touch) post(DeckMessage.Jog(ticks * tickSec * sr))
        else if (coasting) return
        else if (kind == JogKind.SEARCH) seek(now() + ticks * 0.08)
        else if (playing) post(DeckMessage.Bend(ticks * 0.004))
        else seek(now() + ticks * tickSec)
    }

    // ---- loops ----
    private fun sendLoop() {
        val on = loop.on && loop.a != null && loop.b != null
        post(DeckMessage.Loop(on, (loop.a ?: 0.0) * sr, (loop.b ?: 0.0) * sr))
    }
    fun loopIn() { if (!loaded) return; loop = Loop(false, snap(now()), null); sendLoop() }
    fun loopOut() {
        if (!loaded) return
        val a = loop.a ?: return
        val b = snap(now())
        if (b <= a + 0.01) return
        loop.b = b; loop.on = true; sendLoop()
    }
    fun reloopExit() {
        val a = loop.a ?: return
        val b = loop.b ?: return
        if (loop.on) { loop.on = false; sendLoop() }
        else { loop.on = true; sendLoop(); val n = now(); if (n > b || n < a) seek(a) }
    }
    fun beatLoop(beats: Double) {
        if (!loaded) return
        val len = beats * spb
        val la = loop.a; val lb = loop.b
        if (loop.on && la != null && lb != null && abs((lb - la) - len) < 0.002) { loop.on = false; sendLoop(); return }
        val t = now()
        val a = if (quant && ana != null) timeOfBeat(jsFloor(beatAt(t) + 1e-6)) else t
        loop = Loop(true, a, a + len)
        sendLoop()
    }
    fun loopScale(f: Double) {
        val a = loop.a ?: return
        val b = loop.b ?: return
        val len = (b - a) * f
        if (len < spb / 32 || len > spb * 512) return
        loop.b = a + len
        sendLoop()
    }
    fun loopBeats(): Double { val a = loop.a; val b = loop.b; return if (a != null && b != null) (b - a) / spb else 0.0 }
    fun beatJump(beats: Double) {
        if (!loaded) return
        val d = beats * spb
        val a = loop.a; val b = loop.b
        if (loop.on && a != null && b != null) { loop.a = a + d; loop.b = b + d; sendLoop() }
        seek(now() + d)
    }
    // hold LOOP IN for half a second: 4-beat loop
    fun loopInPress(on: Boolean) {
        if (on) { loopInDown = core.wallMs(); loopIn() }
        else if (loopInDown > 0 && core.wallMs() - loopInDown > 500) beatLoop(4.0)
    }

    // ---- hot cues ----
    fun hotcue(k: Int) {
        if (!loaded) return
        val h = hot[k]
        if (h != null) { seek(h); if (!playing) cue = h }
        else { hot[k] = snap(now()); saveCues() }
    }
    fun clearHot(k: Int) { hot[k] = null; saveCues() }
    fun callCue(dir: Int) {
        if (loop.on) { loopScale(if (dir > 0) 2.0 else 0.5); return }
        val t = now()
        val cues = hot.filterNotNull().sorted()
        val next = if (dir > 0) cues.firstOrNull { it > t + 0.05 } else cues.reversed().firstOrNull { it < t - 0.05 }
        if (next != null) { seek(next); if (!playing) cue = next }
    }
    private fun saveCues() { track?.let { core.cues.save(it.id, cue, hot.toList()) } }
    fun padPress(p: Int, shift: Boolean = false) {
        when (padMode) {
            PadMode.PADFX, PadMode.PADFX2 -> core.fx.padDown(i, padMode, p)
            PadMode.HOTCUE -> if (shift) clearHot(p) else hotcue(p)
            PadMode.BEATLOOP -> beatLoop(LOOP_SIZES[p])
            PadMode.BEATJUMP -> beatJump(JUMPS[p])
        }
    }
    fun padRelease(p: Int) { if (padMode == PadMode.PADFX || padMode == PadMode.PADFX2) core.fx.padUp(i, padMode, p) }
}

/** Settings and small state kept between launches */
interface Prefs {
    fun bool(k: String, d: Boolean): Boolean
    fun double(k: String, d: Double): Double
    fun string(k: String, d: String): String
    fun set(k: String, v: Any?)
}
class MemoryPrefs : Prefs {
    private val m = HashMap<String, Any?>()
    override fun bool(k: String, d: Boolean) = m[k] as? Boolean ?: d
    override fun double(k: String, d: Double) = (m[k] as? Number)?.toDouble() ?: d
    override fun string(k: String, d: String) = m[k] as? String ?: d
    override fun set(k: String, v: Any?) { m[k] = v }
}

class Core(val engine: Engine, val prefs: Prefs = MemoryPrefs(), val cues: CueStore = MemoryCueStore()) {
    val decks: List<DeckModel>
    val fx: FxController by lazy { FxController(this) }
    /** the audio clock now (seconds): the app works it out from the last report and the host clock */
    var clock: () -> Double = { 0.0 }
    var wallMs: () -> Double = { hostSeconds() * 1000 }
    var onStatus: (String, Double) -> Unit = { _, _ -> }
    var trackChanged: (TrackInfo) -> Unit = {}
    var reanalyse: (TrackInfo) -> Unit = {}
    var playStarted: () -> Unit = {}
    /** run work off the main thread after `delay` seconds; returns a cancel */
    var background: (Double, () -> Unit) -> (() -> Unit) = { delay, work ->
        val f = bgPool.schedule(work, (delay * 1000).toLong(), TimeUnit.MILLISECONDS)
        ({ f.cancel(false); Unit })
    }
    /** back onto the thread that drives Core (the app sets its main looper) */
    var onMain: (() -> Unit) -> Unit = { it() }
    /** the mixer; after changing it directly, call mixerChanged() so the engine hears */
    val mixer = MixerState()
    var four: Boolean = prefs.bool("cb.four", false); private set
    var loadLock: Boolean = prefs.bool("cb.loadLock", true)
        set(v) { field = v; prefs.set("cb.loadLock", v) }
    var jogSens: Double = prefs.double("cb.jogSens", 1.0)
        set(v) { field = v; prefs.set("cb.jogSens", v) }
    var spinSecs: Double = prefs.double("cb.spin", 2.5)
        set(v) { field = v; prefs.set("cb.spin", v); engine.post(decks.indices.map { EngineCommand.Deck(it, DeckMessage.Spin(v)) }) }
    var lastSnapshot = EngineSnapshot(); private set

    init {
        decks = List(4) { DeckModel(it, this) }
        mixer.active[2] = four; mixer.active[3] = four
        mixerChanged()
        for (d in decks) engine.post(EngineCommand.Deck(d.i, DeckMessage.Mt(d.mt)))
    }
    fun mixerChanged() = engine.post(EngineCommand.Mixer(mixer.deepCopy()))
    fun status(s: String, secs: Double = 4.0) = onStatus(s, secs)
    fun deckActive(i: Int): Boolean = i < 2 || four
    fun setFour(on: Boolean) {
        four = on; prefs.set("cb.four", on)
        mixer.active[2] = on; mixer.active[3] = on; mixerChanged()
        if (!on) for (d in decks.drop(2)) if (d.playing) d.setPlaying(false)
    }

    /** Call often (the app does ~60 times a second): reads the engine's reports, keeps sync locked and the FX clocks fresh. */
    fun tick() {
        val s = engine.snapshot()
        for ((k, d) in decks.withIndex()) d.onReport(s.decks[k], s.time)
        for (d in decks) if (d.sync) d.syncTick()
        fx.clockTick()
        lastSnapshot = s
    }

    // ---- mixer controls (the controller and the screen both come here) ----
    fun setMixer(name: String, deck: Int, v: Double) {
        when (name) {
            "fader" -> mixer.fader[deck] = v
            "trim" -> mixer.trim[deck] = v
            "hi" -> mixer.hi[deck] = v
            "mid" -> mixer.mid[deck] = v
            "low" -> mixer.low[deck] = v
            "cfx" -> mixer.cfx[deck] = v
            "xfader" -> mixer.xfader = v
            "headMix" -> mixer.headMix = v
            "master" -> mixer.master = v
            else -> return
        }
        mixerChanged()
    }
    fun mixerValue(name: String, deck: Int): Double? = when (name) {
        "fader" -> mixer.fader[deck]
        "trim" -> mixer.trim[deck]
        "hi" -> mixer.hi[deck]
        "mid" -> mixer.mid[deck]
        "low" -> mixer.low[deck]
        "cfx" -> mixer.cfx[deck]
        "tempo" -> (decks[deck].pitch + 1) / 2
        else -> null
    }
    fun togglePfl(deck: Int) { mixer.pfl[deck] = !mixer.pfl[deck]; mixerChanged() }
    fun toggleMasterCue() { mixer.masterCue = !mixer.masterCue; mixerChanged() }

    private companion object {
        val bgPool = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "cratebox-analysis").apply { isDaemon = true } }
    }
}

// ---- Beat FX / Pad FX state (the effects themselves run in the engine's FxUnits) ----
class FxSpec(val beats: DoubleArray?, val beat: Double, val depth: Double)
private val BEAT_SET_ECHO = doubleArrayOf(1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 3.0 / 4, 1.0, 2.0, 4.0)
val FX_LIST: List<Pair<FxKind, FxSpec>> = listOf(
    FxKind.ECHO to FxSpec(BEAT_SET_ECHO, 0.5, 0.55),
    FxKind.DELAY to FxSpec(BEAT_SET_ECHO, 0.75, 0.6),
    FxKind.PING_PONG to FxSpec(BEAT_SET_ECHO, 0.5, 0.6),
    FxKind.REVERB to FxSpec(null, 1.0, 0.55),
    FxKind.FLANGER to FxSpec(doubleArrayOf(1.0, 2.0, 4.0, 8.0, 16.0, 32.0), 16.0, 0.8),
    FxKind.FILTER to FxSpec(doubleArrayOf(1.0, 2.0, 4.0, 8.0, 16.0, 32.0), 4.0, 0.7),
    FxKind.TRANS to FxSpec(doubleArrayOf(1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1.0, 2.0), 0.25, 1.0),
    FxKind.ROLL to FxSpec(doubleArrayOf(1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1.0, 2.0, 4.0), 0.5, 1.0),
    FxKind.HPF to FxSpec(null, 1.0, 0.6),
    FxKind.LPF to FxSpec(null, 1.0, 0.6),
)
data class PadFx(val fx: FxKind, val beats: Double, val depth: Double)
val PAD_FX: Map<PadMode, List<PadFx>> = mapOf(
    PadMode.PADFX to listOf(PadFx(FxKind.ECHO, 0.5, 0.6), PadFx(FxKind.ECHO, 1.0, 0.6), PadFx(FxKind.REVERB, 1.0, 0.7), PadFx(FxKind.ROLL, 0.25, 1.0),
        PadFx(FxKind.ROLL, 0.5, 1.0), PadFx(FxKind.TRANS, 0.25, 1.0), PadFx(FxKind.HPF, 1.0, 0.7), PadFx(FxKind.LPF, 1.0, 0.7)),
    PadMode.PADFX2 to listOf(PadFx(FxKind.PING_PONG, 0.5, 0.6), PadFx(FxKind.DELAY, 0.75, 0.6), PadFx(FxKind.FLANGER, 16.0, 0.8), PadFx(FxKind.ROLL, 0.125, 1.0),
        PadFx(FxKind.ROLL, 1.0, 1.0), PadFx(FxKind.TRANS, 0.125, 1.0), PadFx(FxKind.FILTER, 4.0, 0.8), PadFx(FxKind.ECHO, 0.25, 0.7)),
)
fun fracText(b: Double): String =
    if (b >= 1) (if (b == floor(b)) b.toInt().toString() else b.toString()) else if (b == 0.75) "3/4" else "1/${jsRound(1 / b).toInt()}"

class FxController internal constructor(private val core: Core) {
    /** the BEAT FX unit: effect, BEAT per effect, depth, on, channel (0-3, or 4 = MASTER) */
    var fx = FxKind.ECHO; private set
    val beats = HashMap<FxKind, Double>()
    var depth = 0.55; private set
    var on = false; private set
    var ch = 0; private set
    data class PadHeld(val p: Int, val bank: PadMode)
    val pad: Array<PadHeld?> = arrayOfNulls(4)
    private val lastActive = HashMap<Int, Double>()
    private var lastClock = 0.0

    init {
        for ((k, s) in FX_LIST) beats[k] = s.beat
        val p = core.prefs
        FxKind.of(p.string("cb.bfx.fx", "ECHO"))?.let { if (it != FxKind.NONE) fx = it }
        depth = p.double("cb.bfx.depth", depth)
        ch = p.double("cb.bfx.ch", 0.0).toInt()
        for ((k, _) in FX_LIST) { val v = p.double("cb.bfx.beat.${k.raw}", -1.0); if (v > 0) beats[k] = v }
    }
    private fun save() {
        val p = core.prefs
        p.set("cb.bfx.fx", fx.raw); p.set("cb.bfx.depth", depth); p.set("cb.bfx.ch", ch.toDouble())
        for ((k, v) in beats) p.set("cb.bfx.beat.${k.raw}", v)
    }
    val spec: FxSpec get() = FX_LIST.first { it.first == fx }.second
    val beat: Double get() = beats[fx] ?: spec.beat
    // the beat clock for an insert: its deck's (master: the deck the mix follows)
    private fun clockDeck(u: Int): DeckModel {
        if (u < 4) return core.decks[u]
        core.decks.firstOrNull { core.deckActive(it.i) && it.sync && it.master() != null }?.master()?.let { return it }
        val loud = core.decks.filter { core.deckActive(it.i) && it.playing && it.loaded }.sortedByDescending { core.mixer.fader[it.i] }
        return loud.firstOrNull() ?: core.decks.firstOrNull { it.loaded } ?: core.decks[0]
    }
    private fun sendClock(u: Int) {
        val d = clockDeck(u)
        val bpm = if (d.bpm > 0) d.effBpm() else 120.0
        val playing = d.playing && d.loaded
        core.engine.post(EngineCommand.Clock(u, FxClock(core.clock(), if (d.bpm > 0) d.beatAt(d.now()) else 0.0, if (playing) bpm / 60 else 0.0, 60 / bpm)))
    }
    internal fun clockTick() {
        val now = core.wallMs()
        if (now - lastClock < 100) return
        lastClock = now
        for ((u, t) in lastActive.toList()) {
            val busy = (u == ch && on) || (u < 4 && pad[u] != null)
            if (busy) lastActive[u] = now
            if (busy || now - t < 15000) sendClock(u) else lastActive.remove(u)
        }
    }
    private fun send() {
        if (on) { lastActive[ch] = core.wallMs(); sendClock(ch) }
        core.engine.post(EngineCommand.Fx(ch, FxSlotName.BEAT, fx, beat, depth, on))
    }
    fun select(step: Int) {
        val names = FX_LIST.map { it.first }
        val k = names.indexOf(fx).let { if (it < 0) 0 else it }
        val was = on
        fx = names[(k + step + names.size) % names.size]
        send(); save()
        if (was) core.status("Beat FX: ${fx.raw}")
    }
    fun select(kind: FxKind) { fx = kind; send(); save() }
    fun beatStep(step: Int) {
        val list = spec.beats ?: return
        var k = list.indexOfFirst { abs(it - beat) < 1e-6 }
        if (k < 0) k = max(0, list.indexOfFirst { it == spec.beat })
        k = max(0, min(list.size - 1, k + step))
        beats[fx] = list[k]
        send(); save()
    }
    fun channel(c: Int) {
        if (c == ch) return
        // the old insert stops taking input and rings out; the new one picks up
        core.engine.post(EngineCommand.Fx(ch, FxSlotName.BEAT, on = false))
        ch = c
        send(); save()
    }
    fun setOn(v: Boolean) { on = v; send() }
    fun setDepth(v: Double) { depth = clamp(v, 0.0, 1.0); send(); save() }
    // PAD FX: hold a pad = that effect on this deck; let go = off (the last pad pressed wins)
    fun padDown(i: Int, bank: PadMode, p: Int) {
        val pr = PAD_FX[bank]?.getOrNull(p) ?: return
        pad[i] = PadHeld(p, bank)
        lastActive[i] = core.wallMs(); sendClock(i)
        core.engine.post(EngineCommand.Fx(i, FxSlotName.PAD, pr.fx, pr.beats, pr.depth, true))
    }
    fun padUp(i: Int, bank: PadMode, p: Int) {
        val cur = pad[i] ?: return
        if (cur.p != p || cur.bank != bank) return
        pad[i] = null
        core.engine.post(EngineCommand.Fx(i, FxSlotName.PAD, on = false))
    }
}

/** Musical keys: 0-11 major (C...B), 12-23 minor; Camelot labels (the web app's camelot / shiftKey / keysMatch). */
object Keys {
    private val pitch = listOf("C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B")
    fun shift(k: Int, semis: Int): Int = if (k < 0) k else (if (k >= 12) 12 else 0) + (((k % 12) + semis) % 12 + 12) % 12
    data class Camelot(val num: Int, val letter: String, val label: String, val name: String, val sort: Int)
    fun camelot(k: Int): Camelot? {
        if (k < 0) return null
        val minor = k >= 12; val pc = k % 12; val rel = if (minor) (pc + 3) % 12 else pc     // relative major
        val num = ((rel * 7) % 12 + 7) % 12 + 1                                            // C major = 8B, G = 9B ...
        val letter = if (minor) "A" else "B"
        return Camelot(num, letter, "$num$letter", pitch[pc] + if (minor) " minor" else " major", num * 2 + if (minor) 0 else 1)
    }
    /** harmonic mixing: same key, one step round the wheel, or the relative major/minor */
    fun mixes(a: Int, b: Int): Boolean {
        val x = camelot(a) ?: return false
        val y = camelot(b) ?: return false
        if (x.num == y.num) return true
        return x.letter == y.letter && (abs(x.num - y.num) == 1 || abs(x.num - y.num) == 11)
    }
}

/** The audio clock for the screen (AppModel.smoothClock / USBPreview.smoothClock on iOS): the engine's last report
 *  carried forward on the host clock, eased toward each new report instead of jumping, and pulled back by the
 *  output latency so waveforms move with what you hear. */
class SmoothClock(private val core: Core, private val latency: () -> Double) {
    private var cAudio = 0.0; private var cHost = 0.0
    fun now(): Double {
        val s = core.lastSnapshot
        if (s.host == 0.0) return s.time
        val now = hostSeconds()
        val raw = s.time + min(0.25, max(0.0, now - s.host))
        if (cHost == 0.0) { cAudio = raw; cHost = now; return raw }
        val dt = max(0.0, now - cHost)
        var t = cAudio + dt
        val err = raw - t
        if (abs(err) > 0.08) t = raw else t += err * min(1.0, dt * 2)
        cAudio = t; cHost = now
        return t - latency()
    }
}
