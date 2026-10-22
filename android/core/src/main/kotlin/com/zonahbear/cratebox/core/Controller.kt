package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.regex.Pattern
import kotlin.math.abs

// Controllers: Pioneer DJ / AlphaTheta profiles, the table-driven MIDI engine, LEDs, deck layers with soft
// takeover, MIDI learn. A port of CrateboxKit Controller.swift (the web app's controller code, cratebox.html,
// "Controllers"): same mappings (the FLX4 one checked on the hardware, the rest from Mixxx's community
// mappings), same actions. Bytes are Ints 0-255.

/** [status, data1, action, deck (-1 = global), lsb data1 for 14-bit controls (0 = none)] */
data class MapEntry(val status: Int, val data1: Int, val action: String, val deck: Int, val lsb: Int)

class ControllerProfile(
    val id: String, val name: String, private val match: Pattern?, val src: Source, private val makeMap: () -> List<MapEntry>,
    val keepAlive: List<Int>?, val initMsg: List<Int>?, val vu: Boolean, val leds: Boolean,
) {
    enum class Source { TESTED, MIXXX, FAMILY, LEARN }
    val map: List<MapEntry> get() = makeMap()
    internal fun matches(s: String) = match?.matcher(s)?.find() == true
}

object Profiles {
    /** the Mixxx-derived maps (= the web app's MIXXX_MAPS), shared with iOS: ios/CrateboxKit/.../Resources */
    val mixxx: Map<String, List<MapEntry>> by lazy {
        val text = Profiles::class.java.getResourceAsStream("/mixxx_maps.json")?.bufferedReader()?.readText() ?: return@lazy emptyMap()
        try {
            Json.parseToJsonElement(text).jsonObject.mapValues { (_, v) ->
                v.jsonArray.map { e -> val a = e.jsonArray; MapEntry(a[0].jsonPrimitive.int, a[1].jsonPrimitive.int, a[2].jsonPrimitive.content, a[3].jsonPrimitive.int, a[4].jsonPrimitive.int) }
            }
        } catch (_: Exception) { emptyMap() }
    }
    /** The rekordbox-era DDJ layout (DDJ-400, FLX2/4/6/10, 800, 1000...), written out from the FLX4. */
    fun ddjRekordboxMap(deckChs: List<Int> = listOf(0, 1), padChs: List<List<Int>> = listOf(listOf(0x97, 0x98), listOf(0x99, 0x9a))): List<MapEntry> {
        val m = ArrayList<MapEntry>()
        for ((k, ch) in deckChs.withIndex()) {
            val d = k % 2; val n = 0x90 + ch; val c = 0xb0 + ch
            val notes = listOf(0x0b to "play", 0x0e to "playCue", 0x0c to "cue", 0x48 to "start", 0x58 to "sync", 0x5c to "syncOn",
                0x60 to "range", 0x36 to "touch", 0x67 to "touch", 0x10 to "loopIn", 0x11 to "loopOut", 0x4d to "reloop",
                0x50 to "reloopStop", 0x4c to "loopHalf", 0x4e to "loopDouble", 0x51 to "callPrev", 0x53 to "callNext",
                0x3e to "jump:-4", 0x3d to "jump:4", 0x54 to "pfl", 0x68 to "quant", 0x3f to "ignore",
                0x1b to "mode:hotcue", 0x6d to "mode:beatloop", 0x20 to "mode:beatjump", 0x1e to "mode:padfx",
                0x6b to "mode:padfx2", 0x22 to "mode:sampler", 0x69 to "mode:keyboard", 0x6f to "mode:keyshift")
            for ((no, a) in notes) m.add(MapEntry(n, no, a, d, 0))
            for ((no, a) in listOf(0x22 to "jogTop", 0x23 to "jogTop", 0x21 to "jogSide", 0x29 to "jogSearch", 0x02 to "ignore")) m.add(MapEntry(c, no, a, d, 0))
            for ((no, a) in listOf(0x00 to "tempo", 0x13 to "fader", 0x04 to "trim", 0x07 to "hi", 0x0b to "mid", 0x0f to "low")) m.add(MapEntry(c, no, a, d, no + 0x20))
        }
        for ((k, pc) in padChs.withIndex()) {
            val d = k % 2; val pn = pc[0]; val ps = pc[1]
            for (p in 0 until 8) {
                m.add(MapEntry(pn, p, "hot:$p", d, 0)); m.add(MapEntry(ps, p, "hotClear:$p", d, 0))
                m.add(MapEntry(pn, 0x60 + p, "loop:${LOOP_SIZES[p]}", d, 0)); m.add(MapEntry(ps, 0x60 + p, "loop:${LOOP_SIZES[p]}", d, 0))
                m.add(MapEntry(pn, 0x20 + p, "jump:${JUMPS[p]}", d, 0))
                m.add(MapEntry(pn, 0x10 + p, "pfx:$p", d, 0)); m.add(MapEntry(ps, 0x10 + p, "pfx:$p", d, 0))
                m.add(MapEntry(pn, 0x50 + p, "pfx2:$p", d, 0)); m.add(MapEntry(ps, 0x50 + p, "pfx2:$p", d, 0))
            }
        }
        m += listOf(MapEntry(0x96, 0x46, "load", 0, 0), MapEntry(0x96, 0x47, "load", 1, 0), MapEntry(0x96, 0x48, "load", 0, 0), MapEntry(0x96, 0x49, "load", 1, 0),
            MapEntry(0x96, 0x41, "browsePress", -1, 0), MapEntry(0x96, 0x42, "browseShift", -1, 0),
            MapEntry(0xb6, 0x40, "browse", -1, 0), MapEntry(0xb6, 0x64, "zoom", -1, 0),
            MapEntry(0xb6, 0x1f, "xfader", -1, 0x3f), MapEntry(0xb6, 0x17, "cfx", 0, 0x37), MapEntry(0xb6, 0x18, "cfx", 1, 0x38), MapEntry(0xb6, 0x0c, "headMix", -1, 0x2c),
            MapEntry(0x94, 0x63, "fxSelect", -1, 0), MapEntry(0x94, 0x64, "fxSelectPrev", -1, 0), MapEntry(0x94, 0x4a, "fxBeatDown", -1, 0), MapEntry(0x94, 0x4b, "fxBeatUp", -1, 0),
            MapEntry(0x94, 0x10, "fxCh:0", -1, 0), MapEntry(0x95, 0x11, "fxCh:1", -1, 0), MapEntry(0x94, 0x47, "fxOn", -1, 0), MapEntry(0x95, 0x47, "fxOn", -1, 0),
            MapEntry(0x94, 0x43, "fxOff", -1, 0), MapEntry(0x95, 0x43, "fxOff", -1, 0), MapEntry(0xb4, 0x02, "fxDepth", -1, 0x22))
        for (st in listOf(0x94, 0x95)) for (no in 0 until 128) m.add(MapEntry(st, no, "unsupported:Beat FX", -1, 0))
        return m
    }
    /** Mixxx maps only cover channels 1-2 for some units: copy them onto 3-4 for four-deck hardware */
    internal fun withDecks34(map: List<MapEntry>): List<MapEntry> {
        val out = ArrayList(map)
        val have = map.map { it.status * 256 + it.data1 }.toSet()
        for (e in map) {
            val t = e.status and 0xf0; val ch = e.status and 0x0f
            if ((t == 0x90 || t == 0xb0) && ch <= 1) {
                val st = e.status + 2
                if (st * 256 + e.data1 !in have) out.add(MapEntry(st, e.data1, e.action, e.deck, e.lsb))
            }
        }
        return out
    }
    val FLX4_KEEPALIVE = listOf(0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x04, 0x05, 0x00, 0x50, 0x02, 0xf7)
    private fun re(p: String): Pattern = Pattern.compile(p, Pattern.CASE_INSENSITIVE)
    private fun mx(k: String) = mixxx[k] ?: emptyList()
    val all: List<ControllerProfile> = listOf(
        ControllerProfile("ddj-flx4", "Pioneer DDJ-FLX4", re("FLX-?4"), ControllerProfile.Source.TESTED, { ddjRekordboxMap() }, FLX4_KEEPALIVE, null, vu = true, leds = true),
        ControllerProfile("ddj-400", "Pioneer DDJ-400", re("DDJ-?400"), ControllerProfile.Source.MIXXX, { mx("ddj-400") + ddjRekordboxMap() }, null,
            listOf(0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x02, 0x06, 0x00, 0x03, 0x01, 0xf7), vu = true, leds = true),
        ControllerProfile("ddj-200", "Pioneer DDJ-200", re("DDJ-?200"), ControllerProfile.Source.MIXXX, { mx("ddj-200") }, null,
            listOf(0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x02, 0x0a, 0x00, 0x03, 0x01, 0xf7), vu = false, leds = true),
        ControllerProfile("ddj-sb3", "Pioneer DDJ-SB3", re("DDJ-?SB3"), ControllerProfile.Source.MIXXX, { mx("ddj-sb3") }, null, listOf(0xf0, 0x00, 0x20, 0x7f, 0x03, 0x01, 0xf7), vu = false, leds = true),
        ControllerProfile("ddj-sb2", "Pioneer DDJ-SB2", re("DDJ-?SB2"), ControllerProfile.Source.MIXXX, { mx("ddj-sb2") }, null, null, vu = false, leds = true),
        ControllerProfile("ddj-sb", "Pioneer DDJ-SB", re("DDJ-?SB\\b"), ControllerProfile.Source.MIXXX, { withDecks34(mx("ddj-sb")) }, null, null, vu = false, leds = true),
        ControllerProfile("ddj-sx2", "Pioneer DDJ-SX2 / SX3", re("DDJ-?SX[23]"), ControllerProfile.Source.MIXXX, { mx("ddj-sx2") }, null, null, vu = false, leds = true),
        ControllerProfile("ddj-sx", "Pioneer DDJ-SX", re("DDJ-?SX\\b"), ControllerProfile.Source.MIXXX, { mx("ddj-sx") }, null, null, vu = false, leds = true),
        ControllerProfile("xdj-rx", "Pioneer XDJ-RX", re("XDJ-?RX\\b(?!2|3)"), ControllerProfile.Source.MIXXX, { mx("xdj-rx") }, null, null, vu = false, leds = false),
        ControllerProfile("cdj-2000", "Pioneer CDJ-2000 / NXS / NXS2 (MIDI mode)", re("CDJ-?2000"), ControllerProfile.Source.MIXXX, { withDecks34(mx("cdj-2000")) }, null, null, vu = false, leds = false),
        ControllerProfile("cdj-850", "Pioneer CDJ-850 / 900 (MIDI mode)", re("CDJ-?(850|900)"), ControllerProfile.Source.MIXXX, { withDecks34(mx("cdj-850")) }, null, null, vu = false, leds = false),
        ControllerProfile("cdj-350", "Pioneer CDJ-350 (MIDI mode)", re("CDJ-?350"), ControllerProfile.Source.MIXXX, { withDecks34(mx("cdj-350")) }, null, null, vu = false, leds = false),
        ControllerProfile("ddj-rekordbox", "Pioneer DDJ / XDJ, rekordbox series (FLX2, FLX6, FLX10, 800, 1000, GRV6, RB, RR, RX, RZ...)", re("DDJ|FLX|XDJ|OPUS|GRV|AlphaTheta"), ControllerProfile.Source.FAMILY,
            { ddjRekordboxMap(listOf(0, 1, 2, 3), listOf(listOf(0x97, 0x98), listOf(0x99, 0x9a), listOf(0x9b, 0x9c), listOf(0x9d, 0x9e))) }, null, null, vu = false, leds = true),
        ControllerProfile("ddj-serato", "Pioneer DDJ, Serato series (SR, SR2, SZ, SZ2, REV1/5/7, 1000SRT, XP)", re("DDJ-?(SR|SZ|REV|XP|1000SRT)"), ControllerProfile.Source.FAMILY, { mx("ddj-sx") }, null, null, vu = false, leds = true),
        ControllerProfile("cdj", "Pioneer CDJ / XDJ player (MIDI mode)", re("CDJ|XDJ-?(1000|700)"), ControllerProfile.Source.FAMILY, { withDecks34(mx("cdj-2000")) }, null, null, vu = false, leds = false),
        ControllerProfile("learn", "Other controller (map it with MIDI learn)", null, ControllerProfile.Source.LEARN, { emptyList() }, null, null, vu = false, leds = true),
    )
    val srcNote: Map<ControllerProfile.Source, String> = mapOf(
        ControllerProfile.Source.TESTED to "Mapping checked on the hardware.",
        ControllerProfile.Source.MIXXX to "Mapping from Mixxx's community mapping for this model. Not tested here: if a control is wrong, fix it with Learn.",
        ControllerProfile.Source.FAMILY to "This model uses the shared Pioneer layout for its product line. The main controls should work; fix anything wrong with Learn.",
        ControllerProfile.Source.LEARN to "No built-in mapping: use Learn to assign controls.",
    )
    val pioneerish: Pattern = re("DDJ|FLX|CDJ|XDJ|DJM|OPUS|GRV|Pioneer|AlphaTheta")
    fun profile(port: String): ControllerProfile =
        all.firstOrNull { it.src != ControllerProfile.Source.FAMILY && it.src != ControllerProfile.Source.LEARN && it.matches(port) }
            ?: all.filter { it.src == ControllerProfile.Source.FAMILY }.reversed().firstOrNull { it.matches(port) }
            ?: all.first { it.id == "learn" }
    fun byId(id: String): ControllerProfile? = all.firstOrNull { it.id == id }
}

