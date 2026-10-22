package com.zonahbear.cratebox.core

import kotlin.math.max
import kotlin.math.min

// Deck Bridge: Cratebox as a touch MIDI controller for rekordbox. This is the message layout it sends and the
// rekordbox mapping file (MIDI → IMPORT) that matches it, so the only manual step in rekordbox is importing
// one file. Port of CrateboxKit DeckBridgeMap.swift; DeckBridgeMapTest checks the CSV is byte-for-byte the
// one in deckbridge/.
//
// The layout follows Pioneer's own 4-deck controllers (the DDJ-1000's numbers, as in rekordbox's
// MidiMappings files): each deck its own MIDI channel (deck 1 = channel 1 … deck 4 = channel 4), the pads on
// channels 8-11, the mixer's global controls and the browser on channel 7, Beat FX on channel 5. Faders and
// knobs are 14-bit (MSB on CC n, LSB on CC n+32). Jog wheels and the browse knob are relative: 64 = no move,
// above = clockwise. rekordbox lights the buttons back (PLAY, CUE, SYNC, loops, hot cue pads) on the same
// numbers, which Deck Bridge reads to light its own.

enum class BridgeControl {
    // deck buttons (note on the deck's channel)
    PLAY_PAUSE, CUE, SYNC, KEYLOCK, QUANTIZE, SLIP, LOOP_IN, LOOP_OUT, RELOOP_EXIT, AUTO_LOOP, LOOP_HALF, LOOP_DOUBLE, HEADPHONE_CUE, HOT_CUE_MODE, JUMP_TO_START,
    PAD_FX1_MODE, BEAT_JUMP_MODE, PAD_FX2_MODE,
    // what the platter presses while it turns: rekordbox takes no jog wheel from a generic MIDI device, only these
    SEARCH_FWD, SEARCH_REV,
    // deck continuous (14-bit CC on the deck's channel)
    TEMPO, TRIM, EQ_HIGH, EQ_MID, EQ_LOW, CHANNEL_FADER,
    // jog (relative CC / touch note on the deck's channel)
    JOG_SCRATCH, JOG_BEND, JOG_TOUCH,
    // per channel, on the global channel
    FILTER, FX_ASSIGN, LOAD,
    // global
    CROSSFADER, BROWSE, BACK, FX_DEPTH, FX_ON, FX_SELECT, FX_BEAT_DOWN, FX_BEAT_UP, FILTER_SELECT,
}

/** one MIDI message, bytes 0-255 */
data class BridgeMessage(val bytes: List<Int>)

object DeckBridgeMap {
    private val deckNote: Map<BridgeControl, Int> = mapOf(
        BridgeControl.PLAY_PAUSE to 0x0B, BridgeControl.CUE to 0x0C, BridgeControl.SYNC to 0x58, BridgeControl.KEYLOCK to 0x1A,
        BridgeControl.QUANTIZE to 0x35, BridgeControl.SLIP to 0x40, BridgeControl.LOOP_IN to 0x10, BridgeControl.LOOP_OUT to 0x11,
        BridgeControl.RELOOP_EXIT to 0x4D, BridgeControl.AUTO_LOOP to 0x14, BridgeControl.LOOP_HALF to 0x12, BridgeControl.LOOP_DOUBLE to 0x13,
        BridgeControl.HEADPHONE_CUE to 0x54, BridgeControl.HOT_CUE_MODE to 0x1B, BridgeControl.JUMP_TO_START to 0x48,
        BridgeControl.PAD_FX1_MODE to 0x1E, BridgeControl.BEAT_JUMP_MODE to 0x20, BridgeControl.PAD_FX2_MODE to 0x6B,
        BridgeControl.SEARCH_FWD to 0x71, BridgeControl.SEARCH_REV to 0x70,
    )
    private val deckCC: Map<BridgeControl, Int> = mapOf(BridgeControl.TEMPO to 0x00, BridgeControl.TRIM to 0x04, BridgeControl.EQ_HIGH to 0x07,
        BridgeControl.EQ_MID to 0x0B, BridgeControl.EQ_LOW to 0x0F, BridgeControl.CHANNEL_FADER to 0x13)
    private val jogCC: Map<BridgeControl, Int> = mapOf(BridgeControl.JOG_SCRATCH to 0x22, BridgeControl.JOG_BEND to 0x23)
    private const val JOG_TOUCH_NOTE = 0x36
    private const val PAD_CHANNEL0 = 7            // deck 1's pads on channel 8 (status 0x97)
    private const val GLOBAL_CHANNEL = 6          // channel 7
    private const val FX_CHANNEL = 4              // channel 5

