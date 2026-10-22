// Ties it all together (AppModel.swift on iOS): the audio host and its engine, the decks (core Core), the
// controller (MidiHost + MIDIEngine), the library, playlists, recorder, HEAT, and the suite's other two modes
// (Deck Bridge, Cratebox USB, made on first use). Implements what the controller's actions do. The Compose
// screens read this and call into it; `onChange` / `onFrame` tell them to redraw.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import com.zonahbear.cratebox.core.Analysis
import com.zonahbear.cratebox.core.ControlTarget
import com.zonahbear.cratebox.core.Core
import com.zonahbear.cratebox.core.CueSet
import com.zonahbear.cratebox.core.CueStore
import com.zonahbear.cratebox.core.DeckAnalysis
import com.zonahbear.cratebox.core.DeckModel
import com.zonahbear.cratebox.core.MIDIEngine
import com.zonahbear.cratebox.core.MapEntry
import com.zonahbear.cratebox.core.PadMode
import com.zonahbear.cratebox.core.Playlists
import com.zonahbear.cratebox.core.Profiles
import com.zonahbear.cratebox.core.RekordboxANLZ
import com.zonahbear.cratebox.core.RekordboxXML
import com.zonahbear.cratebox.core.hostSeconds
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/** Performance Mode's saved cues, per track: "cb.cues.<id>" as {"cue": s or -1, "hot": [s or -1 × 8]}, as on iOS */
class AndroidCueStore(private val prefs: AndroidPrefs) : CueStore {
    override fun load(id: String): CueSet? {
        val o = runCatching { Json.parseToJsonElement(prefs.sp.getString("cb.cues.$id", null) ?: return null) as JsonObject }.getOrNull() ?: return null
        val c = (o["cue"] as? JsonPrimitive)?.doubleOrNull
        val hot = (o["hot"] as? JsonArray)?.map { (it as? JsonPrimitive)?.doubleOrNull?.takeIf { v -> v >= 0 } } ?: emptyList()
        return CueSet(c?.takeIf { it >= 0 }, (hot + List(8) { null }).take(8))
    }
    override fun save(id: String, cue: Double?, hot: List<Double?>) {
        val s = buildJsonObject { put("cue", cue ?: -1.0); put("hot", JsonArray(hot.map { JsonPrimitive(it ?: -1.0) })) }.toString()
        prefs.sp.edit().putString("cb.cues.$id", s).apply()
    }
}

class AppModel(context: Context) : ControlTarget {
    val app: Context = context.applicationContext
    val prefs = AndroidPrefs(app)
    private val main = Handler(Looper.getMainLooper())
    val audio = AudioHost(app)
    val cues = AndroidCueStore(prefs)
    val core = Core(audio.engine, prefs, cues)
    val midi = MIDIEngine()
    val midiHost = MidiHost(app)
    val library = Library(app)
    val devices = Devices(app, library)
    val recorder = Recorder(app)
    val playlists = Playlists(File(app.filesDir, "Cratebox/playlists.json").takeIf { it.exists() }?.readText()) { text ->
        runCatching { File(app.filesDir, "Cratebox").mkdirs(); File(app.filesDir, "Cratebox/playlists.json").writeText(text) }
    }
    val heat = HeatController(app)
    /** the suite's other two modes (made on first use) */
    val bridge by lazy { DeckBridge(app) }
    val usb by lazy { USBSession(app, audio, prefs, library, devices, cues).also { it.status = ::status } }

    var onChange: () -> Unit = {}
    /** ~20 times a second while something is loaded: the decks' readouts follow the playhead */
    var onFrame: () -> Unit = {}
    var statusText = ""; private set
    var controllerName = ""; private set
    var zoomSecs = 8.0
    var tab = 0                                 // phones: 0 = mix, 1 = library
    var waveMode: Boolean = prefs.bool("cb.waveMode", false)
        set(v) { field = v; prefs.set("cb.waveMode", v) }

