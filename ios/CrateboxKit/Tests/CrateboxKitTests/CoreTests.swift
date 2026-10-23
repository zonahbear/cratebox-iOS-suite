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
        func absValue(_ name: String, deck: Int) -> Double? { core.mixerValue(name, deck) }
        func setAbs(_ name: String, deck: Int, _ v: Double) { if name == "tempo" { core.decks[deck].setPitch(v * 2 - 1) } else { core.setMixer(name, deck, v) } }
        func press(_ name: String, arg: String, deck: Int, on: Bool) {
            let d = deck >= 0 ? core.decks[deck] : nil
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