/** What the controller drives (the app's Core plus the library and screen). */
interface ControlTarget {
    val fourDecks: Boolean
    fun absValue(name: String, deck: Int): Double?
    fun setAbs(name: String, deck: Int, v: Double)
    fun press(name: String, arg: String, deck: Int, on: Boolean)
    fun relative(name: String, deck: Int, ticks: Int)
    /** LED state for an action (null = leave it) */
    fun led(name: String, arg: String, deck: Int, blink: Boolean): Int?
    fun vu(deck: Int): Double
    fun controllerStatus(s: String)
}

internal val ABS_ACTIONS = setOf("tempo", "fader", "trim", "hi", "mid", "low", "cfx", "xfader", "headMix", "master", "fxDepth")
internal val REL_ACTIONS = setOf("jogTop", "jogSide", "jogSearch", "browse", "zoom")
internal val LED_RE: Pattern = Pattern.compile("^(play|cue|sync|pfl|loopIn|loopOut|reloop|keylock|quant|mode:|hot:|loop:|pfx:|pfx2:|fxOn|layer)")
internal val PICKUP = listOf("tempo", "fader", "trim", "hi", "mid", "low", "cfx")
val LEARN_LABEL: Map<String, String> = mapOf("play" to "Play", "cue" to "Cue", "sync" to "Sync", "loopIn" to "Loop in", "loopOut" to "Loop out", "reloop" to "Reloop/exit",
    "tempo" to "Tempo fader", "jog" to "Jog wheel", "pfl" to "Headphone cue", "masterCue" to "Master cue", "fxOn" to "Beat FX on/off", "fxSelect" to "Beat FX select",
    "fxBeatDown" to "Beat FX beat ◀", "fxBeatUp" to "Beat FX beat ▶", "fxDepth" to "Beat FX level/depth", "fader" to "Channel fader", "trim" to "Trim", "hi" to "EQ high",
    "mid" to "EQ mid", "low" to "EQ low", "cfx" to "Filter (CFX)", "xfader" to "Crossfader", "headMix" to "Cue/master mix", "master" to "Master level",
    "browse" to "Browse knob", "browsePress" to "Browse knob press", "load" to "Load", "keylock" to "Master tempo", "quant" to "Quantize", "jogSide" to "Jog side (nudge)", "layer" to "Deck layer (1⇄3 / 2⇄4)")