    // ---- what the browser shows: a list and the selected track in it ----
    sealed class LibraryView(val key: String) {
        object Collection : LibraryView("collection")
        class Playlist(val id: String) : LibraryView("pl:$id")
        class Device(val dev: String) : LibraryView("dev:$dev")
        class DevicePlaylist(val dev: String, val node: Long) : LibraryView("devpl:$dev:$node")
        override fun equals(other: Any?) = other is LibraryView && other.key == key
        override fun hashCode() = key.hashCode()
    }
    var view: LibraryView = LibraryView.Collection
        set(v) { if (field != v) { field = v; selection = prefs.sp.getString("cb.browseSel.${v.key}", null); remember() } }
    var selection: String? = null
        set(v) { if (field != v) { field = v; remember(); changed() } }
    private fun remember() {
        prefs.sp.edit().putString("cb.browseSel.${view.key}", selection).putString("cb.browseView", view.key).apply()
    }
    var browseFocusTree = false
    var treeCursor: LibraryView? = null
    var visibleTrackIds: List<String> = emptyList()  // the library list as shown (for the browse knob)
    var libraryShown = false
    var browserShown = false; private set
    private var browserUntil = 0.0
    private var statusUntil = 0.0
    private var lastLed = 0.0; private var lastKeep = 0.0; private var lastSec = 0.0; private var frame = 0
    private var running = false
    private val clock = com.zonahbear.cratebox.core.SmoothClock(core) { audio.latency }

    private fun changed() = onChange()

    init {
        AndroidSQLite.install()
        core.clock = { clock.now() }
        core.onMain = { main.post(it) }
        core.onStatus = { s, secs -> status(s, secs) }
        core.trackChanged = { t -> library.track(t.id)?.let(library::changed) }
        core.reanalyse = { t -> library.track(t.id)?.let { it.rec.ver = 0; library.enqueue(it) } }
        library.status = { status(it) }
        library.isPlaying = { core.decks.any { it.playing } }
        library.onChange = ::changed
        devices.status = { s, secs -> status(s, secs) }
        devices.onChange = ::changed
        devices.inUse = { d -> core.decks.any { k -> k.track?.let { t -> d.byRbId.values.any { it.info === t } } == true } }
        recorder.status = { s, secs -> status(s, secs) }
        heat.onStatus = { status(it) }
        heat.onChange = ::changed
        midi.target = this
        midi.send = { b -> midiHost.send(b.toIntArray()) }
        midi.loadLearned = { id -> parseMap(prefs.sp.getString("cb.learn.$id", null)) }
        midi.saveLearned = { id, l -> prefs.sp.edit().putString("cb.learn.$id", encodeMap(l)).apply() }
        midi.onFxLever = { d -> core.fx.channel(d ?: 4) }
        midi.onSide = ::changed
        midiHost.onMessage = { m -> midi.receive(m.toList()) }
        midiHost.onChange = ::controllerConnected
        audio.onRoute = { main.post(::routeChanged) }
    }

    private fun encodeMap(l: List<MapEntry>) = JsonArray(l.map { JsonArray(listOf(JsonPrimitive(it.status), JsonPrimitive(it.data1), JsonPrimitive(it.action), JsonPrimitive(it.deck), JsonPrimitive(it.lsb))) }).toString()
    private fun parseMap(s: String?): List<MapEntry> = runCatching {
        Json.parseToJsonElement(s ?: return emptyList()).jsonArray.map { e ->
            val a = e.jsonArray
            MapEntry(a[0].jsonPrimitive.int, a[1].jsonPrimitive.int, a[2].jsonPrimitive.content, a[3].jsonPrimitive.int, a[4].jsonPrimitive.int)
        }
    }.getOrDefault(emptyList())

    private val tick = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            tickOnce()
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    fun start() {
        if (running) return
        running = true
        audio.start()
        midiHost.start()
        Choreographer.getInstance().postFrameCallback(tick)
        for (f in library.folders) if (!f.device && library.fs(f)?.exists(Devices.PDB_REL) != true) library.scan(f)
        devices.restore()
        restoreBrowse()
    }

