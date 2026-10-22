package com.zonahbear.cratebox.core

import java.util.concurrent.locks.ReentrantLock
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

// The audio engine: 4 decks -> channel strips -> master (BEAT FX on MASTER, level, limiter), plus the
// headphone mix, rendered in 128-frame blocks like the web app's AudioWorklets (so anything timed per block,
// such as the jog's pitch bend fading out, behaves the same). Port of CrateboxKit Engine.swift. The app's
// audio thread calls render(); everything else talks to it through post() and reads it back with snapshot().

data class DeckReport(
    val pos: Double = 0.0, val speed: Double = 0.0, val playing: Boolean = false, val ended: Boolean = false,
    val coast: Boolean = false, val peakL: Float = 0f, val peakR: Float = 0f, val seq: Int = 0,
)
/** time: the audio clock (s) at the end of the last block; host: the host clock (s, monotonic) when it was rendered */
data class EngineSnapshot(
    val time: Double = 0.0, val host: Double = 0.0,
    val decks: List<DeckReport> = List(4) { DeckReport() }, val masterPeak: Pair<Float, Float> = 0f to 0f,
)
fun hostSeconds(): Double = System.nanoTime() / 1e9

enum class FxSlotName { BEAT, PAD }
typealias RecordTap = (FloatArray, FloatArray, Int) -> Unit

sealed class EngineCommand {
    data class Deck(val i: Int, val m: DeckMessage) : EngineCommand()
    /** then Deck(i, Load(...)) */
    data class Track(val i: Int, val t: PCMTrack?) : EngineCommand()
    /** pass a copy (MixerState.deepCopy) so later edits don't reach the audio thread */
    data class Mixer(val m: MixerState) : EngineCommand()
    /** unit 0-3 = decks, 4 = master */
    data class Fx(val unit: Int, val slot: FxSlotName, val fx: FxKind? = null, val beats: Double? = null, val depth: Double? = null, val on: Boolean? = null) : EngineCommand()
    data class Clock(val unit: Int, val c: FxClock) : EngineCommand()
    data class Output(val o: OutputMode) : EngineCommand()
    /** set or clear the recording tap on the audio thread itself (so it never changes mid-block) */
    data class SetRecordTap(val f: RecordTap?) : EngineCommand()
    /** three short beeps in the headphone mix only (if the speakers play them too, cue isn't separate) */
    object TestCue : EngineCommand()
    /** three short beeps on the master only (the speakers) */
    object TestMaster : EngineCommand()
}

class Engine(val sampleRate: Double) {
    val decks = List(4) { DeckPlayer(sampleRate) }
    private val strips = List(4) { ChannelStrip(sampleRate) }
    private val masterFx = FxUnit(sampleRate)
    private val limiter = Limiter(sampleRate)
    private var mixer = MixerState()
    private var gMaster = MixerCurves.masterGain(0.8)
    private var gHpCue = 1.0
    private var gHpMaster = 0.0
    private var gMcue = 0.0
    var output = OutputMode.STEREO; private set
    private var frames = 0L
    private var beepLeft = 0
    private var beepPhase = 0.0
    private var beepMaster = false
    // scratch, allocated once
    private val B = 128
    private val dl = Array(4) { FloatArray(B) }
    private val dr = Array(4) { FloatArray(B) }
    private val mL = FloatArray(B); private val mR = FloatArray(B)
    private val cL = FloatArray(B); private val cR = FloatArray(B)
    private val hL = FloatArray(B); private val hR = FloatArray(B)
    // commands in, reports out (the audio thread never waits: it tries the lock and skips if it's busy)
    private val lock = ReentrantLock()
    private var pending = ArrayList<EngineCommand>(1024)
    private var inbox = ArrayList<EngineCommand>(1024)
    private val reports = Array(4) { DeckReport() }
    private var reportTime = 0.0
    private var reportHost = 0.0
    private var reportMaster = 0f to 0f
    private val trash = ArrayList<PCMTrack>(16)          // replaced tracks, dropped off the audio thread
    /** a copy of the master output (after the limiter) for recording; set by the recorder */
    private var recordTap: RecordTap? = null

    init { for (i in 0 until 4) strips[i].apply(mixer, i) }

    /** From any thread. */
    fun post(c: EngineCommand) { lock.lock(); try { pending.add(c) } finally { lock.unlock() } }
    fun post(cs: List<EngineCommand>) { lock.lock(); try { pending.addAll(cs) } finally { lock.unlock() } }
    /** What the audio thread last reported, and the tracks it's done with (dropped here). */
    fun snapshot(): EngineSnapshot {
        lock.lock()
        try {
            trash.clear()
            return EngineSnapshot(reportTime, reportHost, reports.toList(), reportMaster)
        } finally { lock.unlock() }
    }

    private fun apply(c: EngineCommand) {
        when (c) {
            is EngineCommand.Deck -> decks[c.i].handle(c.m)
            is EngineCommand.Track -> {
                decks[c.i].track?.let { trash.add(it) }       // keep it until the main thread drops it
                decks[c.i].setTrack(c.t)
            }
            is EngineCommand.Mixer -> { mixer = c.m; for (i in 0 until 4) strips[i].apply(c.m, i) }
            is EngineCommand.Fx -> {
                val unit = if (c.unit < 4) strips[c.unit].fx else masterFx
                (if (c.slot == FxSlotName.BEAT) unit.beat else unit.pad).set(c.fx, c.beats, c.depth, c.on)
            }
            is EngineCommand.Clock -> (if (c.unit < 4) strips[c.unit].fx else masterFx).clock = c.c
            is EngineCommand.Output -> output = c.o
            is EngineCommand.SetRecordTap -> recordTap = c.f
            is EngineCommand.TestCue -> { beepLeft = (1.05 * sampleRate).toInt(); beepPhase = 0.0; beepMaster = false }
            is EngineCommand.TestMaster -> { beepLeft = (1.05 * sampleRate).toInt(); beepPhase = 0.0; beepMaster = true }
        }
    }