private fun splitAction(a: String): Pair<String, String> {
    val c = a.indexOf(':')
    return if (c >= 0) a.substring(0, c) to a.substring(c + 1) else a to ""
}

class MIDIEngine {
    var target: ControlTarget? = null
    var profile: ControllerProfile? = null; private set
    var learned: List<MapEntry> = emptyList(); private set
    private val table = HashMap<Int, MapEntry>()
    private val lsbTable = HashMap<Int, MapEntry>()
    private val msb = HashMap<MapEntry, Int>()
    /** whether the current mapping has a control for this action (the FLX4 has no MASTER LEVEL message) */
    fun hasAction(a: String) = table.values.any { it.action == a }
    private var ledEntries: List<MapEntry> = emptyList()
    private val ledCache = HashMap<Int, Int>()
    /** which deck each side of the controller plays (deck layers, 4-deck mode) */
    val side = intArrayOf(0, 1)
    // soft takeover: present = waiting for the hardware to reach the deck's setting; the value = its last position
    private val pickup = HashMap<String, Double?>()
    private val fxLever = HashMap<Int, Boolean>()
    /** sends bytes to the controller */
    var send: (List<Int>) -> Unit = {}
    var loadLearned: (String) -> List<MapEntry> = { emptyList() }
    var saveLearned: (String, List<MapEntry>) -> Unit = { _, _ -> }
    var onSide: (() -> Unit)? = null
    var onFxLever: ((Int?) -> Unit)? = null
    /** learn: the on-screen control waiting for a controller message */
    class LearnTarget(val action: String, val deck: Int) { internal var touch: MapEntry? = null; internal var turn: MapEntry? = null }
    var learning: LearnTarget? = null
    var learnMode = false
    var learnHint: (String) -> Unit = {}
    var capture: ((Int, Int) -> Unit)? = null