    /** the app going away for good (the activity's onDestroy when finishing) */
    fun stop() {
        running = false
        if (recorder.recording) recorder.stop(audio.engine)
        midiHost.shutdown()
        audio.shutdown()
    }

    private fun tickOnce() {
        core.tick()
        val now = hostSeconds()
        if (now - lastLed > 0.05) { lastLed = now; midi.updateLeds(((now * 2).toInt() % 2) == 0) }
        if (now - lastKeep > 0.2) { lastKeep = now; midi.keepAliveTick() }
        if (now - lastSec > 1) { lastSec = now; recorder.noteAudible(core) }
        if (statusUntil > 0 && now > statusUntil) { statusUntil = 0.0; statusText = ""; changed() }
        if (browserShown && now > browserUntil) { browserShown = false; browseFocusTree = false; treeCursor = null; changed() }
        frame++
        if (frame % 3 == 0 && core.decks.any { it.loaded }) onFrame()
    }

    fun status(s: String, secs: Double = 4.0) {
        statusText = s
        statusUntil = if (secs > 0) hostSeconds() + secs else 0.0
        changed()
    }

    private var toldWireless = ""
    /** output changed: tell about Bluetooth's delay once per device */
    private fun routeChanged() {
        if (audio.wireless) {
            if (toldWireless != audio.routeName) {
                toldWireless = audio.routeName
                status("Bluetooth: ${audio.routeName} plays about ${(audio.latency * 1000).toInt()} ms late. The waveforms are shifted to match what you hear, and SYNC still locks, but mixing by ear and scratching will feel late, and there's no separate headphone cue. For gigs, use the controller's outputs or a cable.", 14.0)
            }
        } else toldWireless = ""
        changed()
    }

    private fun controllerConnected(name: String) {
        controllerName = name
        if (name.isEmpty()) { status("Controller disconnected"); return }
        val forced = prefs.sp.getString("cb.profileFor.$name", "") ?: ""
        val p = midi.use(Profiles.byId(forced) ?: Profiles.profile(name))
        midi.connected()
        // a controller whose MASTER LEVEL works in its own hardware: Cratebox's master goes to its default level
        if (!midi.hasAction("master")) { core.mixer.master = 0.8; core.mixerChanged() }
        status("$name connected · ${p.name}" + if (p.src == com.zonahbear.cratebox.core.ControllerProfile.Source.TESTED) "" else " (see Settings → Controller)")
    }
    fun useProfile(id: String) {
        val p = Profiles.byId(id) ?: return
        if (controllerName.isNotEmpty()) prefs.sp.edit().putString("cb.profileFor.$controllerName", id).apply()
        midi.use(p); midi.connected()
    }

