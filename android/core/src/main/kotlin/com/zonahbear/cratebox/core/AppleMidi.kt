// RTP-MIDI (RFC 6295) with Apple's session protocol ("AppleMIDI"), the bytes only: what a Mac's Network MIDI
// session and Windows' rtpMIDI speak. iOS has it built in (MIDINetworkSession); Android doesn't, so Deck Bridge
// carries its own. The app does the sockets (a control port and the data port right after it) and the Bonjour
// advert (_apple-midi._udp); this builds and reads the packets, with tests.
//
// Session packets: 0xFFFF, a two-letter command, then
//   IN / OK / NO / BY: protocol version (2), initiator token, SSRC, and (IN, OK) a name, null-terminated
//   CK: SSRC, count (0, 1, 2), 3 bytes padding, three 64-bit timestamps (100 µs units)
// Data packets: a 12-byte RTP header (version 2, payload type 97), then the MIDI command section: a header byte
// (B J Z P + length) and the commands, each after the first preceded by a delta time. Cratebox sends no journal
// (the J bit off), so a lost packet is a lost message, as on iOS's own session when the network drops one.
package com.zonahbear.cratebox.core

import java.nio.ByteBuffer

object AppleMidi {
    const val PROTOCOL = 2

    sealed class Session {
        data class Invite(val token: Int, val ssrc: Int, val name: String) : Session()
        data class Accept(val token: Int, val ssrc: Int, val name: String) : Session()
        data class Reject(val token: Int, val ssrc: Int) : Session()
        data class Bye(val token: Int, val ssrc: Int) : Session()
        data class Clock(val ssrc: Int, val count: Int, val t1: Long, val t2: Long, val t3: Long) : Session()
        data class Feedback(val ssrc: Int, val seq: Int) : Session()
    }

    fun isSession(b: ByteArray, n: Int = b.size) = n >= 4 && b[0] == 0xff.toByte() && b[1] == 0xff.toByte()

    fun encode(s: Session): ByteArray {
        fun head(cmd: String, extra: Int) = ByteBuffer.allocate(4 + extra).put(0xff.toByte()).put(0xff.toByte()).put(cmd.toByteArray(Charsets.US_ASCII))
        fun named(cmd: String, token: Int, ssrc: Int, name: String?): ByteArray {
            val nb = name?.toByteArray(Charsets.UTF_8)
            val b = head(cmd, 12 + (nb?.size?.plus(1) ?: 0)).putInt(PROTOCOL).putInt(token).putInt(ssrc)
            if (nb != null) b.put(nb).put(0)
            return b.array()
        }
        return when (s) {
            is Session.Invite -> named("IN", s.token, s.ssrc, s.name)
            is Session.Accept -> named("OK", s.token, s.ssrc, s.name)
            is Session.Reject -> named("NO", s.token, s.ssrc, null)
            is Session.Bye -> named("BY", s.token, s.ssrc, null)
            is Session.Clock -> head("CK", 32).putInt(s.ssrc).put(s.count.toByte()).put(0).put(0).put(0).putLong(s.t1).putLong(s.t2).putLong(s.t3).array()
            is Session.Feedback -> head("RS", 8).putInt(s.ssrc).putShort(s.seq.toShort()).putShort(0).array()
        }
    }

    fun decodeSession(b: ByteArray, n: Int = b.size): Session? {
        if (!isSession(b, n)) return null
        val bb = ByteBuffer.wrap(b, 0, n)
        bb.position(2)
        val cmd = String(byteArrayOf(bb.get(), bb.get()), Charsets.US_ASCII)
        fun name(): String {
            val start = bb.position()
            var end = start
            while (end < n && b[end] != 0.toByte()) end++
            return String(b, start, end - start, Charsets.UTF_8)
        }
        return try {
            when (cmd) {
                "IN", "OK", "NO", "BY" -> {
                    bb.int                                          // protocol version
                    val token = bb.int; val ssrc = bb.int
                    when (cmd) {
                        "IN" -> Session.Invite(token, ssrc, name())
                        "OK" -> Session.Accept(token, ssrc, name())
                        "NO" -> Session.Reject(token, ssrc)
                        else -> Session.Bye(token, ssrc)
                    }
                }
                "CK" -> { val ssrc = bb.int; val count = bb.get().toInt() and 0xff; bb.position(bb.position() + 3); Session.Clock(ssrc, count, bb.long, bb.long, bb.long) }
                "RS" -> { val ssrc = bb.int; Session.Feedback(ssrc, bb.short.toInt() and 0xffff) }
                else -> null
            }
        } catch (_: java.nio.BufferUnderflowException) { null }
    }