    companion object {
        internal fun key(st: Int, d1: Int): Int = ((if ((st and 0xf0) == 0x80) 0x90 or (st and 0x0f) else st) shl 8) or d1
    }

    fun use(p: ControllerProfile): ControllerProfile {
        profile = p
        learned = loadLearned(p.id)
        table.clear(); lsbTable.clear(); msb.clear(); ledCache.clear()
        // learned entries win; earlier entries in a profile win over later ones
        for (e in learned + p.map) {
            val k = key(e.status, e.data1)
            if (table[k] == null) table[k] = e
            if (e.lsb != 0) { val lk = key(e.status, e.lsb); if (lsbTable[lk] == null) lsbTable[lk] = e }
        }
        ledEntries = if (!p.leds && learned.isEmpty()) emptyList() else table.values.filter { (it.status and 0xf0) == 0x90 && LED_RE.matcher(it.action).find() }
        return p
    }
    /** the controller just connected: wake it up */
    fun connected() {
        profile?.initMsg?.let { send(it) }
        profile?.keepAlive?.let { send(it) }
    }
    /** the FLX4 drops into demo-light mode unless the software checks in every so often (call every 200 ms) */
    fun keepAliveTick() { profile?.keepAlive?.let { send(it) } }

    fun receive(data: List<Int>) {
        if (data.size < 2) return
        val st = data[0]; val d1 = data[1]; val d2 = if (data.size > 2) data[2] else 0
        val type = st and 0xf0
        if (type != 0x90 && type != 0x80 && type != 0xb0) return
        val c = capture
        if (c != null && type == 0x90 && d2 > 0) { c(st, d1); return }
        if (learnMode) { learnCapture(st, d1, d2); return }
        val k = key(st, d1)
        table[k]?.let { run(it, type, d2, false); return }
        val l = lsbTable[k]
        if (l != null && type == 0xb0) run(l, type, d2, true)
    }

