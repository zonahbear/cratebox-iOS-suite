import XCTest
@testable import CrateboxKit

/// Decks, sync and the FLX4 mapping, offline: the engine is rendered by hand and the clock is its own.
final class CoreTests: XCTestCase {
    let SR = 44100.0
    final class Rig: ControlTarget {
        let core: Core, midi = MIDIEngine()
        var sent = [[UInt8]]()
        init(_ core: Core) { self.core = core; midi.target = self; midi.send = { [unowned self] in self.sent.append($0) }; midi.use(Profiles.byId("ddj-flx4")!) }
        var fourDecks: Bool { core.four }
        var deckCount: Int { core.deckCount }
        var pressed = [(String, Int)]()
        func absValue(_ name: String, deck: Int) -> Double? { core.mixerValue(name, deck) }
        func setAbs(_ name: String, deck: Int, _ v: Double) { if name == "tempo" { core.decks[deck].setPitch(v * 2 - 1) } else { core.setMixer(name, deck, v) } }
        func press(_ name: String, arg: String, deck: Int, on: Bool) {
            let d = deck >= 0 ? core.decks[deck] : nil
            if on { pressed.append((name, deck)) }
            switch name {
            case "play": if on { d?.togglePlay() }
            case "cue": on ? d?.cueDown() : d?.cueUp()
            case "sync": if on, let d { d.setSync(!d.sync) }
            case "hot": if on { d?.hotcue(Int(arg)!) }
            case "loop": if on { d?.beatLoop(Double(arg)!) }
            case "touch": d?.jogTouch(on)
            default: break
            }
        }
        func relative(_ name: String, deck: Int, ticks: Int) {}
        func led(_ name: String, arg: String, deck: Int, blink: Bool) -> Int? { name == "play" ? (core.decks[deck].playing ? 127 : 0) : nil }
        func vu(deck: Int) -> Double { 0 }
        func controllerStatus(_ s: String) {}
    }
    func makeCore() -> (Core, Engine) {
        let e = Engine(sampleRate: SR)
        let c = Core(engine: e)
        c.clock = { e.time }
        var wall = 0.0
        c.wallMs = { wall += 1; return wall }
        return (c, e)
    }
    func clickTrack(bpm: Double, secs: Double = 20) -> PCMTrack {
        let n = Int(secs * SR), t = PCMTrack(count: n, sampleRate: SR), spb = 60 / bpm
        for i in 0..<n { let ph = (Double(i) / SR).truncatingRemainder(dividingBy: spb); let v = Float(ph < 0.01 ? 0.8 : 0); t.left[i] = v; t.right[i] = v }
        return t
    }
    func load(_ c: Core, _ deck: Int, bpm: Double) {
        let info = TrackInfo(id: "t\(deck)-\(bpm)", title: "Click \(bpm)")
        let d = c.decks[deck]
        d.beginLoad(info)
        d.finishLoad(info, pcm: clickTrack(bpm: bpm), analysis: DeckAnalysis(bpm: bpm, firstBeat: 0, key: 21, phrases: [], wave: nil, duration: 20), mono: nil)
    }
    func render(_ e: Engine, _ c: Core, secs: Double) {
        let n = 256, outs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { outs.forEach { $0.deallocate() } }
        for _ in 0..<Int(secs * SR) / n { e.render(outs, n); c.tick() }
    }