    /** an RTP-MIDI data packet carrying `messages` (each a whole MIDI message, bytes 0-255), all at `timestamp` */
    fun dataPacket(seq: Int, timestamp: Int, ssrc: Int, messages: List<List<Int>>): ByteArray {
        val cmds = java.io.ByteArrayOutputStream()
        for ((i, m) in messages.withIndex()) {
            if (i > 0) cmds.write(0)                                 // delta time 0
            for (x in m) cmds.write(x and 0xff)
        }
        val body = cmds.toByteArray()
        val out = ByteBuffer.allocate(12 + 2 + body.size)
        out.put(0x80.toByte()).put(0x61).putShort(seq.toShort()).putInt(timestamp).putInt(ssrc)
        if (body.size <= 15) out.put(body.size.toByte())             // B = 0: a 4-bit length
        else { if (body.size > 4095) throw IllegalArgumentException("too long for one packet"); out.put((0x80 or (body.size shr 8)).toByte()).put(body.size.toByte()) }
        out.put(body)
        return out.array().copyOf(out.position())
    }

    class Data(val ssrc: Int, val seq: Int, val messages: List<IntArray>)

    /** the MIDI messages in a data packet (null if it isn't one). Running status, delta times and real-time bytes
     *  are handled; sysex comes out whole when it's in one packet (segmented sysex is dropped). */
    fun decodeData(b: ByteArray, n: Int = b.size): Data? {
        if (n < 13 || (b[0].toInt() and 0xc0) != 0x80 || (b[1].toInt() and 0x7f) != 0x61) return null
        val seq = ((b[2].toInt() and 0xff) shl 8) or (b[3].toInt() and 0xff)
        val ssrc = ByteBuffer.wrap(b, 8, 4).int
        var p = 12
        val h = b[p++].toInt() and 0xff
        var len = h and 0x0f
        if (h and 0x80 != 0) { if (p >= n) return null; len = (len shl 8) or (b[p++].toInt() and 0xff) }
        val zFirstDelta = h and 0x20 != 0
        val end = minOf(n, p + len)
        val out = ArrayList<IntArray>()
        var running = 0
        var first = true
        fun skipDelta() { var k = 0; while (p < end && k < 4) { val x = b[p++].toInt() and 0xff; k++; if (x and 0x80 == 0) break } }
        while (p < end) {
            if (!first || zFirstDelta) skipDelta()
            first = false
            if (p >= end) break
            var st = b[p].toInt() and 0xff
            if (st >= 0x80) p++ else st = running
            if (st == 0) break                                        // data byte with no status to run on
            when {
                st >= 0xf8 -> out.add(intArrayOf(st))                 // real-time
                st == 0xf0 -> {
                    val s = p
                    while (p < end && (b[p].toInt() and 0xff) !in setOf(0xf7, 0xf0, 0xf4)) p++
                    val term = if (p < end) b[p++].toInt() and 0xff else 0
                    if (term == 0xf7) out.add(IntArray(p - s + 1) { k -> if (k == 0) 0xf0 else b[s + k - 1].toInt() and 0xff })
                    running = 0
                }
                st >= 0xf0 -> {                                       // system common
                    val need = when (st) { 0xf1, 0xf3 -> 1; 0xf2 -> 2; else -> 0 }
                    if (p + need > end) break
                    out.add(IntArray(need + 1) { k -> if (k == 0) st else b[p + k - 1].toInt() and 0xff }); p += need
                    running = 0
                }
                else -> {
                    val need = if ((st and 0xf0) == 0xc0 || (st and 0xf0) == 0xd0) 1 else 2
                    if (p + need > end) break
                    out.add(intArrayOf(st, b[p].toInt() and 0x7f, if (need > 1) b[p + 1].toInt() and 0x7f else 0)); p += need
                    running = st
                }
            }
        }
        return Data(ssrc, seq, out)
    }
}
