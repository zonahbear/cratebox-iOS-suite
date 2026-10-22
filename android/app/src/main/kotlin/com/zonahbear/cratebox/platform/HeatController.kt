// TrueCurve on Android, the runner (HeatController.swift on iOS): pick a curve, press Start, go back to the decks.
// Back up profile slot 4, write the curve's start temperature, preheat, then steer the live target ~5 times a
// second with the predictive driver, and put the slot back after. Safety rules kept from TrueCurve: 600°F cutoff,
// targets clamped 350–590°F, and on a lost link the device finishes its own cycle. Runs on the main thread as
// small suspending calls; it never touches the audio engine, so playback carries on while the device heats.
//
// The UI asks for `missingPermissions()` (Bluetooth scan/connect on Android 12+, location before that) and calls
// scan() once they're granted. State changes call `onChange`, which the screen turns into recomposition.
package com.zonahbear.cratebox.platform

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import com.zonahbear.cratebox.core.TrueCurve
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

@SuppressLint("MissingPermission")         // every Bluetooth call is behind missingPermissions() / a SecurityException catch
class HeatController(context: Context) {
    enum class Phase { IDLE, PREP, PREHEAT, RUNNING }
    class Found(val id: String, val name: String, val device: BluetoothDevice)

    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    private val scope = Main.scope()
    private val bm = app.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?

    var dev: HeatDevice? = null; private set
    var phase = Phase.IDLE; private set
    /** the HEAT button's text and the panel's device line */
    var label = "HEAT"; private set
    var devText = "No device"; private set
    var msg = ""; private set
    var name: String = prefs.getString("cb.tc.last", null) ?: TrueCurve.DEFAULT_NAME
        set(v) { field = v; prefs.edit().putString("cb.tc.last", v).apply(); changed() }
    /** curves pasted from TrueCurve ({name: {points, smooth}}, same JSON as its tc_curves) */
    var saved: Map<String, TrueCurve.CurveDef> = TrueCurve.parseCurves(prefs.getString("cb.tc.curves", null) ?: "{}") ?: emptyMap(); private set
    val found = ArrayList<Found>()
    /** other named Bluetooth devices nearby, offered when no Puffco is recognised (a renamed device, say) */
    val others = ArrayList<Found>()
    var scanning = false; private set
    val running get() = phase != Phase.IDLE
    val connected get() = dev != null
    var panelOpen = false
    var onStatus: ((String) -> Unit)? = null
    var onChange: (() -> Unit)? = null

    private var live: Double? = null; private var target: Double? = null; private var t: Double? = null
    private var end = 0.0; private var battery: Int? = null
    private var abort = false
    private var ble: PuffcoBle? = null
    private var idleJob: Job? = null
    private var scanStop: Job? = null

    init { if (name !in curveNames) name = TrueCurve.DEFAULT_NAME }

    /** presets (unless a pasted curve has the same name), then the pasted ones */
    val presetNames get() = TrueCurve.presets.map { it.first }.filter { saved[it] == null }
    val savedNames get() = saved.keys.sorted()
    val curveNames get() = presetNames + savedNames
    fun curveDef(n: String): TrueCurve.CurveDef =
        saved[n]?.takeIf { it.points.size >= 2 } ?: TrueCurve.preset(n) ?: TrueCurve.preset(TrueCurve.DEFAULT_NAME)!!

    private fun changed() = onChange?.invoke()
    private fun say(m: String) { msg = m; render() }
    private fun f0(v: Double?) = v?.roundToInt()?.toString() ?: "--"
    private fun render() {
        label = when (phase) {
            Phase.IDLE -> "HEAT"
            Phase.PREP -> "HEAT…"
            Phase.PREHEAT -> "HEAT ${f0(live)}° ↑${f0(target)}"
            Phase.RUNNING -> "HEAT ${f0(live)}° ${(t ?: 0.0).toInt()}/${end.roundToInt()}s"
        }
        val bat = battery?.let { " · $it%" } ?: ""
        devText = dev?.let { "${it.name}$bat · bowl ${f0(live)}°F" } ?: "No device"
        changed()
    }

    // ---- permissions ----

