// TrueCurve on Android, the device side (PuffcoBle.swift on iOS): the Puffco Lorax protocol over BluetoothGatt,
// and a simulator with the same interface. Everything runs on the main thread as small suspending reads/writes
// (~5 a second during a curve); the audio renders on its own thread and never waits on any of it. The byte
// formats live in core (Lorax), with tests.
package com.zonahbear.cratebox.platform

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.zonahbear.cratebox.core.Lorax
import com.zonahbear.cratebox.core.TrueCurve
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.random.Random

class SlotBackup(val temp: List<Int>?, val time: List<Int>?)
class HeatError(message: String) : Exception(message)

/** what the runner needs from a device (the Puffco or the simulator); all on the main thread */
interface HeatDevice {
    val name: String
    val id: String
    val connected: Boolean
    var onDisconnect: (() -> Unit)?
    suspend fun connect()
    fun disconnect()
    suspend fun readTemp(): Double?
    suspend fun readState(): Int?
    suspend fun readBattery(): Int?
    suspend fun readActiveSlot(): Int?
    suspend fun setActiveSlot(s: Int): Boolean
    suspend fun backupSlot(s: Int): SlotBackup
    suspend fun restoreSlot(s: Int, b: SlotBackup)
    suspend fun writeProfileTemp(s: Int, f: Double): Boolean
    suspend fun writeProfileTime(s: Int, secs: Double): Boolean
    suspend fun start(): Boolean
    suspend fun stop(): Boolean
    suspend fun probeLiveFormat()
    suspend fun setLiveTarget(f: Double): Boolean
}

private val SVC = UUID.fromString(Lorax.SERVICE)
private val SVC_LEGACY = UUID.fromString(Lorax.SERVICE_LEGACY)
private val CH_CMD = UUID.fromString(Lorax.CMD)
private val CH_REPLY = UUID.fromString(Lorax.REPLY)
private val CH_VER = UUID.fromString(Lorax.VERSION)
private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
private typealias P = Lorax.Path

/** Needs BLUETOOTH_CONNECT (Android 12+), which HeatController asks for before it gets here. */
@SuppressLint("MissingPermission")
@Suppress("DEPRECATION")      // the pre-Android-13 GATT write/notify calls, used only below API 33
class PuffcoBle(private val context: Context, val device: BluetoothDevice, override val name: String) : HeatDevice {
    companion object {
        val services: List<UUID> = listOf(SVC, SVC_LEGACY)
    }
    override val id: String get() = device.address
    val isProxy = Regex("prox|pivot", RegexOption.IGNORE_CASE).containsMatchIn(name)
    override var connected = false; private set
    override var onDisconnect: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var gatt: BluetoothGatt? = null
    private var cmd: BluetoothGattCharacteristic? = null
    private var reply: BluetoothGattCharacteristic? = null
    private var seq = 0
    private val pending = HashMap<Int, CompletableDeferred<Pair<Int, List<Int>>>>()
    // one request at a time, like the web app's promise queue
    private val lock = Mutex()
    // the connection step being waited on (connect, discovery, pairing read, subscribe)
    private var step: CompletableDeferred<Unit>? = null
    private var withResp = true
    private var fmt = Lorax.Fmt.F32
    private var liveFmt: Lorax.Fmt? = null
    private var tempPath = P.TEMP
    private val soc = Lorax.SocDecoder()