    // ---- loading ----
    fun load(t: LibTrack, deck: Int) {
        val d = core.decks[deck]
        d.canLoad()?.let { status(it); return }
        val uri = library.fileUri(t) ?: run { status("${t.rec.title} isn't in a connected folder"); return }
        d.beginLoad(t.info)
        status("Loading ${t.info.title} into deck ${deck + 1}...", 0.0)
        val info = t.info
        val analysedBefore = t.analysed && (info.bpm ?: 0.0) > 0 && info.firstBeat != null
        val range = prefs.bpmRange
        Thread({
            try {
                // a rekordbox USB track: rekordbox's own grid, phrases and cues (read first, so they're used)
                var fromRekordbox = false
                if (t.device != null) { devices.readAnalysis(t); fromRekordbox = (info.bpm ?: 0.0) > 0 && info.firstBeat != null }
                val cached = analysedBefore || fromRekordbox
                val pcm = AudioDecoder.decode(app, uri)
                val m = AudioDecoder.mono(pcm, 11025.0); val w = AudioDecoder.mono(pcm, 22050.0)
                val dur = pcm.count / pcm.sampleRate
                val a: DeckAnalysis
                if (cached || info.gridManual) {
                    val wave = Analysis.waveform(w.first, w.second)
                    val ph = if (cached && info.phrases.isNotEmpty()) info.phrases else Analysis.phraseAnalysis(m.first, m.second, info.bpm ?: 120.0, info.firstBeat ?: 0.0)
                    val key = if (cached) info.key else Analysis.detectKey(m.first, m.second).key
                    a = DeckAnalysis(info.bpm ?: 120.0, info.firstBeat ?: 0.0, key, ph, wave, dur)
                    // rekordbox's grid beat by beat (unless the grid was edited by hand here)
                    val b = info.rbBeats
                    if (fromRekordbox && !info.gridManual && b != null && b.size >= 2) { a.beats = b.toDoubleArray(); a.beat0 = info.rbBeat0 }
                } else {
                    val r = Analysis.analyze(m.first, m.second, range, w)
                    a = DeckAnalysis(r.bpm, r.firstBeat, if (info.keyFromRekordbox && info.key >= 0) info.key else r.key, r.phrases, r.wave, dur)
                    info.autoBpm = r.bpm; info.autoFirst = r.firstBeat
                }
                main.post {
                    t.rec.ver = Library.ANALYSIS_VER
                    d.finishLoad(info, pcm, a, m)
                    library.changed(t)
                    if (statusText.startsWith("Loading ")) status("", 0.0)
                    changed()
                }
            } catch (e: Throwable) {
                // OutOfMemoryError included: a long file on a small phone shouldn't take the set down
                main.post { d.failLoad(info, e.message ?: e.toString()); changed() }
            }
        }, "cratebox-load").apply { priority = Thread.NORM_PRIORITY + 1 }.start()
    }
    fun loadSelected(deck: Int) {
        val t = selection?.let(library::track) ?: run { showBrowser(); status("Turn the browse knob to pick a track (press it for playlists)"); return }
        load(t, deck)
    }

    // ---- browsing from the controller: the knob walks the tracks, or (press it) the playlist tree ----
    class BrowseSource(val view: LibraryView, val name: String, val depth: Int, val group: String)

    /** Collection, your playlists, then each USB and its rekordbox playlists, in tree order */
    fun browseSources(): List<BrowseSource> {
        val out = arrayListOf(BrowseSource(LibraryView.Collection, "Collection", 0, "CRATEBOX"))
        fun local(parent: String?, depth: Int) {
            for (p in playlists.children(parent)) if (p.folder) local(p.id, depth + 1) else out.add(BrowseSource(LibraryView.Playlist(p.id), p.name, depth, "CRATEBOX"))
        }
        local(null, 0)
        for (d in devices.list) {
            out.add(BrowseSource(LibraryView.Device(d.id), "All tracks", 0, d.name))
            fun walk(parent: Long, depth: Int) {
                for (n in d.tree.filter { it.parent == parent }.sortedBy { it.sort })
                    if (n.folder) walk(n.id, depth + 1) else out.add(BrowseSource(LibraryView.DevicePlaylist(d.id, n.id), n.name, depth, d.name))
            }
            walk(0, 0)
        }
        return out
    }
    fun restoreBrowse() {
        val k = prefs.sp.getString("cb.browseView", null) ?: return
        browseSources().firstOrNull { it.view.key == k }?.let { view = it.view }
    }

    /** a list's tracks in its own order (the screen adds search and sorting) */
    fun tracks(v: LibraryView): List<LibTrack> = when (v) {
        LibraryView.Collection -> library.tracks.filter { it.device == null }
        is LibraryView.Playlist -> playlists.get(v.id)?.items?.mapNotNull(library::track) ?: emptyList()
        is LibraryView.Device -> library.tracks.filter { it.device == v.dev }
        is LibraryView.DevicePlaylist -> devices.list.firstOrNull { it.id == v.dev }?.let { d -> d.tree.firstOrNull { it.id == v.node }?.let { devices.tracks(it, d) } } ?: emptyList()
        else -> emptyList()
    }
    /** the tracks the knob moves through: the list on screen, or the current view */
    fun browseTracks(): List<LibTrack> =
        if (libraryShown && visibleTrackIds.isNotEmpty()) visibleTrackIds.mapNotNull(library::track) else tracks(view)

