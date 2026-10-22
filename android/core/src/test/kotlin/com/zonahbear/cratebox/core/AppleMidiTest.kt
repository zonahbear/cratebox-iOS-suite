package com.zonahbear.cratebox.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AppleMidiTest {
    private fun hex(s: String) = s.replace(" ", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun sessionPacketsRoundTripAndMatchTheWire() {
        val inv = AppleMidi.Session.Invite(0x12345678, 0x0a0b0c0d, "Mac")
        // FFFF "IN" version 2, token, ssrc, "Mac\0"
        assertEquals("ffff494e00000002123456780a0b0c0d4d616300", AppleMidi.encode(inv).joinToString("") { "%02x".format(it) })
        for (s in listOf(inv, AppleMidi.Session.Accept(1, 2, "Cratebox Deck Bridge"), AppleMidi.Session.Reject(3, 4), AppleMidi.Session.Bye(5, 6),
                         AppleMidi.Session.Clock(7, 1, 100, 200, 0), AppleMidi.Session.Feedback(8, 65535)))
            assertEquals(s, AppleMidi.decodeSession(AppleMidi.encode(s)))
        assertEquals(36, AppleMidi.encode(AppleMidi.Session.Clock(7, 0, 1, 0, 0)).size)
        assertNull(AppleMidi.decodeSession(hex("8061")))
    }

    @Test fun dataPacketsRoundTrip() {
        val msgs = listOf(listOf(0x90, 0x0b, 0x7f), listOf(0xb2, 0x13, 0x40), listOf(0xf0, 0x00, 0x20, 0x7f, 0xf7))
        val p = AppleMidi.dataPacket(seq = 513, timestamp = 1000, ssrc = 42, messages = msgs)
        val d = AppleMidi.decodeData(p)!!
        assertEquals(513, d.seq); assertEquals(42, d.ssrc)
        assertEquals(msgs, d.messages.map { it.toList() })
        // more than 15 bytes: the long-length header
        val many = List(8) { listOf(0xb0, it, 0x40) }
        assertEquals(many, AppleMidi.decodeData(AppleMidi.dataPacket(1, 0, 1, many))!!.messages.map { it.toList() })
    }

    @Test fun readsRunningStatusDeltasAndJournalFlag() {
        // what a Mac sends: Z set (a delta before the first command), running status, a 2-byte delta, then a journal (ignored)
        val rtp = "80 61 00 07 00 00 00 10 00 00 00 2a"
        // header: J=1 (0x40), Z=1 (0x20), len 9: [00] 90 3c 64 [81 00] 3e 64 [00] 40
        val body = "69 00 90 3c 64 81 00 3e 64 00 40 00"
        val d = AppleMidi.decodeData(hex("$rtp $body ab cd ef"))!!
        assertEquals(listOf(listOf(0x90, 0x3c, 0x64), listOf(0x90, 0x3e, 0x64)), d.messages.map { it.toList() }.take(2))
    }
}