    // GATT callbacks come on a binder thread; everything is handed to the main thread
    private val cb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (g !== gatt) return@post
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) finishStep(null)
                else if (newState == BluetoothProfile.STATE_DISCONNECTED) lost(status)
            }
        }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) { main.post { finishStep(gattError(status)) } }
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) { main.post { finishStep(gattError(status)) } }
        @Deprecated("Android 12 and older") override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) { main.post { finishStep(gattError(status)) } }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) { main.post { finishStep(gattError(status)) } }
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            if (ch.uuid == CH_REPLY) { val v = value.copyOf(); main.post { onReply(v) } }
        }
        @Deprecated("Android 12 and older") override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid == CH_REPLY) { val v = ch.value?.copyOf() ?: return; main.post { onReply(v) } }
        }
    }

    private fun gattError(status: Int): Exception? = when (status) {
        BluetoothGatt.GATT_SUCCESS -> null
        BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION, BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION -> HeatError("insufficient authentication (not paired)")
        else -> HeatError("Bluetooth error $status")
    }

    override suspend fun connect() {
        // the link often drops right after connecting (worst on Proxy), so connect + discovery are retried together
        var svc: BluetoothGattService? = null
        for (i in 1..3) {
            try {
                awaitStep(12_000) {
                    gatt?.close()
                    gatt = if (Build.VERSION.SDK_INT >= 26) device.connectGatt(context, false, cb, BluetoothDevice.TRANSPORT_LE)
                           else device.connectGatt(context, false, cb)
                }
                delay(300)
                awaitStep(10_000) { if (gatt?.discoverServices() != true) finishStep(HeatError("service discovery didn't start")) }
                svc = gatt?.getService(SVC) ?: gatt?.getService(SVC_LEGACY)
                    ?: throw HeatError("this isn't a Puffco (no Lorax service)")
                break
            } catch (e: Exception) {
                gatt?.disconnect(); gatt?.close(); gatt = null
                if (i == 3) throw e
                delay(800L * i)
            }
        }
        val s = svc ?: throw HeatError("no Lorax service")
        val g = gatt!!
        val c = s.getCharacteristic(CH_CMD); val r = s.getCharacteristic(CH_REPLY)
        if (c == null || r == null) { disconnect(); throw HeatError("the device's command characteristics are missing") }
        cmd = c; reply = r
        // reading the version is encrypted: Android starts pairing here; give the user time to accept the prompt
        s.getCharacteristic(CH_VER)?.let { v -> runCatching { awaitStep(30_000) { if (!g.readCharacteristic(v)) finishStep(HeatError("read didn't start")) } } }
        // subscribing fails with "insufficient authentication" until pairing is done
        var subscribed = false
        for (k in 1..3) {
            try { subscribe(g, r, true); subscribed = true; break } catch (_: Exception) { delay(1500) }
        }
        if (!subscribed) { disconnect(); throw HeatError("couldn't subscribe to the device; accept the pairing prompt and try again") }
        delay(150)
        connected = true
        val props = c.properties
        val canW = props and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
        val canWnr = props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        val both = canW && canWnr
        withResp = canW || !canWnr
        // unauthenticated clients get dropped after ~10 s, so the handshake has to land
        val authProblem = { m: String -> Regex("not paired|insufficient auth|encrypt", RegexOption.IGNORE_CASE).containsMatchIn(m) }
        var why = ""
        for (i in 1..3) {
            why = auth()
            if (why == "ok" || authProblem(why)) break
            if (i == 1 && both) withResp = !withResp
            if (i == 2) {
                runCatching { subscribe(g, r, false) }; delay(300)
                runCatching { subscribe(g, r, true) }; delay(300)
            }
        }
        if (why != "ok") {
            connected = false; g.disconnect()
            throw HeatError(if (authProblem(why)) "pair the device in the phone's Bluetooth settings first" else "handshake failed ($why); is the Puffco app connected to it?")
        }
        fmt = Lorax.detectFormat(read(P.pTemp(0), 4), isProxy)
    }

    private suspend fun subscribe(g: BluetoothGatt, r: BluetoothGattCharacteristic, on: Boolean) {
        g.setCharacteristicNotification(r, on)
        val d = r.getDescriptor(CCCD) ?: return
        val v = if (on) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        awaitStep(15_000) {
            val ok = if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(d, v) == BluetoothGatt.GATT_SUCCESS
                     else { d.value = v; g.writeDescriptor(d) }
            if (!ok) finishStep(HeatError("subscribe didn't start"))
        }
    }

    override fun disconnect() {
        val was = connected
        connected = false
        gatt?.disconnect()
        failPending()
        if (was) onDisconnect?.invoke()
    }

    private fun lost(status: Int) {
        finishStep(HeatError("the device disconnected" + if (status != 0) " (status $status)" else ""))
        if (!connected) return
        connected = false
        failPending()
        gatt?.close(); gatt = null
        onDisconnect?.invoke()
    }
    private fun failPending() {
        for (k in pending.values) k.completeExceptionally(HeatError("Device disconnected"))
        pending.clear()
    }

    private suspend fun awaitStep(ms: Long, start: () -> Unit) {
        val k = CompletableDeferred<Unit>()
        step = k
        start()
        try { withTimeout(ms) { k.await() } }
        catch (e: TimeoutCancellationException) { throw HeatError("the device didn't answer") }
        finally { if (step === k) step = null }
    }
    private fun finishStep(e: Exception?) {
        val k = step ?: return
        step = null
        if (e != null) k.completeExceptionally(e) else k.complete(Unit)
    }

    private suspend fun send(op: Int, payload: List<Int> = emptyList(), timeoutMs: Long = 3000): Pair<Int, List<Int>> = lock.withLock {
        val c = cmd; val g = gatt
        if (!connected || c == null || g == null) throw HeatError("Device is not connected")
        seq = (seq + 1) and 0xffff; if (seq == 0) seq = 1
        val s = seq
        val frame = Lorax.frame(s, op, payload).let { f -> ByteArray(f.size) { f[it].toByte() } }
        val k = CompletableDeferred<Pair<Int, List<Int>>>()
        pending[s] = k
        val type = if (withResp) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val ok = if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, frame, type) == BluetoothGatt.GATT_SUCCESS
                 else { c.writeType = type; c.value = frame; g.writeCharacteristic(c) }
        if (!ok) { pending.remove(s); throw HeatError("the write didn't go out") }
        try { withTimeout(timeoutMs) { k.await() } }
        catch (e: TimeoutCancellationException) { throw HeatError("BLE reply timed out") }
        finally { pending.remove(s) }
    }
    private fun onReply(b: ByteArray) {
        if (b.size < 3) return
        val s = (b[0].toInt() and 0xff) or ((b[1].toInt() and 0xff) shl 8)
        pending.remove(s)?.complete((b[2].toInt() and 0xff) to b.drop(3).map { it.toInt() and 0xff })
    }

    private suspend fun auth(): String = try {
        val (st, seed) = send(0)
        if (st != 0 || seed.size < 16) "seed request returned status $st"
        else { val (ok, _) = send(1, Lorax.token(seed)); if (ok == 0) "ok" else "unlock returned status $ok" }
    } catch (e: Exception) {
        val m = e.message ?: e.toString()
        if (m.contains("timed out")) "no reply from device" else m
    }

    suspend fun read(path: String, max: Int = 64): List<Int>? {
        val r = runCatching { send(16, Lorax.readPayload(path, max)) }.getOrNull() ?: return null
        return if (r.first == 0) r.second else null
    }
    suspend fun write(path: String, bytes: List<Int>): Boolean =
        runCatching { send(17, Lorax.writePayload(path, bytes)) }.getOrNull()?.first == 0

    override suspend fun readTemp(): Double? {
        for (path in if (tempPath == P.TEMP_ALT) listOf(P.TEMP_ALT, P.TEMP) else listOf(P.TEMP, P.TEMP_ALT)) {
            val c = Lorax.decodeC(read(path, 4), fmt)
            if (c != null && c > 0) { tempPath = path; return (TrueCurve.cToF(c) * 10).roundToLong() / 10.0 }
        }
        return null
    }
    override suspend fun readState(): Int? = read(P.STATE, 1)?.firstOrNull()
    override suspend fun readBattery(): Int? = soc.decode(read(P.SOC, 4))
    override suspend fun readActiveSlot(): Int? = read(P.SLOT, 1)?.firstOrNull()
    override suspend fun setActiveSlot(s: Int): Boolean = write(P.SLOT, listOf(s))
    override suspend fun backupSlot(s: Int) = SlotBackup(read(P.pTemp(s), 4), read(P.pTime(s), 4))
    override suspend fun restoreSlot(s: Int, b: SlotBackup) {
        b.temp?.takeIf { it.size >= 4 }?.let { write(P.pTemp(s), it.take(4)) }
        b.time?.takeIf { it.size >= 4 }?.let { write(P.pTime(s), it.take(4)) }
    }
    override suspend fun writeProfileTemp(s: Int, f: Double): Boolean {
        val c = TrueCurve.fToC(min(TrueCurve.MAX_F, max(TrueCurve.MIN_F, f)))
        for (fm in listOf(fmt, if (fmt == Lorax.Fmt.I10) Lorax.Fmt.F32 else Lorax.Fmt.I10)) {
            if (!write(P.pTemp(s), Lorax.encodeC(c, fm))) continue
            val b = read(P.pTemp(s), 4)
            if (b != null && b.size >= 4 && !(abs(Lorax.decodeAs(b, fm) - c) <= 1.5)) continue
            fmt = fm
            return true
        }
        return false
    }
    /** Peak Pro: heat time in float seconds. Proxy units vary by firmware, so it's left alone and the run ends the session. */
    override suspend fun writeProfileTime(s: Int, secs: Double): Boolean {
        if (isProxy) return false
        if (!write(P.pTime(s), Lorax.f32Bytes(secs))) return false
        val r = read(P.pTime(s), 4)
        if (r == null || r.size < 4) return true
        return abs(Lorax.f32(r) - secs) <= 1
    }
    override suspend fun start(): Boolean = write(P.MODE, listOf(7))
    override suspend fun stop(): Boolean {
        var ok = false
        repeat(3) { if (write(P.MODE, listOf(8))) ok = true; delay(45) }
        return ok
    }
    override suspend fun probeLiveFormat() { Lorax.detectLiveFormat(read(P.LIVE, 4))?.let { liveFmt = it } }
    override suspend fun setLiveTarget(f: Double): Boolean {
        val c = TrueCurve.fToC(min(TrueCurve.MAX_F, max(TrueCurve.MIN_F, f)))
        val first = liveFmt ?: fmt
        for (fm in listOf(first, if (first == Lorax.Fmt.I10) Lorax.Fmt.F32 else Lorax.Fmt.I10)) {
            if (write(P.LIVE, Lorax.encodeC(c, fm))) { liveFmt = fm; return true }
        }
        return false
    }

    /** let go of the GATT client for good */
    fun close() { gatt?.close(); gatt = null }
}