    fun showBrowser(secs: Double = 8.0) {
        browserUntil = hostSeconds() + secs
        if (!browserShown && tab != 1) { browserShown = true; changed() }
    }
    fun hideBrowser() { browserUntil = 0.0; browserShown = false; browseFocusTree = false; treeCursor = null; changed() }
    fun moveSelection(n: Int) {
        showBrowser()
        if (browseFocusTree) {
            val src = browseSources()
            val i = src.indexOfFirst { it.view == (treeCursor ?: view) }.coerceAtLeast(0)
            treeCursor = src[max(0, min(src.size - 1, i + n))].view
            changed(); return
        }
        val ids = browseTracks().map { it.id }
        if (ids.isEmpty()) { status("Nothing in $browseTitle yet: press the browse knob to pick a playlist"); return }
        val i = ids.indexOf(selection ?: "")
        selection = ids[max(0, min(ids.size - 1, i + n))]
    }
    val browseTitle get() = browseSources().firstOrNull { it.view == view }?.name ?: "the list"

    // ---- ControlTarget: what the controller's actions do ----
    override val fourDecks get() = core.four
    override fun absValue(name: String, deck: Int) = core.mixerValue(name, deck)
    override fun setAbs(name: String, deck: Int, v: Double) {
        when (name) {
            "tempo" -> core.decks[deck].setPitch(v * 2 - 1)         // top = slower, bottom = faster, like a CDJ
            "fxDepth" -> core.fx.setDepth(v)
            else -> core.setMixer(name, deck, v)
        }
    }
    override fun relative(name: String, deck: Int, ticks: Int) {
        when (name) {
            "jogTop" -> core.decks[deck].jogTicks(ticks.toDouble(), DeckModel.JogKind.SCRATCH)
            "jogSide" -> core.decks[deck].jogTicks(ticks.toDouble(), DeckModel.JogKind.BEND)
            "jogSearch" -> core.decks[deck].jogTicks(ticks.toDouble(), DeckModel.JogKind.SEARCH)
            "browse" -> moveSelection(ticks)
            "zoom" -> { zoomSecs = min(32.0, max(2.0, zoomSecs * if (ticks > 0) 0.8 else 1.25)); changed() }
        }
    }
    override fun press(name: String, arg: String, deck: Int, on: Boolean) {
        val d = if (deck in 0..3) core.decks[deck] else null
        when (name) {
            "play" -> if (on) d?.togglePlay()
            "playCue" -> if (on && d != null) { d.seek(d.cue); d.setPlaying(true) }
            "cue" -> if (on) d?.cueDown() else d?.cueUp()
            "start" -> if (on && d != null) { d.setPlaying(false); d.seek(0.0) }
            "sync" -> if (on && d != null) d.setSync(!d.sync)
            "syncOn" -> if (on && d != null && !d.sync) d.setSync(true)
            "range" -> if (on) d?.cycleRange()
            "touch" -> d?.jogTouch(on)
            "loopIn" -> d?.loopInPress(on)
            "loopOut" -> if (on) d?.loopOut()
            "reloop" -> if (on) d?.reloopExit()
            "reloopStop" -> if (on && d != null) { d.reloopExit(); if (d.loop.on) d.setPlaying(false) }
            "loopHalf" -> if (on) d?.loopScale(0.5)
            "loopDouble" -> if (on) d?.loopScale(2.0)
            "callPrev" -> if (on) d?.callCue(-1)
            "callNext" -> if (on) d?.callCue(1)
            "jump" -> if (on) arg.toDoubleOrNull()?.let { d?.beatJump(it) }
            "pfl" -> if (on && deck >= 0) core.togglePfl(deck)
            "masterCue" -> if (on) core.toggleMasterCue()
            "fxSelect" -> if (on) core.fx.select(1)
            "fxSelectPrev" -> if (on) core.fx.select(-1)
            "fxBeatDown" -> if (on) core.fx.beatStep(-1)
            "fxBeatUp" -> if (on) core.fx.beatStep(1)
            "fxOn" -> if (on) core.fx.setOn(!core.fx.on)
            "fxOff" -> if (on) core.fx.setOn(false)
            "pfx", "pfx2" -> {
                val p = arg.toIntOrNull()
                val bank = if (name == "pfx") PadMode.PADFX else PadMode.PADFX2
                if (p != null && deck >= 0) { if (on) core.fx.padDown(deck, bank, p) else core.fx.padUp(deck, bank, p) }
            }
            "quant" -> if (on && d != null) d.quant = !d.quant
            "keylock" -> if (on && d != null) d.setMT(!d.mt)
            "mode" -> if (on) { val m = PadMode.entries.firstOrNull { it.raw == arg }; if (m != null) d?.padMode = m else status("Pad mode \"$arg\" isn't in Cratebox yet") }
            "hot" -> if (on) arg.toIntOrNull()?.let { d?.hotcue(it) }
            "hotClear" -> if (on) arg.toIntOrNull()?.let { d?.clearHot(it) }
            "loop" -> if (on) arg.toDoubleOrNull()?.let { d?.beatLoop(it) }
            "load" -> if (on && deck >= 0) {
                if (browseFocusTree) { browseFocusTree = false; treeCursor = null; showBrowser(); status("Pick a track, then LOAD"); return }
                loadSelected(deck); hideBrowser()
            }
            "browsePress" -> if (on) {
                // the first press only brings the browser up, on the list you were in
                if (!browserShown) { browseFocusTree = false; treeCursor = null; showBrowser() }
                else {
                    if (browseFocusTree) { treeCursor?.let { view = it }; treeCursor = null; browseFocusTree = false }
                    else { treeCursor = view; browseFocusTree = true }
                    showBrowser()
                }
            }
            "browseShift" -> if (on) tab = if (tab == 0) 1 else 0
            "browseUp" -> if (on) moveSelection(-1)
            "browseDown" -> if (on) moveSelection(1)
            "unsupported" -> if (on) status("$arg isn't in Cratebox yet")
        }
        changed()
    }
    override fun led(name: String, arg: String, deck: Int, blink: Boolean): Int? {
        if (name == "fxOn") return if (core.fx.on) 127 else 0
        if (deck !in 0..3) return null
        val d = core.decks[deck]
        fun b(v: Boolean) = if (v) 127 else 0
        return when (name) {
            "play" -> b(if (d.playing) true else d.loaded && blink)        // PLAY blinks when paused
            "cue" -> { val atCue = d.loaded && abs(d.now() - d.cue) < 0.03; b(if (d.loaded && (atCue || d.previewing)) true else d.loaded && !d.playing && blink) }
            "sync" -> b(d.sync)
            "pfl" -> b(core.mixer.pfl[deck])
            "loopIn" -> b(d.loop.on || (d.loop.a != null && d.loop.b == null && blink))
            "loopOut" -> b(d.loop.on)
            "reloop" -> b(d.loop.b != null)
            "keylock" -> b(d.mt)
            "quant" -> b(d.quant)
            "mode" -> b(d.padMode.raw == arg)
            "hot" -> b(d.padMode == PadMode.HOTCUE && (arg.toIntOrNull()?.let { d.hot[it] != null } ?: false))
            "loop" -> b(d.padMode == PadMode.BEATLOOP && d.loop.on && abs(d.loopBeats() - (arg.toDoubleOrNull() ?: 0.0)) < 0.01)
            "pfx", "pfx2" -> {
                val bank = if (name == "pfx") PadMode.PADFX else PadMode.PADFX2
                b(d.padMode == bank && core.fx.pad[deck]?.let { it.p == arg.toIntOrNull() && it.bank == bank } == true)
            }
            else -> null
        }
    }
    override fun vu(deck: Int): Double {
        val r = core.lastSnapshot.decks[deck]
        val p = max(r.peakL, r.peakR).toDouble()
        return if (p <= 0) 0.0 else min(1.0, max(0.0, (20 * log10(p) + 48) / 48))
    }
    override fun controllerStatus(s: String) = status(s, 6.0)

