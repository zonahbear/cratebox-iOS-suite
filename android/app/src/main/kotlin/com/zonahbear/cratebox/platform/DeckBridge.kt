// Deck Bridge (DeckBridge.swift on iOS): Cratebox as a touch controller for rekordbox's decks 3 and 4 (or 1 and 2).
//
// Transport on Android:
//  · USB cable: set the phone's USB mode to MIDI (the notification after plugging in, or Settings → Connected
//    devices → USB → MIDI). The computer sees an "Android" MIDI device; rekordbox maps it like any other.
//  · Network (Wi-Fi / Ethernet): Cratebox's own RTP-MIDI session (RtpMidiSession). A Mac connects to it in Audio
//    MIDI Setup → MIDI Network Setup; a Windows PC with the free rtpMIDI driver.
//  (Bluetooth LE MIDI the other way round, the phone as the peripheral, isn't in Android's framework: not here.)
// Messages go out on everything connected; rekordbox's lights come back the same way. The message layout and
// the rekordbox mapping file are core's DeckBridgeMap.
package com.zonahbear.cratebox.platform

import android.content.ContentValues
import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.zonahbear.cratebox.core.BridgeControl
import com.zonahbear.cratebox.core.BridgeMessage
import com.zonahbear.cratebox.core.DeckBridgeMap
import com.zonahbear.cratebox.core.MidiFramer
import com.zonahbear.cratebox.core.hostSeconds
import kotlin.math.abs
import kotlin.math.max

class BridgeDeckState(val deck: Int) {                 // rekordbox's deck, 0-3
    var playing = false; var cueLit = false; var sync = false; var keylock = false; var quantize = false; var slip = false
    var loopIn = false; var loopOut = false; var reloop = false; var autoLoop = false; var headphoneCue = false
    val hot = BooleanArray(8)
    /** rekordbox's pad mode on this deck (as last chosen here), and its pads' lights per mode */
    var padBank = DeckBridgeMap.PadBank.HOT_CUE
    val padLit = Array(4) { BooleanArray(8) }
    // what the touch controls are at (rekordbox doesn't send faders back)
    var tempo = 0.5; var trim = 0.5; var hi = 0.5; var mid = 0.5; var low = 0.5; var fader = 1.0; var filter = 0.5
    var jogTouched = false
    var jogAngle = 0.0                                  // drawn rotation of the platter

    fun lit(c: BridgeControl): Boolean = when (c) {
        BridgeControl.PLAY_PAUSE -> playing; BridgeControl.CUE -> cueLit; BridgeControl.SYNC -> sync; BridgeControl.KEYLOCK -> keylock
        BridgeControl.QUANTIZE -> quantize; BridgeControl.SLIP -> slip; BridgeControl.LOOP_IN -> loopIn; BridgeControl.LOOP_OUT -> loopOut
        BridgeControl.RELOOP_EXIT -> reloop; BridgeControl.AUTO_LOOP -> autoLoop; BridgeControl.HEADPHONE_CUE -> headphoneCue
        else -> false
    }
    fun set(c: BridgeControl, on: Boolean) {
        when (c) {
            BridgeControl.PLAY_PAUSE -> playing = on; BridgeControl.CUE -> cueLit = on; BridgeControl.SYNC -> sync = on
            BridgeControl.KEYLOCK -> keylock = on; BridgeControl.QUANTIZE -> quantize = on; BridgeControl.SLIP -> slip = on
            BridgeControl.LOOP_IN -> loopIn = on; BridgeControl.LOOP_OUT -> loopOut = on; BridgeControl.RELOOP_EXIT -> reloop = on
            BridgeControl.AUTO_LOOP -> autoLoop = on; BridgeControl.HEADPHONE_CUE -> headphoneCue = on
            // rekordbox lights the pad mode it's in: follow it, so a mode picked on the computer reaches the pads here
            BridgeControl.HOT_CUE_MODE, BridgeControl.BEAT_JUMP_MODE, BridgeControl.PAD_FX1_MODE, BridgeControl.PAD_FX2_MODE ->
                if (on) DeckBridgeMap.PadBank.entries.firstOrNull { it.mode == c }?.let { padBank = it }
            else -> {}
        }
    }
}