    fun clamp14(v: Double): Int = max(0, min(16383, Math.round(v * 16383).toInt()))

    private fun msg(vararg b: Int) = BridgeMessage(b.toList())

    /** a press (on) or release (off) of a deck button; deck 0-3 */
    fun button(c: BridgeControl, deck: Int, on: Boolean): List<BridgeMessage> {
        val v = if (on) 0x7f else 0x00
        val d = deck and 3
        deckNote[c]?.let { return listOf(msg(0x90 or d, it, v)) }
        return when (c) {
            BridgeControl.JOG_TOUCH -> listOf(msg(0x90 or d, JOG_TOUCH_NOTE, v))
            BridgeControl.FX_ASSIGN -> listOf(msg(0x90 or FX_CHANNEL, 0x10 + d, v))
            BridgeControl.LOAD -> listOf(msg(0x90 or GLOBAL_CHANNEL, 0x46 + d, v))
            BridgeControl.BACK -> listOf(msg(0x90 or GLOBAL_CHANNEL, 0x65, v))
            BridgeControl.FX_ON -> listOf(msg(0x90 or FX_CHANNEL, 0x47, v))
            BridgeControl.FX_SELECT -> listOf(msg(0x90 or FX_CHANNEL, 0x63, v))
            BridgeControl.FX_BEAT_DOWN -> listOf(msg(0x90 or FX_CHANNEL, 0x4A, v))
            BridgeControl.FX_BEAT_UP -> listOf(msg(0x90 or FX_CHANNEL, 0x4B, v))
            BridgeControl.FILTER_SELECT -> listOf(msg(0x90 or GLOBAL_CHANNEL, 0x03, v))
            else -> emptyList()
        }
    }

    /** rekordbox's pad modes, in the order Deck Bridge shows them; each mode's pads are 8 notes from its base
     *  (Pioneer's layout: hot cue 0x00, Pad FX 1 0x10, beat jump 0x20, Pad FX 2 0x30; +8 with SHIFT) */
    enum class PadBank(val base: Int, val mode: BridgeControl, val title: String) {
        HOT_CUE(0x00, BridgeControl.HOT_CUE_MODE, "CUES"), BEAT_JUMP(0x20, BridgeControl.BEAT_JUMP_MODE, "JUMP"),
        PAD_FX1(0x10, BridgeControl.PAD_FX1_MODE, "FX1"), PAD_FX2(0x30, BridgeControl.PAD_FX2_MODE, "FX2"),
    }
    /** pad k (0-7) in a pad mode; shift = the pad's SHIFT function (deletes a hot cue) */
    fun pad(k: Int, bank: PadBank, deck: Int, on: Boolean, shift: Boolean = false): List<BridgeMessage> =
        listOf(msg(0x90 or (PAD_CHANNEL0 + (deck and 3)), bank.base + (if (shift) 0x08 else 0x00) + (k and 7), if (on) 0x7f else 0x00))
    /** hot cue pad k (0-7); shift = delete */
    fun hotCue(k: Int, deck: Int, on: Boolean, shift: Boolean = false) = pad(k, PadBank.HOT_CUE, deck, on, shift)
    /** a fader or knob, 0…1 */
    fun value(c: BridgeControl, deck: Int, v: Double): List<BridgeMessage> {
        val x = clamp14(v); val msb = x shr 7; val lsb = x and 0x7f; val d = deck and 3
        fun pair(status: Int, cc: Int) = listOf(msg(status, cc, msb), msg(status, cc + 0x20, lsb))
        deckCC[c]?.let { return pair(0xB0 or d, it) }
        return when (c) {
            BridgeControl.FILTER -> pair(0xB0 or GLOBAL_CHANNEL, 0x17 + d)
            BridgeControl.CROSSFADER -> pair(0xB0 or GLOBAL_CHANNEL, 0x1F)
            BridgeControl.FX_DEPTH -> pair(0xB0 or FX_CHANNEL, 0x02)
            else -> emptyList()
        }
    }
    /** jog / browse movement: ticks (+ clockwise), split into messages of at most ±63 */
    fun relative(c: BridgeControl, deck: Int, ticks: Int): List<BridgeMessage> {
        val status: Int; val cc: Int
        val j = jogCC[c]
        if (j != null) { status = 0xB0 or (deck and 3); cc = j }
        else if (c == BridgeControl.BROWSE) { status = 0xB0 or GLOBAL_CHANNEL; cc = 0x40 }
        else return emptyList()
        var left = ticks
        val out = ArrayList<BridgeMessage>()
        while (left != 0) {
            val step = max(-63, min(63, left))
            out.add(msg(status, cc, 64 + step))
            left -= step
        }
        return out
    }

