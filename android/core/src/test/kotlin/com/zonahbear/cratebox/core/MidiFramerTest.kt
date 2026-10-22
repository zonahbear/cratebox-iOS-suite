package com.zonahbear.cratebox.core

import kotlin.test.Test
import kotlin.test.assertEquals

class MidiFramerTest {
    private fun run(vararg chunks: IntArray): List<List<Int>> {
        val out = ArrayList<List<Int>>()
        val f = MidiFramer { out.add(it.toList()) }
        for (c in chunks) f.feed(ByteArray(c.size) { c[it].toByte() })
        return out
    }

    @Test fun splitAndRunningStatus() {
        val m = run(intArrayOf(0x90, 0x0b), intArrayOf(0x7f, 0x0c, 0x00, 0xb0, 0x13, 0x40))
        assertEquals(listOf(listOf(0x90, 0x0b, 0x7f), listOf(0x90, 0x0c, 0x00), listOf(0xb0, 0x13, 0x40)), m)
    }

    @Test fun realtimeInsideAMessage() {
        assertEquals(listOf(listOf(0xb6, 0x1f, 0x41)), run(intArrayOf(0xb6, 0xf8, 0x1f, 0xfe, 0x41)))
    }

    @Test fun twoByteMessagesPadded() {
        assertEquals(listOf(listOf(0xc0, 5, 0), listOf(0xc0, 6, 0)), run(intArrayOf(0xc0, 5, 6)))
    }

    @Test fun sysexWholeAndRunningStatusCancelled() {
        val m = run(intArrayOf(0x90, 1, 2, 0xf0, 0x00, 0x40), intArrayOf(0x05, 0xf7, 3, 4))
        assertEquals(listOf(listOf(0x90, 1, 2), listOf(0xf0, 0x00, 0x40, 0x05, 0xf7)), m)
    }
}