@Suppress("DEPRECATION")      // MidiManager.getDevices / registerDeviceCallback(callback, handler)
class DeckBridge(context: Context) {
    private val app = context.applicationContext
    private val sp = app.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val mm = app.getSystemService(Context.MIDI_SERVICE) as MidiManager?
    var onChange: () -> Unit = {}
    private fun changed() = onChange()

    // ---- which rekordbox decks the two sides drive ----
    var pair: Int = sp.getInt("cb.bridge.pair", 1)                  // 1 = decks 3/4, 0 = decks 1/2
        set(v) { field = v; sp.edit().putInt("cb.bridge.pair", v).apply(); sides = makeSides(v); changed() }
    var sides = makeSides(pair); private set
    private fun makeSides(p: Int) = listOf(BridgeDeckState(p * 2), BridgeDeckState(p * 2 + 1))
    var shift = false
    var xfader = 0.5; private set
    var fxDepth = 0.5; private set
    var fxOn = false; private set
    val fxAssign = BooleanArray(4)
    var invertTempo: Boolean = sp.getBoolean("cb.bridge.invertTempo", false)
        set(v) { field = v; sp.edit().putBoolean("cb.bridge.invertTempo", v).apply() }
    var jogSensitivity: Double = sp.getFloat("cb.bridge.jogSens", 1f).toDouble()
        set(v) { field = v; sp.edit().putFloat("cb.bridge.jogSens", v.toFloat()).apply() }

    // ---- transport ----
    var networkOn: Boolean = sp.getBoolean("cb.bridge.net", true)
        set(v) { field = v; sp.edit().putBoolean("cb.bridge.net", v).apply(); applyNetwork() }
    private val net = RtpMidiSession(app)
    private var usbDevice: MidiDevice? = null
    private var usbIn: MidiInputPort? = null           // us → the computer
    private var usbOut: MidiOutputPort? = null         // the computer → us
    var destinations: List<String> = emptyList(); private set
    var lastHeard = 0.0; private set                   // host time of the last message from rekordbox
    var sentCount = 0; private set
    var status = ""; private set
    val heardRecently get() = lastHeard > 0 && hostSeconds() - lastHeard < 30
    val linked get() = destinations.isNotEmpty()
    /** a computer is really there: one is connected to the session or the cable, or rekordbox has sent something lately */
    val confirmed get() = net.connectedPeers.isNotEmpty() || usbIn != null || heardRecently
    private var started = false