    // ---- what rekordbox sends back (lights) ----
    sealed class Feedback {
        data class Button(val c: BridgeControl, val deck: Int, val on: Boolean) : Feedback()
        data class HotCue(val k: Int, val deck: Int, val on: Boolean) : Feedback()
        data class Pad(val bank: PadBank, val k: Int, val deck: Int, val on: Boolean) : Feedback()
        data class Fx(val c: BridgeControl, val on: Boolean) : Feedback()
    }
    fun feedback(m: List<Int>): Feedback? {
        if (m.size < 3) return null
        val kind = m[0] and 0xF0; val ch = m[0] and 0x0F
        if (kind != 0x90 && kind != 0x80) return null
        val on = kind == 0x90 && m[2] > 0
        if (ch <= 3) deckNote.entries.firstOrNull { it.value == m[1] }?.let { return Feedback.Button(it.key, ch, on) }
        if (ch >= PAD_CHANNEL0 && ch <= PAD_CHANNEL0 + 3) {
            if (m[1] < 8) return Feedback.HotCue(m[1], ch - PAD_CHANNEL0, on)
            if (m[1] and 0x08 == 0) PadBank.entries.firstOrNull { it.base == m[1] and 0xF0 }?.let { return Feedback.Pad(it, m[1] and 7, ch - PAD_CHANNEL0, on) }
        }
        if (ch == FX_CHANNEL && m[1] == 0x47) return Feedback.Fx(BridgeControl.FX_ON, on)
        return null
    }

    // ---- the rekordbox mapping file ----
    private class Row(val name: String, val function: String, val type: String, val input: String, val decks: String,
                      val output: String, val outDecks: String, val option: String, val comment: String)
    private fun hex(status: Int, d1: Int) = fmt("%02X%02X", status, d1)