    private fun hwDeck(d: Int): Int = if ((target?.fourDecks ?: false) && (d == 0 || d == 1)) side[d] else d

    private fun run(e: MapEntry, type: Int, v: Int, isLsb: Boolean) {
        val t = target ?: return
        val (name, arg) = splitAction(e.action)
        val deck = if (name == "layer") e.deck else hwDeck(e.deck)
        if (type == 0xb0 && name in ABS_ACTIONS) {
            val value: Double = when {
                e.lsb == 0 -> v / 127.0
                !isLsb -> { msb[e] = v; v / 127.0 }      // apply the MSB straight away, refine on the LSB
                else -> (((msb[e] ?: 0) shl 7) or v) / 16383.0
            }
            if (!pickedUp(name, deck, value)) return
            t.setAbs(name, deck, value); return
        }
        if (name in REL_ACTIONS) {
            if (type != 0xb0) return
            val ticks = if (name.startsWith("jog")) v - 64 else (if (v < 64) v else v - 128)   // jogs: centre 64; knobs: 1 / 127
            t.relative(name, deck, ticks); return
        }
        val on = if (type == 0x90) v > 0 else if (type == 0x80) false else v > 63
        when (name) {
            "layer" -> if (on && t.fourDecks) toggleSide(deck)
            // the FLX4's CH SELECT lever: CH1 / CH2 send 7F while there, 00 when it leaves; neither = MASTER
            "fxCh" -> {
                fxLever[arg.toIntOrNull() ?: 0] = on
                onFxLever?.invoke(if (fxLever[0] == true) hwDeck(0) else if (fxLever[1] == true) hwDeck(1) else null)
            }
            else -> t.press(name, arg, deck, on)
        }
    }