    fun missingPermissions(): List<String> {
        val need = if (Build.VERSION.SDK_INT >= 31) listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
                   else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        return need.filter { app.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
    }

    // ---- connecting ----

    private val services = PuffcoBle.services.map { it.toString() }
    private fun looksPuffco(name: String) = listOf("peak", "prox", "puff", "pivot").any { name.lowercase().startsWith(it) }

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, r: ScanResult) {
            val rec = r.scanRecord
            val name = r.device.name ?: rec?.deviceName ?: ""
            // like the web app's filters: the Lorax service, a Puffco name, or Puffco's Bluetooth company id (0x0c03)
            val puffco = rec?.serviceUuids?.any { it.uuid.toString().lowercase() in services } == true ||
                looksPuffco(name) || rec?.getManufacturerSpecificData(0x0c03) != null
            scope.launch { add(r.device, name, puffco) }
        }
        override fun onScanFailed(errorCode: Int) { scope.launch { stopScan(); say("Bluetooth scan failed ($errorCode). Turn Bluetooth off and on, and try again.") } }
    }

    /** look for a Puffco; the one used last time connects by itself, others are listed to pick from */
    fun scan() {
        found.clear(); others.clear()
        if (missingPermissions().isNotEmpty()) { say("Cratebox Suite isn't allowed to use Bluetooth: allow Nearby devices in its app settings."); return }
        val adapter = bm?.adapter ?: run { say("This device has no Bluetooth LE."); return }
        if (!adapter.isEnabled) { say("Bluetooth is off."); return }
        val scanner = adapter.bluetoothLeScanner ?: run { say("Bluetooth is off."); return }
        scanning = true
        say("Looking for your Puffco… (wake it up if it's asleep)")
        try {
            // a Puffco already connected to the phone (the Puffco app holding it) stops advertising, so a scan never
            // sees it; the connected and bonded ones with a Puffco name are offered straight away
            for (d in bm.getConnectedDevices(BluetoothProfile.GATT)) add(d, d.name ?: "", d.name?.let(::looksPuffco) ?: false)
            for (d in adapter.bondedDevices) d.name?.let { if (looksPuffco(it)) add(d, it, true) }
            scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCb)
        } catch (e: SecurityException) { stopScan(); say("Cratebox Suite isn't allowed to use Bluetooth: allow Nearby devices in its app settings."); return }
        scanStop?.cancel()
        scanStop = scope.launch {
            delay(15_000)
            if (!scanning) return@launch
            stopScan()
            if (dev == null && ble == null) say(when {
                found.isNotEmpty() -> "Pick your device."
                others.isEmpty() -> "No Bluetooth devices found. Is Bluetooth on, and the Puffco awake?"
                else -> "No Puffco recognised. If yours has its own name, pick it from the list below."
            })
        }
    }

    private fun stopScan() {
        if (scanning) runCatching { bm?.adapter?.bluetoothLeScanner?.stopScan(scanCb) }
        scanning = false
        changed()
    }

    private fun add(d: BluetoothDevice, name: String, puffco: Boolean) {
        if (!scanning || found.any { it.id == d.address }) return
        val f = Found(d.address, name.ifEmpty { "Puffco" }, d)
        if (!puffco) {
            if (name.isNotEmpty() && others.size < 12 && others.none { it.id == d.address }) { others.add(f); changed() }
            return
        }
        others.removeAll { it.id == d.address }
        found.add(f)
        if (d.address == prefs.getString("cb.tc.device", null)) pick(f)
        else if (found.size == 1) say("Found ${f.name}. Tap it to connect.") else changed()
    }

    fun pick(f: Found) {
        if (ble != null) return
        stopScan()
        val b = PuffcoBle(app, f.device, f.name)
        ble = b
        connect(b)
    }
    fun useSimulator() { stopScan(); connect(SimPuffco()) }
    fun disconnect() { dev?.disconnect() }

    private fun connect(d: HeatDevice) {
        say(if (d is SimPuffco) "Starting the simulator…" else "Connecting to ${d.name}… (accept the pairing prompt if one comes up)")
        d.onDisconnect = {
            if (running) abort = true
            dev = null; ble?.close(); ble = null
            say(if (running) "Connection lost mid-curve; the device finishes its own cycle at its last temperature." else "Disconnected.")
        }
        scope.launch {
            try {
                d.connect()
                dev = d
                if (d is PuffcoBle) prefs.edit().putString("cb.tc.device", d.id).apply()
                found.clear()
                say("Connected to ${d.name}.")
                idle()
            } catch (e: Exception) {
                ble?.close(); ble = null
                say("Couldn't connect: ${e.message}")
            }
        }
    }

    /** bowl temperature and battery while no curve runs (less often when the panel is closed) */
    private fun idle() {
        idleJob?.cancel()
        idleJob = scope.launch {
            var n = 0
            while (true) {
                val d = dev ?: break
                if (!d.connected) break
                if (!running) {
                    live = d.readTemp()
                    if (n % 30 == 0) battery = d.readBattery()
                    render()
                }
                n++
                delay(if (panelOpen) 1000 else 3000)
            }
        }
    }

    // ---- running a curve ----

    /** Start (then straight back to the decks: the HEAT button carries the temperature) or Stop */
    fun toggle() {
        if (running) { abort = true; say("Stopping…") }
        else if (dev != null) { phase = Phase.PREP; render(); val n = name; scope.launch { run(n) } }
    }

    private fun modelKey(d: HeatDevice) = "cb.tc.model." + d.id
    private fun now() = SystemClock.elapsedRealtimeNanos() / 1e9
    private fun heating(s: Int?) = s != null && s in TrueCurve.heating

    private suspend fun run(name: String) {
        val dev = dev ?: run { phase = Phase.IDLE; render(); return }
        val def = curveDef(name)
        val curve = TrueCurve.Curve.of(def.points, def.smooth) ?: run { phase = Phase.IDLE; say("That curve has no length."); return }
        val slot = TrueCurve.SLOT; val mk = modelKey(dev)
        val model = TrueCurve.parseModel(prefs.getString(mk, null)) ?: TrueCurve.HeaterModel()
        val drv = TrueCurve.Driver(curve, model); val learner = TrueCurve.Learner(model)
        var backup: SlotBackup? = null; var origSlot: Int? = null; var completed = false; var errSum = 0.0; var errN = 0
        abort = false; phase = Phase.PREP; t = null; end = curve.end; target = curve.at(0.0)
        say("Setting up \"$name\"…")

        suspend fun body() {
            if (heating(dev.readState())) { dev.stop(); delay(1500) }
            origSlot = dev.readActiveSlot()
            backup = dev.backupSlot(slot)
            val startF = curve.at(0.0).roundToLong().toDouble()
            if (!dev.writeProfileTemp(slot, startF)) throw HeatError("the device refused the start temperature")
            dev.writeProfileTime(slot, min(120.0, ceil(curve.end + 10)))
            dev.setActiveSlot(slot)
            if (!dev.start()) throw HeatError("the device didn't accept the start command")
            phase = Phase.PREHEAT; target = startF
            say("Preheating to ${startF.toInt()}°F. Back to the decks; it'll run on its own.")
            val p0 = now()
            while (!abort) {
                live = dev.readTemp()
                val st = dev.readState(); val tp = now() - p0; val y = live
                render()
                if (y != null && y >= TrueCurve.CUTOFF_F) throw HeatError("overheat cutoff at $y°F")
                // some firmware (Proxy) says "heating" long before the bowl is hot, so the temperature has to agree too
                if (y != null && (y >= startF - 8 || (heating(st) && st != 7 && y >= startF - 30))) break
                if (tp > 6 && !heating(st)) throw HeatError("the device stopped heating during preheat (at ${f0(y)}°F)")
                if (tp > 70) break
                delay(250)
            }
            if (abort) return
            dev.probeLiveFormat()
            phase = Phase.RUNNING
            say("Running \"$name\".")
            val t0 = now()
            var last = t0; var sent = startF; var sentAt = 0.0; var tick = 0
            while (!abort) {
                val tn = now(); val tt = tn - t0; val dt = tn - last
                last = tn
                if (tt >= curve.end) { completed = true; break }
                val y = dev.readTemp()
                if (tick % 3 == 0) {
                    val st = dev.readState()
                    if (tt > 2 && !heating(st)) { say("The device ended its heat cycle ${tt.roundToInt()} s in."); break }
                }
                tick++
                if (y != null && y >= TrueCurve.CUTOFF_F) throw HeatError("overheat cutoff at $y°F")
                val u = (drv.command(tt, y, dt) * 10).roundToLong() / 10.0
                val diff = abs(u - sent)
                if ((diff >= 1.5 || (diff >= 0.5 && tn - sentAt > 1.5)) && dev.setLiveTarget(u)) { sent = u; sentAt = tn }
                learner.add(tt, y, sent)
                val r = curve.at(tt)
                t = tt; live = y; target = r
                if (y != null && tt > 1) { errSum += abs(y - r); errN++ }
                render()
                delay(max(0L, ((0.2 - (now() - tn)) * 1000).toLong()))
            }
        }

        try { body() } catch (e: Exception) { say("Stopped: ${e.message}") }
        if (dev.connected) {
            dev.stop()
            backup?.let { dev.restoreSlot(slot, it) }
            origSlot?.let { dev.setActiveSlot(it) }
        }
        if (errN > 10) {
            say("${if (completed) "Done" else "Stopped"}: \"$name\", ${String.format(java.util.Locale.US, "%.1f", errSum / errN)}°F average off the curve.")
            if (learner.n > 15) {
                val m = learner.m.copy(dead = model.dead, runs = model.runs + 1)
                prefs.edit().putString(mk, TrueCurve.encodeModel(m)).apply()
            }
        } else if (abort && this.dev != null) say("Stopped.")
        phase = Phase.IDLE; t = null; target = null
        render()
        onStatus?.invoke(if (completed) "Heat curve \"$name\" done" else "Heat curve \"$name\" stopped")
    }

    /** paste the JSON from TrueCurve's "Copy curves for Cratebox" (the screen reads the clipboard) */
    fun paste(txt: String?) {
        if (txt.isNullOrEmpty()) { say("Nothing to paste: in TrueCurve, press Copy curves for Cratebox first."); return }
        val got = TrueCurve.parseCurves(txt) ?: run { say("That isn't TrueCurve's curve list."); return }
        if (got.isEmpty()) { say("No curves found in that text."); return }
        saved = saved + got
        prefs.edit().putString("cb.tc.curves", TrueCurve.encodeCurves(saved)).apply()
        say("Added ${got.size} curve${if (got.size > 1) "s" else ""}.")
    }
}