    func testPlayCueHotcueLoop() {
        let (c, e) = makeCore(); load(c, 0, bpm: 120)
        render(e, c, secs: 0.1)
        let d = c.decks[0]
        XCTAssertTrue(d.loaded)
        d.togglePlay(); render(e, c, secs: 1)
        XCTAssertEqual(d.now(), 1, accuracy: 0.05)
        d.hotcue(0)                                 // set A on the beat (Q on): 1.0 s at 120 BPM
        XCTAssertEqual(d.hot[0]!, 1.0, accuracy: 1e-9)
        d.beatLoop(1); render(e, c, secs: 2)        // a 1-beat loop: stays inside it
        XCTAssertTrue(d.loop.on)
        XCTAssertGreaterThanOrEqual(d.now(), d.loop.a! - 0.02); XCTAssertLessThanOrEqual(d.now(), d.loop.b! + 0.02)
        d.cueDown(); render(e, c, secs: 0.1)        // playing: back to the cue point and stop
        XCTAssertFalse(d.playing)
    }
    func testUnloadForEject() {
        let (c, e) = makeCore(); load(c, 0, bpm: 120)
        let d = c.decks[0]
        d.togglePlay(); render(e, c, secs: 0.5)
        d.unload(); render(e, c, secs: 0.1)
        XCTAssertFalse(d.playing); XCTAssertFalse(d.loaded); XCTAssertNil(d.track)
        XCTAssertNil(c.engine.decks[0].track)        // the engine let go of the audio too
    }
    /// Bluetooth: what you hear is `lag` behind the engine. A 4-beat jump still moves the music exactly 4 beats,
    /// and a synced deck pressed into play starts in phase with what the master is playing, not what you hear.
    func testJumpsAndSyncStartFromThePlayheadWithOutputLag() {
        let (c, e) = makeCore()
        c.clock = { e.time - 0.25 }; c.lag = { 0.25 }
        load(c, 0, bpm: 120); load(c, 1, bpm: 120)
        let d = c.decks[0]
        d.togglePlay(); render(e, c, secs: 3)
        let heard = d.now()
        d.beatJump(4); render(e, c, secs: 1)               // 4 beats at 120 = 2 s, then 1 s of playing
        XCTAssertEqual(d.now(), heard + 2 + 1, accuracy: 0.02)
        let b = c.decks[1]
        b.setSync(true); b.togglePlay(); render(e, c, secs: 0.5)
        var err = b.beatAt(b.now()) - d.beatAt(d.now()); err -= err.rounded()
        XCTAssertEqual(err, 0, accuracy: 0.02)              // in phase (a quarter-second lag is half a beat here)
    }
    /// two jumps before the engine has reported the first: the second starts where the first landed (the guess
    /// made at the jump is stamped on the audio clock, like the reports), not a lag further on
    func testTwoJumpsBeforeAReportWithOutputLag() {
        let (c, e) = makeCore()
        c.clock = { e.time - 0.25 }; c.lag = { 0.25 }
        load(c, 0, bpm: 120)
        let d = c.decks[0]
        d.togglePlay(); render(e, c, secs: 3)
        let start = d.playhead()
        d.beatJump(4); d.beatJump(4)                        // 2 s each at 120, no render or tick between
        XCTAssertEqual(d.playhead(), start + 4, accuracy: 0.005)
        render(e, c, secs: 0.5)
        XCTAssertEqual(e.decks[0].pos / SR, start + 4.5, accuracy: 0.02)
        XCTAssertEqual(d.playhead(), start + 4.5, accuracy: 0.02)
    }
    /// hold a PAD FX pad, switch the pads to hot cues, let go: the effect still turns off
    func testPadFxLetsGoAfterThePadModeChanges() {
        let (c, _) = makeCore(); load(c, 0, bpm: 120)
        let d = c.decks[0]
        d.padMode = .padfx; d.padPress(0)
        XCTAssertNotNil(c.fx.pad[0])
        d.padMode = .hotcue; d.padRelease(0)
        XCTAssertNil(c.fx.pad[0])
        d.padRelease(0)                                     // a second release does nothing
        XCTAssertNil(d.hot[0])                              // and the release didn't set a hot cue
    }
    func testSyncHalftimeAndBeatLock() {
        let (c, e) = makeCore(); load(c, 0, bpm: 140); load(c, 1, bpm: 70.5)
        render(e, c, secs: 0.1)
        c.decks[0].togglePlay(); render(e, c, secs: 0.5)
        let d = c.decks[1]
        d.setSync(true)
        XCTAssertEqual(d.syncMult, 0.5, "70.5 against 140: half the master's tempo (halftime), not sped up to 140")
        XCTAssertEqual(d.bpm * d.rate(), 70, accuracy: 0.05)
        d.seek(5); render(e, c, secs: 0.05)       // into the track, so lining up the beat never needs a seek before 0:00
        d.togglePlay(); render(e, c, secs: 4)
        XCTAssertNotNil(d.phaseErr)
        XCTAssertLessThan(abs(d.phaseErr ?? 1), 0.005, "beat lock holds the phase")
        XCTAssertFalse(d.phaseHeld)
        // moved 0.4 beat off by hand (the platter): SYNC keeps the tempo, leaves the offset, and says so
        d.jogTouch(true); d.seek(d.playhead() + 0.4 * d.spb); d.jogTouch(false); render(e, c, secs: 1)
        XCTAssertTrue(d.phaseHeld, "a deliberate offset is shown as tempo-only")
        XCTAssertGreaterThan(abs(d.phaseErr ?? 0), 0.1)
    }
    // Jonah's report (2026-10-28): 140 on deck 1, 92 on deck 2, SYNC pressed on and off on both; the decks ended up
    // both SYNC, 140 against 70, with the beats drifting apart and the phase readout stuck. Whatever the order,
    // two synced, playing decks end up on the beat.
    func longClicks(_ c: Core, _ deck: Int, bpm: Double) {
        let info = TrackInfo(id: "long\(deck)-\(bpm)", title: "Click \(bpm)")
        let d = c.decks[deck]
        d.beginLoad(info)
        d.finishLoad(info, pcm: clickTrack(bpm: bpm, secs: 90), analysis: DeckAnalysis(bpm: bpm, firstBeat: 0, key: 21, phrases: [], wave: nil, duration: 90), mono: nil)
    }
    // hold SYNC = master: the held deck keeps its tempo and leads, the other synced deck follows it
    func testHoldSyncMakesTheMaster() {
        let (c, e) = makeCore(); longClicks(c, 0, bpm: 124); longClicks(c, 1, bpm: 120)
        render(e, c, secs: 0.1)
        let a = c.decks[0], b = c.decks[1]
        a.togglePlay(); render(e, c, secs: 0.5)
        b.setSync(true); b.togglePlay(); render(e, c, secs: 1)
        a.setSync(true); render(e, c, secs: 1)                     // synced later: deck 1 follows deck 2
        a.setPitch(0.5); render(e, c, secs: 0.5)
        XCTAssertEqual(a.effBpm(), 124, accuracy: 0.1, "a follower's fader does nothing")
        a.setPitch(0)
        a.makeMaster()
        a.syncPressed(); XCTAssertTrue(a.sync, "the release that ends the hold doesn't turn SYNC off")
        render(e, c, secs: 0.5)
        XCTAssertTrue(a.sync && b.sync)
        a.setPitch(0.5); render(e, c, secs: 1)                     // now deck 1 leads: its fader moves both
        XCTAssertEqual(a.effBpm(), 124 * 1.03, accuracy: 0.1)
        XCTAssertEqual(b.effBpm(), 124 * 1.03, accuracy: 0.1)
    }
    func testSyncMultipliersStayInTheTempoRange() {
        XCTAssertEqual(DeckModel.pickMult(96.0 / 92, range: 6), 1)                // +4.3%: fine at ±6
        XCTAssertNil(DeckModel.pickMult(100.0 / 92, range: 6))                    // +8.7%: not at ±6
        XCTAssertEqual(DeckModel.pickMult(100.0 / 92, range: 10), 1)
        XCTAssertEqual(DeckModel.pickMult(140.0 / 70.5, range: 6), 0.5)           // halftime inside the range
        XCTAssertEqual(DeckModel.pickMult(140.0 / 92), 0.5)                        // WIDE: the nearest, as before
        XCTAssertEqual(DeckModel.pickMult(92.0 / 140), 2)
    }
    func testSyncFlipFlop140And92EndsOnTheBeat() {
        let (c, e) = makeCore(); longClicks(c, 0, bpm: 140); longClicks(c, 1, bpm: 92)
        render(e, c, secs: 0.1)
        let a = c.decks[0], b = c.decks[1]
        a.togglePlay(); render(e, c, secs: 1)
        // at ±16% neither ½× (−24%), 1× (+52%) nor 2× (+31%) fits: SYNC stays off and the tempo doesn't move
        b.cycleRange(); b.cycleRange(); XCTAssertEqual(b.range, 16)
        b.setSync(true); XCTAssertFalse(b.sync); XCTAssertEqual(b.effBpm(), 92, accuracy: 0.01)
        for d in [a, b] { while d.range < 100 { d.cycleRange() } }               // WIDE: any of them
        b.seek(5); b.setSync(true); b.togglePlay(); render(e, c, secs: 2)          // 92 follows 140 at half time
        XCTAssertEqual(b.effBpm(), 70, accuracy: 0.1)
        b.setSync(false); render(e, c, secs: 1)
        XCTAssertEqual(b.effBpm(), 92, accuracy: 0.1)
        a.setSync(true); render(e, c, secs: 2)                                    // 140 follows 92 at double time
        XCTAssertEqual(a.syncMult, 2); XCTAssertEqual(a.effBpm(), 184, accuracy: 0.2)
        a.setSync(false); render(e, c, secs: 1)
        b.setSync(true); render(e, c, secs: 1)                                    // 92 → 70 against 140 again
        a.setSync(true); render(e, c, secs: 1)                                    // and 140 against 70
        XCTAssertTrue(a.sync && b.sync)
        // a jump that leaves deck 1 0.4 beat off (not by hand): beat lock pulls it back in
        a.seek(a.playhead() + 0.4 * a.spb); render(e, c, secs: 15)
        XCTAssertEqual(a.effBpm(), 2 * b.effBpm(), accuracy: 0.3)
        XCTAssertNotNil(a.phaseErr)
        XCTAssertLessThan(abs(a.phaseErr ?? 1), 0.005, "both on SYNC: back on the beat, not drifting")
        XCTAssertFalse(a.phaseHeld)
    }
    // Jonah's bug (2026-10-23): a synced deck playing at 72.5 dropped to 36.25 when a 72.5 was loaded on the other
    // deck. It followed the freshly loaded (stopped) deck, with the halftime it had picked against the old 145 there.
    func testLoadingTheOtherDeckNeverRetimesAPlayingSyncedDeck() {
        let (c, e) = makeCore(); load(c, 0, bpm: 145); load(c, 1, bpm: 72.5)
        render(e, c, secs: 0.1)
        let a = c.decks[0], b = c.decks[1]
        a.togglePlay(); render(e, c, secs: 0.5)
        b.setSync(true); XCTAssertEqual(b.syncMult, 0.5)
        b.seek(5); b.togglePlay(); render(e, c, secs: 1)
        XCTAssertEqual(b.effBpm(), 72.5, accuracy: 0.5)
        a.setPlaying(false); load(c, 0, bpm: 72.5); render(e, c, secs: 1)
        XCTAssertEqual(b.effBpm(), 72.5, accuracy: 0.05, "loading deck 1 must not touch deck 2's tempo")
        a.togglePlay(); render(e, c, secs: 1)                // deck 1 played unsynced: deck 2 keeps leading
        XCTAssertEqual(b.effBpm(), 72.5, accuracy: 0.05)
        a.setPitch(0.5); render(e, c, secs: 0.5)
        XCTAssertEqual(b.effBpm(), 72.5, accuracy: 0.05, "a deck it doesn't follow can't move it")
        a.setPitch(0); a.setPlaying(false); load(c, 0, bpm: 75); render(e, c, secs: 0.2)
        a.setSync(true)                                       // syncing the new track follows the playing deck
        XCTAssertEqual(a.syncMult, 1); XCTAssertEqual(a.effBpm(), 72.5, accuracy: 0.05)
        XCTAssertEqual(b.effBpm(), 72.5, accuracy: 0.05)
        b.setPitch(0.2); render(e, c, secs: 0.2)              // the leader's fader still moves it, and the follower
        XCTAssertEqual(b.effBpm(), 72.5 * 1.012, accuracy: 0.05)
        XCTAssertEqual(a.effBpm(), 72.5 * 1.012, accuracy: 0.05)
    }
    // the first report: 140 playing with SYNC on (nothing to follow yet), a 75 loaded on the empty deck
    func testSyncedDeckWithNoMasterHoldsWhenATrackLoads() {
        let (c, e) = makeCore(); load(c, 1, bpm: 140)
        render(e, c, secs: 0.1)
        let b = c.decks[1]
        b.setSync(true); b.togglePlay(); render(e, c, secs: 0.5)
        load(c, 0, bpm: 75); render(e, c, secs: 1)
        XCTAssertEqual(b.effBpm(), 140, accuracy: 0.05)
        XCTAssertEqual(e.decks[1].pos / SR, 1.5, accuracy: 0.05, "the player itself ran at 1x the whole time")
    }
    func testFLX4Messages() {
        let (c, e) = makeCore(); load(c, 0, bpm: 120)
        render(e, c, secs: 0.1)
        let rig = Rig(c)
        rig.midi.receive([0x90, 0x0b, 0x7f]); rig.midi.receive([0x90, 0x0b, 0x00])   // PLAY
        XCTAssertTrue(c.decks[0].playing)
        rig.midi.receive([0xb0, 0x13, 0x40]); rig.midi.receive([0xb0, 0x33, 0x00])   // channel fader, 14 bit
        XCTAssertEqual(c.mixer.fader[0], Double(0x40 << 7) / 16383, accuracy: 1e-9)
        rig.midi.receive([0xb0, 0x00, 0x7f]); rig.midi.receive([0xb0, 0x20, 0x7f])   // tempo fader to the bottom: faster
        XCTAssertEqual(c.decks[0].pitch, 1, accuracy: 1e-6)
        rig.midi.updateLeds(blink: false)
        XCTAssertTrue(rig.sent.contains([0x90, 0x0b, 0x7f]), "PLAY light on")
        rig.midi.connected()
        XCTAssertTrue(rig.sent.contains(Profiles.FLX4_KEEPALIVE), "keep-alive sent")
    }
    func testLayersAndSoftTakeover() {
        let (c, _) = makeCore(); c.setFour(true)
        let rig = Rig(c)
        c.mixer.fader[2] = 0.3
        rig.midi.receive([0xb0, 0x13, 0x7f])        // deck 1 fader up
        XCTAssertEqual(c.mixer.fader[0], 1, accuracy: 0.01)
        rig.midi.toggleSide(0)                      // left side -> deck 3
        rig.midi.receive([0xb0, 0x13, 0x7e])        // the hardware fader is still up: deck 3 doesn't jump
        XCTAssertEqual(c.mixer.fader[2], 0.3, accuracy: 1e-9)
        rig.midi.receive([0xb0, 0x13, 0x30]); rig.midi.receive([0xb0, 0x13, 0x26])    // moved down past 0.3: takes over
        XCTAssertEqual(c.mixer.fader[2], Double(0x26) / 127, accuracy: 0.01)
        XCTAssertEqual(c.mixer.fader[0], 1, accuracy: 0.01, "deck 1 left alone")
    }
    /// 3 decks: 1 and 3 share the left side, 2 stays alone on the right; deck 4 is off; the DECKS button cycles 2 → 3 → 4 → 2
    func testThreeDecks() {
        let (c, _) = makeCore(); c.setDecks(3)
        let rig = Rig(c)
        XCTAssertEqual(c.deckCount, 3); XCTAssertEqual(c.activeDecks, [0, 1, 2])
        XCTAssertEqual(c.mixer.active, [true, true, true, false])
        XCTAssertTrue(c.deckActive(2)); XCTAssertFalse(c.deckActive(3))
        rig.midi.toggleSide(0); XCTAssertEqual(rig.midi.side, [2, 1], "left side → deck 3")
        rig.midi.toggleSide(1); XCTAssertEqual(rig.midi.side, [2, 1], "right side stays on deck 2")
        rig.midi.toggleSide(0); XCTAssertEqual(rig.midi.side, [0, 1])
        c.cycleDecks(); XCTAssertEqual(c.deckCount, 4); XCTAssertFalse(c.three)
        c.cycleDecks(); XCTAssertEqual(c.deckCount, 2); XCTAssertFalse(c.four)
        c.cycleDecks(); XCTAssertEqual(c.deckCount, 3)
        // remembered
        let p = MemoryPrefs(); let c2 = Core(engine: Engine(sampleRate: SR), prefs: p); c2.setDecks(3)
        XCTAssertEqual(Core(engine: Engine(sampleRate: SR), prefs: p).deckCount, 3)
    }
    /// FLX4: SHIFT + LOAD 1 / 2 name decks 3 / 4, whichever decks the sides are on; plain LOAD follows the side
    func testShiftLoadGoesToDecks3And4() {
        let (c, _) = makeCore(); c.setFour(true)
        let rig = Rig(c)
        rig.midi.receive([0x96, 0x48, 0x7f]); rig.midi.receive([0x96, 0x49, 0x7f])
        XCTAssertEqual(rig.pressed.filter { $0.0 == "loadShift" }.map { $0.1 }, [2, 3])
        rig.midi.toggleSide(0)
        rig.midi.receive([0x96, 0x46, 0x7f])
        XCTAssertEqual(rig.pressed.last.map { [$0.0] + ["\($0.1)"] }, ["load", "2"], "LOAD 1 follows the left side (deck 3)")
    }
    func testProfilesAndKeys() {
        XCTAssertEqual(Profiles.profile(for: "DDJ-FLX4").id, "ddj-flx4")
        XCTAssertEqual(Profiles.profile(for: "DDJ-400").id, "ddj-400")
        XCTAssertEqual(Profiles.profile(for: "DDJ-FLX6").id, "ddj-rekordbox")
        XCTAssertEqual(Profiles.profile(for: "Some Keyboard").id, "learn")
        XCTAssertFalse(Profiles.mixxx.isEmpty, "Mixxx maps bundled")
        XCTAssertEqual(Keys.camelot(0)?.label, "8B"); XCTAssertEqual(Keys.camelot(21)?.label, "8A"); XCTAssertEqual(Keys.camelot(17)?.label, "4A")
        XCTAssertTrue(Keys.mixes(21, 0)); XCTAssertTrue(Keys.mixes(21, 16)); XCTAssertFalse(Keys.mixes(21, 1))
    }
}