    // ---- deck layers and soft takeover ----
    private fun pickedUp(name: String, deck: Int, value: Double): Boolean {
        val k = "$name/$deck"
        if (!pickup.containsKey(k)) return true
        val p = pickup[k]
        val cur = target?.absValue(name, deck)
        // close enough, or the hardware moved across the deck's setting since the last message
        if (cur == null || abs(value - cur) < 0.02 || (p != null && (p - cur) * (value - cur) <= 0)) { pickup.remove(k); return true }
        pickup[k] = value
        return false
    }
    fun setSide(s: Int, deck: Int) {
        if (deck == side[s] || (!(target?.fourDecks ?: false) && deck >= 2)) return
        target?.press("touch", "", side[s], false)          // let go of the platter on the deck being left
        side[s] = deck
        for (n in PICKUP) pickup["$n/$deck"] = null
        if (fxLever[s] == true) onFxLever?.invoke(deck)
        onSide?.invoke()
        if (profile != null) target?.controllerStatus("Controller ${if (s == 1) "right" else "left"} side: deck ${deck + 1}. Faders and knobs take over once they reach deck ${deck + 1}'s settings.")
    }
    fun toggleSide(s: Int) = setSide(s, if (side[s] == s) s + 2 else s)
    fun resetSides() { side[0] = 0; side[1] = 1; onSide?.invoke() }

    // ---- LEDs: Pioneer hardware lights a button when it receives its own note back ----
    fun updateLeds(blink: Boolean) {
        val t = target ?: return
        fun led(st: Int, no: Int, v: Int) {
            val k = st * 256 + no
            if (ledCache[k] == v) return
            ledCache[k] = v
            send(listOf(st, no, v))
        }
        for (e in ledEntries) {
            val a = e.action
            if (a == "fxOn") { t.led("fxOn", "", -1, blink)?.let { led(e.status, e.data1, it) }; continue }
            // a layer button's light stays off: on the FLX4, SMART CFX's and SMART FADER's lights switch the
            // controller's own Smart CFX / Smart Fader on, which then moves the EQ and BEAT FX by itself
            if (a == "layer") { led(e.status, e.data1, 0); continue }
            if (e.deck < 0) continue
            val (name, arg) = splitAction(a)
            t.led(name, arg, hwDeck(e.deck), blink)?.let { led(e.status, e.data1, it) }
        }
        if (profile?.vu == true) for (i in 0..1) led(0xb0 + i, 0x02, jsRound(t.vu(hwDeck(i)) * 127).toInt())
    }