    private val framer = MidiFramer { m -> main.post { heard(m) } }
    private val receiver = object : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) { synchronized(framer) { framer.feed(msg, offset, count) } }
    }
    private val deviceCallback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(info: MidiDeviceInfo) = bindUsb()
        override fun onDeviceRemoved(info: MidiDeviceInfo) = bindUsb()
    }
    private val refreshTick = object : Runnable { override fun run() { if (started) { net.prune(); refresh(); main.postDelayed(this, 3000) } } }

    fun setActive(on: Boolean) { if (on) start() }

    fun start() {
        if (started) { refresh(); return }
        started = true
        net.onMessage = { m -> main.post { heard(m) } }
        net.onPeers = { main.post { refresh() } }
        applyNetwork()
        mm?.registerDeviceCallback(deviceCallback, main)
        bindUsb()
        // keep the copy in Downloads/Cratebox the same as this build's mapping
        writeMapping()
        main.postDelayed(refreshTick, 3000)
    }

    fun shutdown() {
        started = false
        net.stop()
        mm?.unregisterDeviceCallback(deviceCallback)
        closeUsb()
    }

    private fun applyNetwork() {
        if (networkOn && started) { if (!net.start()) status = "Couldn't open the network MIDI ports (5004-5025 all busy)" } else net.stop()
        refresh()
    }

    /** the phone as a USB MIDI device: Android lists it as its own "USB Peripheral" MIDI device */
    private fun bindUsb() {
        val m = mm ?: return
        val peri = m.devices.firstOrNull { MidiHost.isBridgeEndpoint(it) && it.type == MidiDeviceInfo.TYPE_USB }
        if (peri == null) { closeUsb(); refresh(); return }
        if (usbDevice?.info?.id == peri.id) return
        closeUsb()
        m.openDevice(peri, { d ->
            if (d == null) return@openDevice
            usbDevice = d
            if (peri.inputPortCount > 0) usbIn = d.openInputPort(0)
            if (peri.outputPortCount > 0) usbOut = d.openOutputPort(0)?.also { it.connect(receiver) }
            refresh()
        }, main)
    }
    private fun closeUsb() {
        runCatching { usbOut?.disconnect(receiver) }
        runCatching { usbOut?.close() }; runCatching { usbIn?.close() }; runCatching { usbDevice?.close() }
        usbOut = null; usbIn = null; usbDevice = null
    }

    fun refresh() {
        if (!started) return
        val peers = net.connectedPeers
        val names = ArrayList<String>()
        if (networkOn) names.add(if (peers.isEmpty()) "Network session" else "Network: " + peers.joinToString(", "))
        if (usbIn != null) names.add("USB cable")
        destinations = names
        status = when {
            peers.isNotEmpty() || usbIn != null || heardRecently -> "Linked: " + names.joinToString(" · ")
            networkOn -> "Sending on the network session \"${net.name}\" (port ${net.port}). Connect to it from rtpMIDI / Audio MIDI Setup, or set USB to MIDI and plug in."
            else -> "Not linked: set the phone's USB mode to MIDI and plug into the computer"
        }
        changed()
    }

    // ---- out ----
    fun send(ms: List<BridgeMessage>) {
        if (!started || ms.isEmpty()) return
        if (networkOn) net.send(ms.map { it.bytes })
        usbIn?.let { p ->
            val all = ms.flatMap { it.bytes }
            val b = ByteArray(all.size) { all[it].toByte() }
            runCatching { p.send(b, 0, b.size) }
        }
        sentCount += ms.size
    }
    fun button(c: BridgeControl, side: Int, on: Boolean) = send(DeckBridgeMap.button(c, sides[side].deck, on))
    fun global(c: BridgeControl, on: Boolean) = send(DeckBridgeMap.button(c, 0, on))
    fun hotCue(k: Int, side: Int, on: Boolean) = send(DeckBridgeMap.hotCue(k, sides[side].deck, on, shift))
    /** a pad in the deck's current pad mode (SHIFT only does something for hot cues: delete) */
    fun pad(k: Int, side: Int, on: Boolean) {
        val d = sides[side]
        send(DeckBridgeMap.pad(k, d.padBank, d.deck, on, shift && d.padBank == DeckBridgeMap.PadBank.HOT_CUE))
    }
    fun setPadBank(b: DeckBridgeMap.PadBank, side: Int) {
        sides[side].padBank = b
        button(b.mode, side, true); button(b.mode, side, false)
        changed()
    }
    fun value(c: BridgeControl, side: Int, v: Double) {
        val d = sides[side]
        when (c) {
            BridgeControl.TEMPO -> d.tempo = v; BridgeControl.TRIM -> d.trim = v; BridgeControl.EQ_HIGH -> d.hi = v
            BridgeControl.EQ_MID -> d.mid = v; BridgeControl.EQ_LOW -> d.low = v; BridgeControl.CHANNEL_FADER -> d.fader = v
            BridgeControl.FILTER -> d.filter = v
            else -> {}
        }
        send(DeckBridgeMap.value(c, d.deck, if (c == BridgeControl.TEMPO && invertTempo) 1 - v else v))
    }
    fun setXfader(v: Double) { xfader = v; send(DeckBridgeMap.value(BridgeControl.CROSSFADER, 0, v)) }
    fun setFxDepth(v: Double) { fxDepth = v; send(DeckBridgeMap.value(BridgeControl.FX_DEPTH, 0, v)) }
    fun toggleFxAssign(side: Int) {
        val d = sides[side].deck
        fxAssign[d] = !fxAssign[d]
        send(DeckBridgeMap.button(BridgeControl.FX_ASSIGN, d, true)); send(DeckBridgeMap.button(BridgeControl.FX_ASSIGN, d, false))
        changed()
    }

    // The platter seeks. rekordbox takes no jog wheel from a generic MIDI device, so while it turns it holds down
    // rekordbox's search button in the direction it's turning, and lets go when it stops.
    private val jogHeld = arrayOfNulls<BridgeControl>(2)
    private val jogRelease = arrayOfNulls<Runnable>(2)
    private val jogTravel = DoubleArray(2)
    fun jog(side: Int, degrees: Double) {
        val d = sides[side]
        d.jogAngle += degrees
        // a slow turn moves a fraction of a degree per touch event: add them up so it still counts
        jogTravel[side] += degrees
        if (abs(jogTravel[side]) < 0.5) return
        val turn = jogTravel[side]
        jogTravel[side] = 0.0
        val want = if (turn > 0) BridgeControl.SEARCH_FWD else BridgeControl.SEARCH_REV
        if (jogHeld[side] != want) {
            jogHeld[side]?.let { button(it, side, false) }
            button(want, side, true)
            jogHeld[side] = want
        }
        // let go once the platter stops turning (sooner the more sensitive the setting)
        jogRelease[side]?.let(main::removeCallbacks)
        val w = Runnable { jogLetGo(side) }
        jogRelease[side] = w
        main.postDelayed(w, (150 / max(0.5, jogSensitivity)).toLong())
    }
    fun jogLetGo(side: Int) {
        jogRelease[side]?.let(main::removeCallbacks); jogRelease[side] = null
        jogTravel[side] = 0.0
        jogHeld[side]?.let { button(it, side, false); jogHeld[side] = null }
    }
    fun jogTouch(side: Int, on: Boolean) { sides[side].jogTouched = on; if (!on) jogLetGo(side) }
    fun browse(ticks: Int) = send(DeckBridgeMap.relative(BridgeControl.BROWSE, 0, ticks))
    fun load(side: Int) { button(BridgeControl.LOAD, side, true); button(BridgeControl.LOAD, side, false) }

    // ---- in: rekordbox's lights ----
    private fun heard(m: IntArray) {
        lastHeard = hostSeconds()
        when (val f = DeckBridgeMap.feedback(m.toList()) ?: return) {
            is DeckBridgeMap.Feedback.Button -> sides.firstOrNull { it.deck == f.deck }?.set(f.c, f.on)
            is DeckBridgeMap.Feedback.HotCue -> sides.firstOrNull { it.deck == f.deck }?.let { it.hot[f.k] = f.on; it.padLit[0][f.k] = f.on }
            is DeckBridgeMap.Feedback.Pad -> sides.firstOrNull { it.deck == f.deck }?.let { it.padLit[f.bank.ordinal][f.k] = f.on }
            is DeckBridgeMap.Feedback.Fx -> fxOn = f.on
        }
        changed()
    }

    // ---- the mapping file, for rekordbox's MIDI → IMPORT: Downloads/Cratebox, where a USB cable or a share finds it ----
    fun writeMapping(): Uri? {
        val name = "Cratebox Deck Bridge.midi.csv"
        val rel = "${Environment.DIRECTORY_DOWNLOADS}/Cratebox"
        val cr = app.contentResolver
        return try {
            // replace the copy this app wrote before
            cr.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?", arrayOf(name, "$rel/"))
            val uri = cr.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name); put(MediaStore.MediaColumns.MIME_TYPE, "text/csv"); put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
            }) ?: return null
            cr.openOutputStream(uri)!!.use { it.write(DeckBridgeMap.rekordboxCSV().toByteArray()) }
            uri
        } catch (e: Exception) { status = "Couldn't write the mapping file: ${e.message}"; null }
    }
}
