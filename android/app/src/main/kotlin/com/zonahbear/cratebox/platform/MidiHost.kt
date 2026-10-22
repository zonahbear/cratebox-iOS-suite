// android.media.midi (MIDIHost.swift on iOS): finds the controller (a chosen one, else the first Pioneer/AlphaTheta,
// else any), feeds its messages to the controller engine on the main thread, and sends lights, init and keep-alive
// back. USB class-compliant controllers (the FLX4) show up here with no driver; Bluetooth MIDI needs pairing first.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import com.zonahbear.cratebox.core.MidiFramer
import com.zonahbear.cratebox.core.Profiles

@Suppress("DEPRECATION")      // getDevices / registerDeviceCallback(callback, handler): fine on every Android Cratebox runs on
class MidiHost(context: Context) {
    private val app = context.applicationContext
    private val mm = app.getSystemService(Context.MIDI_SERVICE) as MidiManager?
    private val prefs = app.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())

    private var device: MidiDevice? = null
    private var outPort: MidiOutputPort? = null        // the controller → us
    private var inPort: MidiInputPort? = null          // us → the controller
    private var openingId = -1
    var deviceName = ""; private set
    var available: List<String> = emptyList(); private set
    var preferred: String
        get() = prefs.getString("cb.midiIn", "") ?: ""
        set(v) { prefs.edit().putString("cb.midiIn", v).apply(); bind() }
    var onMessage: (IntArray) -> Unit = {}
    var onChange: (String) -> Unit = {}
    /** demo mode: messages Performance Mode sent to the stand-in controller */
    var virtualReceived = 0; private set
    private var virtual = false

    val supported get() = mm != null

    private val callback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(info: MidiDeviceInfo) = bind()
        override fun onDeviceRemoved(info: MidiDeviceInfo) = bind()
    }

    // the stream framed into messages, on the port's own thread, handed to the main thread
    private val framer = MidiFramer { m -> main.post { onMessage(m) } }
    private val receiver = object : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            synchronized(framer) { framer.feed(msg, offset, count) }
        }
    }

    fun start() {
        mm?.registerDeviceCallback(callback, main)
        bind()
    }

    fun shutdown() {
        mm?.unregisterDeviceCallback(callback)
        close()
    }

    companion object {
        fun name(i: MidiDeviceInfo): String {
            val p = i.properties
            return p.getString(MidiDeviceInfo.PROPERTY_NAME)?.takeIf { it.isNotBlank() }
                ?: p.getString(MidiDeviceInfo.PROPERTY_PRODUCT)?.takeIf { it.isNotBlank() }
                ?: "MIDI device"
        }
        /** Deck Bridge's own links (the phone as a USB MIDI peripheral, a network session) are never picked by
         *  themselves as Performance Mode's controller */
        private val bridge = Regex("Cratebox Deck Bridge|Android USB Peripheral|Network Session", RegexOption.IGNORE_CASE)
        fun isBridgeEndpoint(i: MidiDeviceInfo) = bridge.containsMatchIn(name(i))
    }

    /** a stand-in FLX4 for the simulator runs (demo mode): nothing is opened, lights are just counted */
    fun makeVirtualFLX4() { close(); virtual = true; deviceName = "DDJ-FLX4"; onChange(deviceName) }
    /** as if the controller sent it */
    fun injectFromVirtual(bytes: IntArray) { if (virtual && bytes.size == 3) main.post { onMessage(bytes) } }

    private fun close() {
        runCatching { outPort?.disconnect(receiver) }
        runCatching { outPort?.close() }; runCatching { inPort?.close() }; runCatching { device?.close() }
        outPort = null; inPort = null; device = null
    }

    fun bind() {
        if (virtual) return
        val m = mm ?: run { deviceName = ""; onChange(""); return }
        val srcs = m.devices.filter { it.outputPortCount > 0 }
        available = srcs.map(::name)
        val auto = srcs.filter { !isBridgeEndpoint(it) }
        val pref = preferred
        val pick = srcs.firstOrNull { name(it) == pref }
            ?: auto.firstOrNull { Profiles.pioneerish.matcher(name(it)).find() }
            ?: auto.firstOrNull()
        val cur = device?.info
        if (pick != null && cur != null && pick.id == cur.id) return       // already on it
        close()
        if (pick == null) { deviceName = ""; onChange(""); return }
        openingId = pick.id
        m.openDevice(pick, { d ->
            if (d == null || openingId != pick.id) { runCatching { d?.close() }; if (d == null) { deviceName = ""; onChange("") }; return@openDevice }
            device = d
            outPort = d.openOutputPort(0)?.also { it.connect(receiver) }
            // the output: port 0 of the same device (controllers pair their in and out on one USB device)
            inPort = if (pick.inputPortCount > 0) d.openInputPort(0) else null
            deviceName = name(pick)
            onChange(deviceName)
        }, main)
    }

    /** a channel message or a whole sysex, as bytes 0-255 */
    fun send(bytes: IntArray) {
        if (bytes.isEmpty()) return
        if (virtual) { virtualReceived++; return }
        val p = inPort ?: return
        val b = ByteArray(bytes.size) { bytes[it].toByte() }
        runCatching { p.send(b, 0, b.size) }
    }
}