    /** The audio callback: `outs` are the output channels (2, or 4 for master on 1/2 and headphones on 3/4),
     *  each at least `n` long, written from `offset`. */
    fun render(outs: Array<FloatArray>, n: Int, offset: Int = 0) {
        if (lock.tryLock()) {
            try { val t = pending; pending = inbox; inbox = t } finally { lock.unlock() }
            for (c in inbox) apply(c)
            inbox.clear()
        }
        var done = 0
        val k = 1 - exp(-1 / (0.008 * sampleRate))
        val tMaster = MixerCurves.masterGain(mixer.master)
        val hm = MixerCurves.headMix(mixer.headMix)
        val tMc = if (mixer.masterCue) 1.0 else 0.0
        var mpl = 0f
        var mpr = 0f
        while (done < n) {
            val m = min(B, n - done)
            val time = frames / sampleRate
            for (j in 0 until m) { mL[j] = 0f; mR[j] = 0f; cL[j] = 0f; cR[j] = 0f }
            for (i in 0 until 4) {
                decks[i].render(dl[i], dr[i], m)
                strips[i].process(dl[i], dr[i], m, time, cL, cR)
                for (j in 0 until m) { mL[j] += dl[i][j]; mR[j] += dr[i][j] }
            }
            masterFx.process(mL, mR, m, time)
            for (j in 0 until m) {
                gMaster += (tMaster - gMaster) * k; gHpCue += (hm.first - gHpCue) * k; gHpMaster += (hm.second - gHpMaster) * k; gMcue += (tMc - gMcue) * k
                val ml = mL[j] * gMaster
                val mr = mR[j] * gMaster
                // headphones: the CUE mix, the master by the CUE/MASTER knob, and MASTER CUE at full level
                hL[j] = (cL[j] * gHpCue + ml * (gHpMaster + gMcue)).toFloat(); hR[j] = (cR[j] * gHpCue + mr * (gHpMaster + gMcue)).toFloat()
                var mb = 0f
                if (beepLeft > 0) {
                    // 3 x 150 ms of 880 Hz, 200 ms apart
                    val pos = (1.05 * sampleRate).toInt() - beepLeft
                    val cyc = (0.35 * sampleRate).toInt()
                    if (pos % cyc < (0.15 * sampleRate).toInt()) {
                        val b = (0.3 * sin(beepPhase)).toFloat()
                        if (beepMaster) mb = b else { hL[j] += b; hR[j] += b }
                    }
                    beepPhase += 2 * Math.PI * 880 / sampleRate
                    beepLeft -= 1
                }
                limiter.l = ml; limiter.r = mr
                limiter.run()
                mL[j] = limiter.l.toFloat() + mb; mR[j] = limiter.r.toFloat() + mb
                if (abs(mL[j]) > mpl) mpl = abs(mL[j]); if (abs(mR[j]) > mpr) mpr = abs(mR[j])
            }
            recordTap?.invoke(mL, mR, m)
            val o = offset + done
            when {
                output == OutputMode.QUAD && outs.size >= 4 -> {
                    for (j in 0 until m) { outs[0][o + j] = mL[j]; outs[1][o + j] = mR[j]; outs[2][o + j] = hL[j]; outs[3][o + j] = hR[j] }
                    for (c in 4 until outs.size) for (j in 0 until m) outs[c][o + j] = 0f
                }
                output == OutputMode.QUAD_SWAPPED && outs.size >= 4 -> {
                    for (j in 0 until m) { outs[0][o + j] = hL[j]; outs[1][o + j] = hR[j]; outs[2][o + j] = mL[j]; outs[3][o + j] = mR[j] }
                    for (c in 4 until outs.size) for (j in 0 until m) outs[c][o + j] = 0f
                }
                output == OutputMode.SPLIT && outs.size >= 2 -> {
                    // mono master on the left, mono cue mix on the right (a splitter cable)
                    for (j in 0 until m) { outs[0][o + j] = (mL[j] + mR[j]) * 0.5f; outs[1][o + j] = (hL[j] + hR[j]) * 0.5f }
                }
                else -> {
                    for (j in 0 until m) { outs[0][o + j] = mL[j]; if (outs.size > 1) outs[1][o + j] = mR[j] }
                    for (c in 2 until outs.size) for (j in 0 until m) outs[c][o + j] = 0f
                }
            }
            frames += m; done += m
        }
        if (lock.tryLock()) {
            try {
                reportTime = frames / sampleRate; reportHost = hostSeconds()
                for (i in 0 until 4) {
                    val d = decks[i]
                    reports[i] = DeckReport(d.pos, d.speed, d.playing, d.ended, d.coast, strips[i].peakL, strips[i].peakR, d.seq)
                }
                reportMaster = mpl to mpr
            } finally { lock.unlock() }
        }
    }

    val time: Double get() = frames / sampleRate
}