    /** rekordbox's MIDI mapping file for Deck Bridge (CSV, CRLF): rekordbox → MIDI → pick "Cratebox Deck
     *  Bridge" (or the network session it shows up as) → IMPORT */
    fun rekordboxCSV(deviceName: String = "Cratebox Deck Bridge"): String {
        val rows = ArrayList<Row>()
        val four = "0,1,2,3"; val pads = "7,8,9,10"
        data class D(val c: BridgeControl, val name: String, val fn: String, val opt: String, val comment: String)
        val deckRows = listOf(
            D(BridgeControl.PLAY_PAUSE, "PlayPause", "PlayPause", "Fast;Blink=1000;Priority=50", "Play/Pause"),
            D(BridgeControl.CUE, "Cue", "Cue", "Fast;Blink=500;Priority=50", "Cue"),
            D(BridgeControl.JUMP_TO_START, "JumpToTrackStart", "Cue+Shift", "Fast;Priority=50", "Jump to track start"),
            D(BridgeControl.SYNC, "Sync", "Sync", "Blink=600", "Sync On/Off"),
            D(BridgeControl.KEYLOCK, "MasterTempo", "MasterTempo", "", "Master Tempo (key lock) On/Off"),
            D(BridgeControl.QUANTIZE, "Quantize", "Quantize", "", "Quantize On/Off"),
            D(BridgeControl.SLIP, "Slip", "Slip", "", "Slip On/Off"),
            D(BridgeControl.LOOP_IN, "LoopIn", "LoopIn", "Fast", "Loop in"),
            D(BridgeControl.LOOP_OUT, "LoopOut", "LoopOut", "Fast", "Loop out"),
            D(BridgeControl.RELOOP_EXIT, "ReloopExit", "LoopOut+Shift", "Fast", "Reloop/Exit"),
            D(BridgeControl.AUTO_LOOP, "4BeatLoop", "4BeatLoop", "Fast", "Auto Loop On/Off"),
            D(BridgeControl.LOOP_HALF, "LoopHalf", "LoopHalf", "Fast", "Loop 1/2"),
            D(BridgeControl.LOOP_DOUBLE, "LoopDouble", "LoopDouble", "Fast", "Loop x2"),
            D(BridgeControl.HEADPHONE_CUE, "HeadphoneCue", "HeadphoneCue", "", "Headphone cue"),
            D(BridgeControl.HOT_CUE_MODE, "HotCue", "HotCueMode", "Fast", "HOT CUE pad mode"),
            D(BridgeControl.BEAT_JUMP_MODE, "BeatJump", "BeatJumpMode", "Fast", "BEAT JUMP pad mode"),
            D(BridgeControl.PAD_FX1_MODE, "PadFx1", "PadFx1Mode", "Fast", "PAD FX 1 pad mode"),
            D(BridgeControl.PAD_FX2_MODE, "PadFx2", "PadFx2Mode", "Fast", "PAD FX 2 pad mode"),
        )
        for (r in deckRows) {
            val code = hex(0x90, deckNote[r.c]!!)
            rows.add(Row(r.name, r.fn, "Button", code, four, code, four, r.opt, r.comment))
        }
        // search for the platter, written the way rekordbox exports a learned row (it ignored the deck-number form
        // of these): empty function, one code per deck
        for ((c, name, comment) in listOf(Triple(BridgeControl.SEARCH_FWD, "SearchFwd", "Search forward (jog turning right)"), Triple(BridgeControl.SEARCH_REV, "SearchRev", "Search back (jog turning left)"))) {
            val codes = (0 until 4).joinToString(",") { hex(0x90 or it, deckNote[c]!!) }
            rows.add(Row(name, "", "Button", "", codes, "", codes, "Fast", comment))
        }
        for (k in 0 until 8) {
            rows.add(Row("PAD${k + 1}_HotCue", "PAD${k + 1}.HotCue.Call", "Pad", hex(0x90, k), pads, hex(0x90, k), pads, "Fast", "Hot cue ${k + 1}"))
            rows.add(Row("PAD${k + 1}_HotCue+Shift", "PAD${k + 1}.HotCue.Delete", "Pad", hex(0x90, 8 + k), pads, "", "", "Fast", "Delete hot cue ${k + 1}"))
        }
        for ((bank, name, label) in listOf(Triple(PadBank.BEAT_JUMP, "BeatJump", "Beat jump"), Triple(PadBank.PAD_FX1, "PadFx1", "Pad FX 1"), Triple(PadBank.PAD_FX2, "PadFx2", "Pad FX 2"))) {
            for (k in 0 until 8) {
                val code = hex(0x90, bank.base + k)
                rows.add(Row("PAD${k + 1}_$name", "PAD${k + 1}.$name", "Pad", code, pads, code, pads, "Fast", "$label pad ${k + 1}"))
            }
        }
        val cc = listOf(Triple(BridgeControl.TEMPO, "TempoSlider", "Tempo"), Triple(BridgeControl.TRIM, "Gain", "Trim"), Triple(BridgeControl.EQ_HIGH, "EQHigh", "EQ high"),
            Triple(BridgeControl.EQ_MID, "EQMid", "EQ mid"), Triple(BridgeControl.EQ_LOW, "EQLow", "EQ low"), Triple(BridgeControl.CHANNEL_FADER, "ChannelFader", "Channel fader"))
        for ((c, name, comment) in cc) rows.add(Row(name, name, "KnobSliderHiRes", hex(0xB0, deckCC[c]!!), four, "", "", "Fast", comment))
        // no jog rows: the platter presses SearchFwd / SearchRev (above) instead
        for (d in 0 until 4) {
            rows.add(Row("CFXParameterCH${d + 1}", "CFXParameterCH${d + 1}", "KnobSliderHiRes", hex(0xB0 or GLOBAL_CHANNEL, 0x17 + d), ",,,", "", "", "Fast", "CH${d + 1} filter (Sound Color FX)"))
            rows.add(Row("FX1Assign.CH${d + 1}", "", "Button", hex(0x90 or FX_CHANNEL, 0x10 + d), ",,,", "", "", "", "Beat FX on CH${d + 1}"))
        }
        rows.add(Row("CFX4On", "CFX4On", "Button", hex(0x90 or GLOBAL_CHANNEL, 0x03), ",,,", hex(0x90 or GLOBAL_CHANNEL, 0x03), ",,,", "Fast", "Sound Color FX: FILTER"))
        rows.add(Row("CrossFader", "CrossFader", "KnobSliderHiRes", hex(0xB0 or GLOBAL_CHANNEL, 0x1F), ",,,", "", "", "Fast", "Crossfader"))
        rows.add(Row("Browse", "Browse", "Rotary", hex(0xB0 or GLOBAL_CHANNEL, 0x40), ",,,", "", "", "", "Browse"))
        rows.add(Row("Back", "Back", "Button", hex(0x90 or GLOBAL_CHANNEL, 0x65), ",,,", "", "", "", "Library back"))
        rows.add(Row("Load", "Load", "Button", "", (0 until 4).joinToString(",") { hex(0x90 or GLOBAL_CHANNEL, 0x46 + it) }, "", ",,,", "", "Load to deck"))
        rows.add(Row("FX1-1", "FX1-1", "KnobSliderHiRes", hex(0xB0 or FX_CHANNEL, 0x02), ",,,", "", "", "", "Beat FX depth"))
        rows.add(Row("FX1-1On", "FX1-1On", "Button", hex(0x90 or FX_CHANNEL, 0x47), ",,,", hex(0x90 or FX_CHANNEL, 0x47), ",,,", "", "Beat FX on/off"))
        rows.add(Row("FX1-1Select", "FX1-1Select", "Button", hex(0x90 or FX_CHANNEL, 0x63), ",,,", "", "", "", "Beat FX select"))
        rows.add(Row("FX1BeatDown", "FX1BeatDown", "Button", hex(0x90 or FX_CHANNEL, 0x4A), ",,,", "", "", "", "Beat FX beat -"))
        rows.add(Row("FX1BeatUp", "FX1BeatUp", "Button", hex(0x90 or FX_CHANNEL, 0x4B), ",,,", "", "", "", "Beat FX beat +"))
        val lines = arrayListOf("@file,1,$deviceName", "#name,function,type,input,deck1,deck2,deck3,deck4,output,deck1,deck2,deck3,deck4,option,comment")
        for (r in rows) {
            val outDecks = r.outDecks.ifEmpty { ",,," }
            lines.add(listOf(r.name, r.function, r.type, r.input, r.decks, r.output, outDecks, r.option, r.comment).joinToString(","))
        }
        return lines.joinToString("\r\n") + "\r\n"
    }
}