    // ---- MIDI learn ----
    fun startLearn() {
        if (profile == null) use(Profiles.byId("learn")!!)
        learnMode = true; learning = null; learnHint("Tap a control on screen, then move or press it on the controller.")
    }
    fun stopLearn() { learnMode = false; learning = null }
    fun learnPick(action: String, deck: Int) {
        learning = LearnTarget(action, deck)
        val who = (if (deck >= 0) "Deck ${deck + 1} " else "") + (LEARN_LABEL[action] ?: if (action.startsWith("hot:")) "Pad ${(action.drop(4).toIntOrNull() ?: 0) + 1}" else action)
        learnHint(if (action == "jog") "$who: touch the top of the platter, then turn it." else "$who: now move or press it on the controller.")
    }
    private fun learnCapture(st: Int, d1: Int, d2: Int) {
        val t = learning ?: return
        val p = profile ?: return
        val type = st and 0xf0
        val s = if (type == 0x80) 0x90 or (st and 0x0f) else st
        if (type == 0x80 || (type == 0x90 && d2 == 0)) return
        val entries: List<MapEntry>
        if (t.action == "jog") {
            if (type == 0x90) t.touch = MapEntry(s, d1, "touch", t.deck, 0) else t.turn = MapEntry(s, d1, "jogTop", t.deck, 0)
            val a = t.touch; val b = t.turn
            if (a == null || b == null) { learnHint(if (t.touch != null) "Got the touch. Now turn the platter." else "Got the turn. Now touch the top of the platter."); return }
            entries = listOf(a, b)
        } else if (t.action in ABS_ACTIONS) {
            if (type != 0xb0) { learnHint("That sent a button press. Move a knob or fader instead."); return }
            entries = listOf(MapEntry(s, d1, t.action, t.deck, if (d1 < 0x20) d1 + 0x20 else 0))      // Pioneer 14-bit pairs: fine part on CC + 32
        } else if (t.action == "browse") {
            if (type != 0xb0) { learnHint("Turn the knob rather than pressing it."); return }
            entries = listOf(MapEntry(s, d1, "browse", -1, 0))
        } else entries = listOf(MapEntry(s, d1, t.action, t.deck, 0))
        val keys = entries.map { key(it.status, it.data1) }.toSet()
        val targets = entries.map { "${it.action}/${it.deck}" }.toSet()
        // one control does one thing: drop older learns on the same message or for the same on-screen control
        learned = learned.filter { key(it.status, it.data1) !in keys && "${it.action}/${it.deck}" !in targets } + entries
        saveLearned(p.id, learned)
        use(p)
        learning = null
        learnHint("Mapped ${entries.joinToString(" + ") { fmt("%02X %02X", it.status, it.data1) }}. Tap the next control, or Done.")
    }
    fun clearLearned() { val p = profile ?: return; saveLearned(p.id, emptyList()); use(p) }
    /** SMART CFX / SMART FADER (or two spare buttons) as layer buttons: press each once */
    fun setupLayerButtons(done: () -> Unit) {
        val p = profile ?: run { target?.controllerStatus("Connect the controller first"); return }
        val flx = p.id.lowercase().contains("flx")
        data class Step(val side: Int, val what: String, val decks: String)
        val steps = listOf(Step(0, if (flx) "SMART CFX" else "a spare button for the left side", "1 and 3"), Step(1, if (flx) "SMART FADER" else "a spare button for the right side", "2 and 4"))
        var k = 0
        fun ask(pre: String) = target?.controllerStatus("${pre}Press ${steps[k].what} on the controller: it will switch the ${if (k == 1) "right" else "left"} side between decks ${steps[k].decks}.")
        capture = { st, d1 ->
            val have = table[key(st, d1)]
            if (have != null && have.action != "layer" && !have.action.startsWith("unsupported")) {
                ask("That button already does \"${LEARN_LABEL[have.action] ?: have.action}\". ")
            } else {
                val s = steps[k].side
                learned = learned.filter { !(it.status == st && it.data1 == d1) && !(it.action == "layer" && it.deck == s) } + MapEntry(st, d1, "layer", s, 0)
                saveLearned(p.id, learned)
                use(p)
                k += 1
                if (k < steps.size) ask("")
                else {
                    capture = null
                    target?.controllerStatus("Done: ${steps[0].what} switches the left side 1 ⇄ 3, ${steps[1].what} the right side 2 ⇄ 4 (in 4-deck mode).")
                    done()
                }
            }
        }
        ask("")
    }
    val mappedCount: Int get() = learned.size
}
