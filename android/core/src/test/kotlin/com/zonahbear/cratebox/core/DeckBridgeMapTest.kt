package com.zonahbear.cratebox.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Deck Bridge's messages and mapping file, as USBTests.swift checks them. */
class DeckBridgeMapTest {
    private fun m(vararg b: Int) = BridgeMessage(b.toList())

    @Test fun messages() {
        assertEquals(listOf(m(0x92, 0x0B, 0x7F)), DeckBridgeMap.button(BridgeControl.PLAY_PAUSE, 2, true))
        assertEquals(listOf(m(0x93, 0x0B, 0x00)), DeckBridgeMap.button(BridgeControl.PLAY_PAUSE, 3, false))
        assertEquals(listOf(m(0x9A, 0x04, 0x7F)), DeckBridgeMap.hotCue(4, 3, true))
        assertEquals(listOf(m(0xB2, 0x13, 0x7F), m(0xB2, 0x33, 0x7F)), DeckBridgeMap.value(BridgeControl.CHANNEL_FADER, 2, 1.0))
        assertEquals(m(0xB6, 0x1A, 0x40), DeckBridgeMap.value(BridgeControl.FILTER, 3, 0.5).first())
        assertEquals(listOf(listOf(0xB2, 0x22, 127), listOf(0xB2, 0x22, 101)), DeckBridgeMap.relative(BridgeControl.JOG_SCRATCH, 2, 100).map { it.bytes })
        assertEquals(listOf(listOf(0xB3, 0x23, 59)), DeckBridgeMap.relative(BridgeControl.JOG_BEND, 3, -5).map { it.bytes })
        assertEquals(DeckBridgeMap.Feedback.Button(BridgeControl.PLAY_PAUSE, 2, true), DeckBridgeMap.feedback(listOf(0x92, 0x0B, 0x7F)))
        assertEquals(DeckBridgeMap.Feedback.HotCue(2, 3, false), DeckBridgeMap.feedback(listOf(0x9A, 0x02, 0x00)))
    }

    @Test fun mappingFile() {
        val csv = DeckBridgeMap.rekordboxCSV()
        val lines = csv.split("\r\n").filter { it.isNotEmpty() }
        assertEquals("@file,1,Cratebox Deck Bridge", lines[0])
        for (l in lines.drop(1)) assertEquals(15, l.split(",").size, l)
        assertTrue("PlayPause,PlayPause,Button,900B,0,1,2,3,900B,0,1,2,3,Fast;Blink=1000;Priority=50,Play/Pause" in lines)
        assertTrue(lines.any { it.startsWith("PAD1_HotCue,PAD1.HotCue.Call,Pad,9000,7,8,9,10,") })
        assertTrue(lines.any { it.startsWith("ChannelFader,ChannelFader,KnobSliderHiRes,B013,0,1,2,3,") })
        assertTrue(lines.any { it.startsWith("Load,Load,Button,,9646,9647,9648,9649,") })
        assertFalse(lines.any { it.startsWith("Jog") })
        assertTrue(lines.any { it.startsWith("SearchFwd,,Button,,9071,9171,9271,9371,,9071,9171,9271,9371,") })
        assertFalse(lines.any { it.startsWith("PitchBend") })
        assertEquals(listOf(m(0x92, 0x71, 0x7F)), DeckBridgeMap.button(BridgeControl.SEARCH_FWD, 2, true))
        assertEquals(listOf(m(0x9A, 0x23, 0x7F)), DeckBridgeMap.pad(3, DeckBridgeMap.PadBank.BEAT_JUMP, 3, true))
        // byte for byte the file in deckbridge/
        assertEquals(File(System.getProperty("cratebox.repo") ?: "../..", "deckbridge/Cratebox Deck Bridge.midi.csv").readText(), csv)
    }
}
