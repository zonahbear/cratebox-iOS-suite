// A network MIDI session the way a Mac's Audio MIDI Setup (Network) and Windows' rtpMIDI expect (iOS's
// MIDINetworkSession, which Android doesn't have): Cratebox listens on a control port and the data port after it,
// advertises itself over Bonjour (_apple-midi._udp) so the computer lists it, accepts the computer's invitation,
// answers its clock syncs, and then sends and receives MIDI. The packets are core's AppleMidi.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.SystemClock
import com.zonahbear.cratebox.core.AppleMidi
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import kotlin.random.Random

class RtpMidiSession(context: Context, val name: String = "Cratebox Deck Bridge") {
    class Peer(val ssrc: Int, var name: String, val address: InetAddress, val controlPort: Int) {
        var dataPort = 0
        @Volatile var lastHeard = SystemClock.elapsedRealtime()
        val connected get() = dataPort != 0
    }

    private val app = context.applicationContext
    private val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager?
    private val ssrc = Random.nextInt()
    private var control: DatagramSocket? = null
    private var data: DatagramSocket? = null
    private val peers = ArrayList<Peer>()
    private var seq = Random.nextInt(0, 0xffff)
    @Volatile private var running = false
    // Android refuses network calls on the main thread: sends go out from here, in order
    private val out = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "cratebox-rtpmidi-out").apply { isDaemon = true } }
    var port = 0; private set
    /** messages from the computer (on a socket thread) */
    var onMessage: (IntArray) -> Unit = {}
    /** the peer list changed (on a socket thread) */
    var onPeers: () -> Unit = {}

    val connectedPeers: List<String> get() = synchronized(peers) { peers.filter { it.connected }.map { it.name } }

    /** timestamps in 100 µs units, as AppleMIDI counts them */
    private fun now100us() = SystemClock.elapsedRealtimeNanos() / 100_000

    private val registration = object : NsdManager.RegistrationListener {
        override fun onServiceRegistered(info: NsdServiceInfo) {}
        override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {}
        override fun onServiceUnregistered(info: NsdServiceInfo) {}
        override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
    }

    /** opens the ports (5004/5005, the usual pair, or the next free pair) and advertises them */
    fun start(): Boolean {
        if (running) return true
        for (p in 5004..5024 step 2) {
            try {
                val c = DatagramSocket(null).apply { reuseAddress = true; bind(InetSocketAddress(p)) }
                val d = try { DatagramSocket(null).apply { reuseAddress = true; bind(InetSocketAddress(p + 1)) } } catch (e: Exception) { c.close(); throw e }
                control = c; data = d; port = p
                break
            } catch (_: Exception) {}
        }
        val c = control ?: return false; val d = data ?: return false
        running = true
        Thread({ loop(c, isData = false) }, "cratebox-rtpmidi-ctl").apply { isDaemon = true }.start()
        Thread({ loop(d, isData = true) }, "cratebox-rtpmidi-data").apply { isDaemon = true }.start()
        runCatching {
            nsd?.registerService(NsdServiceInfo().apply { serviceName = name; serviceType = "_apple-midi._udp"; setPort(port) }, NsdManager.PROTOCOL_DNS_SD, registration)
        }
        return true
    }

    fun stop() {
        if (!running) return
        running = false
        val all = synchronized(peers) { peers.toList().also { peers.clear() } }
        val c = control; val d = data
        control = null; data = null
        out.execute {
            for (p in all) runCatching { sendTo(c, AppleMidi.encode(AppleMidi.Session.Bye(0, ssrc)), p.address, p.controlPort) }
            c?.close(); d?.close()
        }
        runCatching { nsd?.unregisterService(registration) }
        onPeers()
    }

    private fun sendTo(s: DatagramSocket?, b: ByteArray, a: InetAddress, port: Int) { s?.send(DatagramPacket(b, b.size, a, port)) }

    private fun loop(s: DatagramSocket, isData: Boolean) {
        val buf = ByteArray(2048)
        while (running) {
            val pk = DatagramPacket(buf, buf.size)
            try { s.receive(pk) } catch (_: Exception) { if (!running) return else continue }
            val n = pk.length
            if (AppleMidi.isSession(buf, n)) session(AppleMidi.decodeSession(buf, n) ?: continue, pk.address, pk.port, isData)
            else if (isData) {
                val d = AppleMidi.decodeData(buf, n) ?: continue
                synchronized(peers) { peers.firstOrNull { it.ssrc == d.ssrc } }?.lastHeard = SystemClock.elapsedRealtime()
                for (m in d.messages) onMessage(m)
            }
        }
    }

    private fun session(m: AppleMidi.Session, from: InetAddress, port: Int, isData: Boolean) {
        val sock = if (isData) data else control
        when (m) {
            is AppleMidi.Session.Invite -> {
                synchronized(peers) {
                    if (!isData) {
                        peers.removeAll { it.ssrc == m.ssrc }
                        peers.add(Peer(m.ssrc, m.name, from, port))
                    } else peers.firstOrNull { it.ssrc == m.ssrc }?.let { it.dataPort = port; it.lastHeard = SystemClock.elapsedRealtime() }
                }
                sendTo(sock, AppleMidi.encode(AppleMidi.Session.Accept(m.token, ssrc, name)), from, port)
                if (isData) onPeers()
            }
            is AppleMidi.Session.Clock -> {
                synchronized(peers) { peers.firstOrNull { it.ssrc == m.ssrc } }?.lastHeard = SystemClock.elapsedRealtime()
                // the computer starts (count 0); we answer with our time (count 1); its count 2 ends the exchange
                if (m.count == 0) sendTo(sock, AppleMidi.encode(AppleMidi.Session.Clock(ssrc, 1, m.t1, now100us(), 0)), from, port)
            }
            is AppleMidi.Session.Bye -> { synchronized(peers) { peers.removeAll { it.ssrc == m.ssrc } }; onPeers() }
            else -> {}
        }
    }

    /** drops computers that have gone quiet (no clock sync or data for a minute) */
    fun prune() {
        val cut = SystemClock.elapsedRealtime() - 60_000
        val gone = synchronized(peers) { peers.removeAll { it.lastHeard < cut } }
        if (gone) onPeers()
    }

    /** to every connected computer, in one packet */
    fun send(messages: List<List<Int>>) {
        val d = data ?: return
        val to = synchronized(peers) { peers.filter { it.connected } }
        if (to.isEmpty() || messages.isEmpty()) return
        seq = (seq + 1) and 0xffff
        val b = AppleMidi.dataPacket(seq, now100us().toInt(), ssrc, messages)
        out.execute { for (p in to) runCatching { sendTo(d, b, p.address, p.dataPort) } }
    }
}