    // ---- rekordbox XML ----

    /** rekordbox's collection export: grids, keys and cues for files Cratebox knows, and its playlists in a folder */
    fun importXml(data: ByteArray) {
        val x = runCatching { RekordboxXML.parse(data) }.getOrNull() ?: run { status("Couldn't read that file: not a rekordbox XML export", 8.0); return }
        // match rekordbox's tracks to files Cratebox knows (file name + size, then file name)
        val byFile = HashMap<String, LibTrack>()
        for (t in library.tracks) if (t.device == null) {
            val f = t.rec.rel.substringAfterLast('/').lowercase()
            byFile["$f|${t.rec.size}"] = t
            byFile.putIfAbsent(f, t)
        }
        val resolved = HashMap<String, LibTrack>(); var matched = 0; var applied = 0
        for (id in x.order) {
            val r = x.tracks[id] ?: continue
            val f = r.filename.lowercase()
            val t = byFile["$f|${r.size}"] ?: byFile[f] ?: continue
            matched++; resolved[id] = t
            var did = false
            val g = r.grid
            if (g != null && g.bpm > 0 && !t.info.gridManual) {
                val spb = 60 / g.bpm; val bar = 4 * spb
                var first = g.firstBeat - (g.beat - 1) * spb                 // back to the downbeat
                first -= floor(first / bar) * bar
                t.info.bpm = g.bpm; t.info.firstBeat = first; t.info.gridManual = true
                if (t.info.autoBpm == null) { t.info.autoBpm = g.bpm; t.info.autoFirst = first }
                did = true
            }
            val k = RekordboxANLZ.keyIndex(r.key)
            if (k >= 0) { t.info.key = k; t.info.keyFromRekordbox = true; did = true }
            if (t.info.duration == 0.0 && r.duration > 0) t.info.duration = r.duration
            if (r.marks.isNotEmpty() && cues.load(t.id) == null) {
                val hot = MutableList<Double?>(8) { null }
                for (m in r.marks) if (m.num in 0..7) hot[m.num] = m.start
                cues.save(t.id, r.marks.filter { it.num == -1 }.minOfOrNull { it.start }, hot); did = true
            }
            if (did) { applied++; library.changed(t); if (!t.analysed) library.enqueue(t) }
        }
        // playlists go into a folder of their own
        val top = playlists.new("rekordbox (${DateFormat.getDateInstance(DateFormat.SHORT).format(Date())})", folder = true)
        val made = HashMap<Int, String>()
        for (n in x.playlists) {
            val parent = n.parent?.let { made[it] } ?: top.id
            val p = playlists.new(n.name, n.folder, parent)
            made[n.key] = p.id
            if (!n.folder) playlists.add(n.tracks.mapNotNull { resolved[it] }.map { listOf(it.id, it.info.title, it.info.artist, it.rec.rel.substringAfterLast('/')) }, p.id)
        }
        status("rekordbox XML: ${x.tracks.size} tracks ($matched found in your folders, grids/cues/keys taken from rekordbox for $applied), ${x.playlists.count { !it.folder }} playlists", 12.0)
    }

    /** your library and playlists as rekordbox XML (rekordbox: Preferences → Advanced → Imported Library) */
    fun exportXml(): String {
        val own = library.tracks.filter { it.device == null }
        val ts = own.map { t ->
            val c = cues.load(t.id)
            val folderName = library.folders.firstOrNull { it.id == t.rec.folder }?.name ?: ""
            RekordboxXML.ExportTrack(t.id, t.info.title, t.info.artist, t.rec.rel.substringAfterLast('/'), "$folderName/${t.rec.rel}",
                t.rec.size.toInt(), t.info.duration, t.info.bpm ?: 0.0, t.info.firstBeat, t.info.key, c?.cue, c?.hot ?: emptyList())
        }
        val ls = playlists.lists.map { RekordboxXML.ExportList(it.id, it.name, it.folder, it.parent, it.order, it.items) }
        status("Exported ${own.size} tracks and ${playlists.lists.count { !it.folder }} playlists. In rekordbox: Preferences → Advanced → Imported Library = this file.", 12.0)
        return RekordboxXML.export(ts, ls, prefs.string("cb.basePath", ""))
    }
}
