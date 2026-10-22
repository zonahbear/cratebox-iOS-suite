// Android hands MIDI over as a byte stream, split wherever the driver likes (CoreMIDI on iOS gives whole
// messages). This puts the stream back into messages: channel voice messages (with running status) come out as
// 3 bytes, like iOS's decode (program change / channel pressure padded with a 0); system exclusive comes out
// whole; real-time bytes (clock, active sensing) are dropped, even mid-message.
package com.zonahbear.cratebox.core

class MidiFramer(private val maxSysex: Int = 4096, private val onMessage: (IntArray) -> Unit) {
    private var status = 0
    private val data = IntArray(2); private var have = 0
    private var sysex: java.io.ByteArrayOutputStream? = null

    private fun needs(st: Int) = when (st and 0xf0) { 0xc0, 0xd0 -> 1; else -> 2 }

    fun feed(b: ByteArray, offset: Int = 0, count: Int = b.size) {
        for (k in offset until offset + count) byte(b[k].toInt() and 0xff)
    }

    fun byte(v: Int) {
        if (v >= 0xf8) return                                   // real-time: clock, start/stop, active sensing
        val sx = sysex
        if (sx != null) {
            if (v == 0xf7) { sx.write(v); sysex = null; onMessage(sx.toByteArray().map { it.toInt() and 0xff }.toIntArray()); return }
            if (v < 0x80) { if (sx.size() < maxSysex) sx.write(v); return }
            sysex = null                                        // a status byte ends an unterminated sysex
        }
        when {
            v == 0xf0 -> { sysex = java.io.ByteArrayOutputStream().apply { write(v) }; status = 0 }
            v >= 0xf0 -> status = 0                             // system common: not used, and cancels running status
            v >= 0x80 -> { status = v; have = 0 }
            status != 0 -> {
                data[have++] = v
                if (have == needs(status)) {
                    onMessage(intArrayOf(status, data[0], if (have > 1) data[1] else 0))
                    have = 0                                    // running status: the next data byte starts another
                }
            }
        }
    }
}