/** the web app's simulator: TrueCurve.SimHeater ticking in real time, with a little I/O delay and sensor noise */
class SimPuffco : HeatDevice {
    override val name = "Simulator"
    override val id = "sim"
    override var connected = false; private set
    override var onDisconnect: (() -> Unit)? = null
    private val h = TrueCurve.SimHeater()
    private val main = Handler(Looper.getMainLooper())
    private var last = 0L
    private val tick = object : Runnable {
        override fun run() {
            if (!connected) return
            val t = SystemClock.elapsedRealtime()
            var dt = min((t - last) / 1000.0, 5.0)
            last = t
            while (dt > 0) { val s = min(dt, 0.1); h.advance(s); dt -= s }
            main.postDelayed(this, 100)
        }
    }

    override suspend fun connect() { connected = true; last = SystemClock.elapsedRealtime(); main.post(tick) }
    override fun disconnect() { main.removeCallbacks(tick); val was = connected; connected = false; if (was) onDisconnect?.invoke() }
    private suspend fun io() = delay(30L + Random.nextLong(30))
    override suspend fun readTemp(): Double { io(); return ((h.y + Random.nextDouble(-0.6, 0.6)) * 10).roundToLong() / 10.0 }
    override suspend fun readState(): Int { io(); return h.state }
    override suspend fun readBattery() = 87
    override suspend fun readActiveSlot() = h.slotIdx
    override suspend fun setActiveSlot(s: Int): Boolean { h.slotIdx = s; return true }
    override suspend fun backupSlot(s: Int) = SlotBackup(Lorax.f32Bytes(h.slots[s].temp), Lorax.f32Bytes(h.slots[s].time))
    override suspend fun restoreSlot(s: Int, b: SlotBackup) {
        b.temp?.takeIf { it.size >= 4 }?.let { h.slots[s].temp = Lorax.f32(it) }
        b.time?.takeIf { it.size >= 4 }?.let { h.slots[s].time = Lorax.f32(it) }
    }
    override suspend fun writeProfileTemp(s: Int, f: Double): Boolean { io(); h.slots[s].temp = f; return true }
    override suspend fun writeProfileTime(s: Int, secs: Double): Boolean { io(); h.slots[s].time = secs; return true }
    override suspend fun start(): Boolean { io(); h.start(); return true }
    override suspend fun stop(): Boolean { io(); h.stop(); return true }
    override suspend fun probeLiveFormat() {}
    override suspend fun setLiveTarget(f: Double): Boolean { io(); h.setLiveTarget(f); return true }
}
