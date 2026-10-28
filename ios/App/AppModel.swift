// Ties it all together: the audio host and its engine, the decks (Core), the controller (MIDIHost +
// MIDIEngine), the library and the screen. Implements what the controller's actions do, like the web app's
// pressAction / setAbs.
import Foundation
import QuartzCore
import SwiftUI
import CrateboxKit

final class UserCueStore: CueStore {
    func load(_ id: String) -> (cue: Double?, hot: [Double?])? {
        guard let d = UserDefaults.standard.dictionary(forKey: "cb.cues." + id) else { return nil }
        let hot = (d["hot"] as? [Double] ?? []).map { $0 < 0 ? nil : $0 } as [Double?]
        let c = d["cue"] as? Double
        return (c == nil || c! < 0 ? nil : c, Array((hot + [Double?](repeating: nil, count: 8)).prefix(8)))
    }
    func save(_ id: String, cue: Double?, hot: [Double?]) {
        UserDefaults.standard.set(["cue": cue ?? -1, "hot": hot.map { $0 ?? -1 }], forKey: "cb.cues." + id)
    }
}

final class AppModel: ObservableObject, ControlTarget {
    let audio = AudioHost()
    let core: Core
    let midi = MIDIEngine()
    let midiHost = MIDIHost()
    let library = Library()
    let recorder = Recorder()
    let playlists = Playlists()
    /// the suite's other two modes (made on first use)
    lazy var bridge = DeckBridge()
    lazy var usb: USBSession = { let s = USBSession(app: self); usbMade = s; return s }()
    private(set) var usbMade: USBSession?        // Cratebox USB, once it's been opened (DriveWatch looks without making it)
    private var lastSec = 0.0
    @Published var statusText = ""
    @Published var controllerName = ""
    // the library row the browse knob and LOAD use, and the list it's in: remembered (per list, and across
    // restarts) so the browser opens where you left it
    @Published var selection: String? { didSet { if oldValue != selection { remember() } } }
    @Published var view: LibraryView = .collection {
        didSet { if oldValue != view { selection = lastSelection[LibraryPane.key(view)]; remember() } }
    }
    private var lastSelection = (UserDefaults.standard.dictionary(forKey: "cb.browseSel") as? [String: String]) ?? [:]
    private func remember() {
        let k = LibraryPane.key(view)
        lastSelection[k] = selection
        UserDefaults.standard.set(lastSelection, forKey: "cb.browseSel")
        UserDefaults.standard.set(k, forKey: "cb.browseView")
    }
    /// back to the list and track the browser was on last time (once the library and USBs are loaded)
    func restoreBrowse() {
        guard let k = UserDefaults.standard.string(forKey: "cb.browseView"), let src = browseSources().first(where: { $0.id == k }) else { return }
        view = src.view
    }
    @Published var browseFocusTree = false
    @Published var zoomSecs = 8.0
    @Published var tab = 0                       // phones: 0 = mix, 1 = library
    /// WAVE: the decks and mixer fold away, the waveforms fill the screen (remembered across launches)
    @Published var waveMode = UserDefaults.standard.bool(forKey: "cb.waveMode") { didSet { UserDefaults.standard.set(waveMode, forKey: "cb.waveMode") } }
    @Published var gridDeck: Int?                // the deck whose beat grid editor is open
    var visibleTrackIds: [String] = []           // the library list as shown (for the browse knob)
    var libraryShown = false                     // the library list is on screen (then the knob follows it, search included)
    @Published var browserShown = false          // the controller's browser over the decks (phones)
    private var browserUntil = 0.0
    private var statusUntil = 0.0
    private var timer: CADisplayLink?
    private var lastLed = 0.0, lastKeep = 0.0, frame = 0

    enum LibraryView: Hashable { case collection, playlist(String), device(String), devicePlaylist(String, UInt32) }

    init() {
        core = Core(engine: audio.engine, prefs: DefaultsPrefs(), cues: UserCueStore())
        core.clock = { [unowned self] in self.smoothClock() }
        core.lag = { [unowned self] in self.audio.latency }
        core.status = { [weak self] s, secs in self?.status(s, secs) }
        core.trackChanged = { [weak self] t in if let lt = self?.library.track(t.id) { self?.library.changed(lt) } }
        core.reanalyse = { [weak self] t in if let lt = self?.library.track(t.id) { lt.rec.ver = 0; self?.library.enqueue(lt) } }
        library.status = { [weak self] s in self?.status(s) }
        library.isPlaying = { [weak self] in self?.core.decks.contains { $0.playing } ?? false }
        recorder.app = self
        midi.target = self
        midi.send = { [weak self] b in self?.midiHost.send(b) }
        midi.loadLearned = { id in
            guard let d = UserDefaults.standard.data(forKey: "cb.learn.\(id)") else { return [] }
            return (try? JSONDecoder().decode([MapEntry].self, from: d)) ?? []
        }
        midi.saveLearned = { id, l in UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: "cb.learn.\(id)") }
        midi.onFxLever = { [weak self] d in self?.core.fx.channel(d ?? 4) }
        midi.onSide = { [weak self] in self?.objectWillChange.send() }      // the lanes' FLX4 glow follows the sides
        midiHost.onMessage = { [weak self] m in self?.midi.receive(m) }
        midiHost.onChange = { [weak self] name in self?.controllerConnected(name) }
        audio.onRoute = { [weak self] in DispatchQueue.main.async { self?.routeChanged() } }
    }

    func start() {
        audio.start()
        midiHost.start()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        timer = link
        for f in library.folders where !f.device && !(library.url(of: f).map(Library.isRekordboxExport) ?? false) { library.scan(f) }
        Devices.shared.app = self
        Devices.shared.restore()
        DriveWatch.shared.app = self
        DriveWatch.shared.start()
        restoreBrowse()
        if CommandLine.arguments.contains("-demo") { demo() }
    }

    /// For the simulator screenshots: a synthetic house loop on decks 1 and 2, deck 1 playing
    func demo() {
        Task.detached {
            let sr = AudioHost.sampleRate, n = Int(sr * 90), bpm = 124.0, spb = 60 / bpm
            let t = PCMTrack(count: n, sampleRate: sr)
            for i in 0..<n {
                let s = Double(i) / sr, ph = s.truncatingRemainder(dividingBy: spb), bar = Int(s / (4 * spb))
                let kick = ph < 0.25 ? sin(2 * .pi * (50 + 120 * exp(-ph * 30)) * ph) * exp(-ph * 9) : 0
                let hat = (s + spb / 2).truncatingRemainder(dividingBy: spb) < 0.03 ? Double.random(in: -0.25...0.25) : 0
                let bass = bar % 8 < 4 ? 0.25 * sin(2 * .pi * 55 * s) * (ph > spb / 2 ? 1 : 0.2) : 0
                let pad = 0.08 * sin(2 * .pi * 220 * s) + 0.06 * sin(2 * .pi * 329.6 * s)
                let v = Float(0.8 * kick + hat + bass + pad)
                t.left[i] = v; t.right[i] = v
            }
            let m = AudioDecoder.mono(t, 11025), w = AudioDecoder.mono(t, 22050)
            let r = Analysis.analyze(m.x, fs: m.fs, waveSource: w)
            await MainActor.run {
                let four = CommandLine.arguments.contains("-four")
                if CommandLine.arguments.contains("-wave") { self.waveMode = true }
                self.core.setFour(four)          // the simulator remembers 4 DECKS between launches: set it either way
                for k in 0..<(four ? 4 : 2) {
                    let info = TrackInfo(id: "demo\(k)", title: ["Demo Groove", "Demo Groove (dub)", "Demo Groove (tool)", "Demo Groove (edit)"][k], artist: "Cratebox")
                    let d = self.core.decks[k]
                    d.beginLoad(info)
                    d.finishLoad(info, pcm: t, analysis: DeckAnalysis(bpm: r.bpm, firstBeat: r.firstBeat, key: r.key, phrases: r.phrases, wave: r.wave, duration: 90), mono: m)
                }
                self.core.decks[0].seek(20); self.core.decks[0].togglePlay()
                self.core.decks[0].hotcue(0)
                self.core.decks[1].seek(12)
                if CommandLine.arguments.contains("-browse") {
                    // a stand-in library for the browser screenshot
                    let recs = (0..<14).map { k in TrackRecord(id: "demo-lib-\(k)", folder: "demo", rel: "\(k).wav", title: ["Night Drive", "Low End Theory", "Sub Pressure", "Warehouse 4AM", "Glass Ceiling", "Rewind Selecta", "Deep Cuts", "Bassline Hustle", "Halftime Heat", "Afterhours", "Roller", "Steppa", "Dub Siren", "Last Call"][k], artist: "Demo Artist \(k % 4 + 1)", size: 0, mtime: 0, bpm: Double([124, 126, 174, 128, 122, 172, 124, 130, 87, 125, 174, 140, 140, 120][k]), firstBeat: 0, key: (k * 5) % 24, duration: 300 + Double(k * 13), phrases: [], gridManual: false, autoBpm: nil, autoFirst: nil, ver: Library.ANALYSIS_VER) }
                    self.library.setDemoTracks(recs.map(LibTrack.init))
                    self.selection = "demo-lib-3"
                    self.showBrowser(600)
                }
                // a stand-in FLX4: connect, keep-alive, lights, then PLAY on deck 2 and its tempo fader
                self.midiHost.makeVirtualFLX4()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.midiHost.injectFromVirtual([0x91, 0x0b, 0x7f]); self.midiHost.injectFromVirtual([0x91, 0x0b, 0x00])
                    self.midiHost.injectFromVirtual([0xb1, 0x00, 0x30]); self.midiHost.injectFromVirtual([0xb1, 0x20, 0x00])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    let d = self.core.decks[1]
                    NSLog("DEMO MIDI: %@", "controller \(self.controllerName), deck 2 playing \(d.playing), pitch \(String(format: "%.3f", d.pitch)), messages to the controller \(self.midiHost.virtualReceived)")
                    self.status("MIDI test: \(self.controllerName) · deck 2 \(d.playing ? "playing" : "stopped") · \(self.midiHost.virtualReceived) messages sent", 60)
                }
            }
        }
    }

    /// The audio clock for the screen. The raw estimate (last block's time + host time since it was rendered)
    /// jumps by up to a buffer every callback, because iOS renders buffers early and unevenly; drawn as is,
    /// the waveforms shake. This runs on the host clock and is nudged toward the raw estimate gently (about
    /// half a second to settle), snapping only after a real jump (a restart of the audio).
    private var cAudio = 0.0, cHost = 0.0
    func smoothClock() -> Double {
        let s = core.lastSnapshot
        if s.host == 0 { return s.time }
        let now = hostSeconds(), raw = s.time + min(0.25, max(0, now - s.host))
        if cHost == 0 { cAudio = raw; cHost = now; return raw }
        let dt = max(0, now - cHost)
        var t = cAudio + dt
        let err = raw - t
        if abs(err) > 0.08 { t = raw } else { t += err * min(1, dt * 2) }
        cAudio = t; cHost = now
        // what you hear lags the audio clock by the output's latency (a lot, on Bluetooth): show that moment
        return t - audio.latency
    }

    @objc func tick() {
        core.tick()
        let now = hostSeconds()
        if now - lastLed > 0.05 { lastLed = now; midi.updateLeds(blink: Int(now * 2) % 2 == 0) }
        if now - lastKeep > 0.2 { lastKeep = now; midi.keepAliveTick() }
        if now - lastSec > 1 { lastSec = now; recorder.noteAudible(core) }
        if statusUntil > 0 && now > statusUntil { statusUntil = 0; statusText = "" }
        if browserShown && now > browserUntil { browserShown = false; browseFocusTree = false; treeCursor = nil }
        frame += 1
        // the decks' readouts (time, beat, sync offset) follow the playhead: refresh ~20 times a second
        if frame % 3 == 0 { for d in core.decks where d.loaded { d.objectChanged() } }
    }

    func status(_ s: String, _ secs: Double = 4) {
        statusText = s
        statusUntil = secs > 0 ? hostSeconds() + secs : 0
    }

    private var toldWireless = ""
    /// output changed: tell about Bluetooth's delay once per device
    func routeChanged() {
        objectWillChange.send()
        if audio.wireless {
            if toldWireless != audio.outputName {
                toldWireless = audio.outputName
                status("Bluetooth: \(audio.outputName) plays about \(Int(audio.latency * 1000)) ms late. The waveforms are shifted to match what you hear, and SYNC still locks, but mixing by ear and scratching will feel late, and there's no separate headphone cue. For gigs, use the controller's outputs or a cable.", 14)
            }
        } else { toldWireless = "" }
    }
    func controllerConnected(_ name: String) {
        controllerName = name
        guard !name.isEmpty else { status("Controller disconnected"); return }
        let forced = UserDefaults.standard.string(forKey: "cb.profileFor.\(name)") ?? ""
        let p = midi.use(Profiles.byId(forced) ?? Profiles.profile(for: name))
        midi.connected()
        // a controller whose MASTER LEVEL works in its own hardware: Cratebox's master goes to its default level, so the
        // knob on the controller is the only master
        if !midi.hasAction("master") { core.mixer.master = 0.8 }
        status("\(name) connected · \(p.name)\(p.src == .tested ? "" : " (see Settings → Controller)")")
    }
    func useProfile(_ id: String) {
        guard let p = Profiles.byId(id) else { return }
        if !controllerName.isEmpty { UserDefaults.standard.set(id, forKey: "cb.profileFor.\(controllerName)") }
        midi.use(p); midi.connected()
    }

    // ---- loading ----
    func load(_ t: LibTrack, deck: Int) {
        let d = core.decks[deck]
        if let why = d.canLoad() { status(why); return }
        guard let url = Devices.shared.url(for: t) ?? library.fileURL(t) else { status("\(t.rec.title) isn't in a connected folder"); return }
        d.beginLoad(t.info)
        status("Loading \(t.info.title) into deck \(deck + 1)...", 0)
        let info = t.info
        let analysedBefore = t.analysed && (t.info.bpm ?? 0) > 0 && t.info.firstBeat != nil
        // what the analysis needs from the track, read here: TrackInfo is the screen's, so the background task
        // works on copies and everything it finds is put back on the main thread
        let rbURL = t.device != nil ? Devices.shared.anlzURL(t) : nil, onStick = t.device != nil
        let manual = info.gridManual, keyRB = info.keyFromRekordbox
        let had = (bpm: info.bpm, first: info.firstBeat, phrases: info.phrases, key: info.key, beats: info.rbBeats, beat0: info.rbBeat0)
        Task.detached(priority: .userInitiated) {
            do {
                // a rekordbox USB track: rekordbox's own grid, phrases and cues (read first, so they're used
                // instead of Cratebox's analysis)
                let rb = rbURL.flatMap { Devices.readAnalysis(at: $0) }
                var bpm = had.bpm, first = had.first, phrases = had.phrases, beats = had.beats, beat0 = had.beat0
                if let rb {
                    if !manual { bpm = rb.bpm; first = rb.firstBeat }
                    beats = rb.beats; beat0 = rb.beat0
                    if let ph = rb.phrases { phrases = ph }
                }
                let fromRekordbox = onStick && (bpm ?? 0) > 0 && first != nil
                let cached = analysedBefore || fromRekordbox
                let pcm = try AudioDecoder.decode(url)
                let m = AudioDecoder.mono(pcm, 11025), w = AudioDecoder.mono(pcm, 22050)
                let dur = Double(pcm.count) / pcm.sampleRate
                var a: DeckAnalysis
                var auto: (bpm: Double, first: Double)?
                if cached || manual {
                    let wave = Analysis.waveform(w.x, w.fs)
                    let ph = cached && !phrases.isEmpty ? phrases : Analysis.phraseAnalysis(m.x, m.fs, bpm ?? 120, first ?? 0)
                    var key = had.key
                    if !cached { key = Analysis.detectKey(m.x, m.fs).key }
                    a = DeckAnalysis(bpm: bpm ?? 120, firstBeat: first ?? 0, key: key, phrases: ph, wave: wave, duration: dur)
                    // rekordbox's grid beat by beat (unless the grid was edited by hand here)
                    if fromRekordbox && !manual, let b = beats, b.count >= 2 { a.beats = b; a.beat0 = beat0 }
                } else {
                    let r = Analysis.analyze(m.x, fs: m.fs, range: Settings.bpmRange, waveSource: w)
                    a = DeckAnalysis(bpm: r.bpm, firstBeat: r.firstBeat, key: keyRB && had.key >= 0 ? had.key : r.key, phrases: r.phrases, wave: r.wave, duration: dur)
                    auto = (r.bpm, r.firstBeat)
                }
                let found = a, autoGrid = auto
                await MainActor.run {
                    if let rb { Devices.apply(rb, to: t) }
                    if let g = autoGrid { info.autoBpm = g.bpm; info.autoFirst = g.first }
                    t.rec.ver = Library.ANALYSIS_VER
                    d.finishLoad(info, pcm: pcm, analysis: found, mono: m)
                    self.library.changed(t)
                    self.library.objectWillChange.send()
                }
            } catch {
                await MainActor.run { d.failLoad(info, error.localizedDescription) }
            }
        }
    }
    func loadSelected(_ deck: Int) {
        guard let id = selection, let t = library.track(id) else { showBrowser(); status("Turn the browse knob to pick a track (press it for playlists)"); return }
        load(t, deck: deck)
    }
    // ---- browsing from the controller: the knob walks the tracks, or (press it) the playlist tree ----
    struct BrowseSource: Identifiable {
        let view: LibraryView; let name: String; let depth: Int; let group: String
        var id: String { LibraryPane.key(view) }
        var deviceId: String? { switch view { case .device(let d), .devicePlaylist(let d, _): return d; default: return nil } }
    }
    /// Collection, your playlists, then each USB and its rekordbox playlists, in tree order (folders are
    /// walked through, not stopped on). `group` is the heading the browser shows above each lot.
    func browseSources() -> [BrowseSource] {
        var out = [BrowseSource(view: .collection, name: "Collection", depth: 0, group: "CRATEBOX")]
        func local(_ parent: String?, _ depth: Int) {
            for p in playlists.children(parent) {
                if p.folder { local(p.id, depth + 1) } else { out.append(BrowseSource(view: .playlist(p.id), name: p.name, depth: depth, group: "CRATEBOX")) }
            }
        }
        local(nil, 0)
        for d in Devices.shared.list {
            out.append(BrowseSource(view: .device(d.id), name: "All tracks", depth: 0, group: d.name))
            func walk(_ parent: UInt32, _ depth: Int) {
                for n in d.tree.filter({ $0.parent == parent }).sorted(by: { $0.sort < $1.sort }) {
                    if n.folder { walk(n.id, depth + 1) } else { out.append(BrowseSource(view: .devicePlaylist(d.id, n.id), name: n.name, depth: depth, group: d.name)) }
                }
            }
            walk(0, 0)
        }
        return out
    }
    /// pressing the knob: the playlists, with a cursor that only becomes the list when the knob is
    /// pressed again (closing the browser, or LOAD, leaves you in the list you were in)
    @Published var treeCursor: LibraryView?
    /// the tracks the knob moves through: the list on screen, or the current view with its saved sort
    func browseTracks() -> [LibTrack] {
        if libraryShown && !visibleTrackIds.isEmpty { return visibleTrackIds.compactMap { library.track($0) } }
        return LibraryPane.build(view, library, playlists, Devices.shared, query: "", sort: LibraryPane.storedSort(view)).compactMap { $0.t }
    }
    func showBrowser(_ secs: Double = 8) {
        browserUntil = hostSeconds() + secs
        if !browserShown && !(tab == 1) { browserShown = true }
    }
    func hideBrowser() { browserUntil = 0; browserShown = false; browseFocusTree = false; treeCursor = nil }
    func moveSelection(_ n: Int) {
        showBrowser()
        if browseFocusTree {
            let src = browseSources()
            let i = src.firstIndex { $0.view == (treeCursor ?? view) } ?? 0
            treeCursor = src[max(0, min(src.count - 1, i + n))].view
            return
        }
        let ids = browseTracks().map { $0.id }
        guard !ids.isEmpty else { status("Nothing in \(browseTitle) yet: press the browse knob to pick a playlist"); return }
        let i = ids.firstIndex(of: selection ?? "") ?? -1
        selection = ids[max(0, min(ids.count - 1, i + n))]
    }
    var browseTitle: String { browseSources().first { $0.view == view }?.name ?? "the list" }

    // ---- ControlTarget: what the controller's actions do ----
    var fourDecks: Bool { core.four }
    var deckCount: Int { core.deckCount }
    /// 2, 3 or 4 decks; a controller side on a deck that's gone goes back to its own
    func setDecks(_ n: Int) {
        core.setDecks(n)
        for s in 0..<2 where midi.side[s] >= core.deckCount { midi.setSide(s, s) }
        if !core.four { midi.resetSides() }
    }
    func cycleDecks() { setDecks(core.deckCount == 4 ? 2 : core.deckCount + 1) }
    func absValue(_ name: String, deck: Int) -> Double? { core.mixerValue(name, deck) }
    func setAbs(_ name: String, deck: Int, _ v: Double) {
        switch name {
        case "tempo": core.decks[deck].setPitch(v * 2 - 1)        // top = slower, bottom = faster, like a CDJ
        case "fxDepth": core.fx.setDepth(v)
        default: core.setMixer(name, deck, v)
        }
    }
    func relative(_ name: String, deck: Int, ticks: Int) {
        switch name {
        case "jogTop": core.decks[deck].jogTicks(Double(ticks), .scratch)
        case "jogSide": core.decks[deck].jogTicks(Double(ticks), .bend)
        case "jogSearch": core.decks[deck].jogTicks(Double(ticks), .search)
        case "browse": moveSelection(ticks)
        case "zoom": zoomSecs = min(32, max(2, zoomSecs * (ticks > 0 ? 0.8 : 1.25)))
        default: break
        }
    }
    func press(_ name: String, arg: String, deck: Int, on: Bool) {
        let d = deck >= 0 && deck < 4 ? core.decks[deck] : nil
        switch name {
        case "play": if on { d?.togglePlay() }
        case "playCue": if on, let d { d.seek(d.cue); d.setPlaying(true) }
        case "cue": if on { d?.cueDown() } else { d?.cueUp() }
        case "start": if on, let d { d.setPlaying(false); d.seek(0) }
        case "sync": if on, let d { d.setSync(!d.sync) }
        case "syncOn": if on, let d, !d.sync { d.setSync(true) }
        case "range": if on { d?.cycleRange() }
        case "touch": d?.jogTouch(on)
        case "loopIn": d?.loopInPress(on)
        case "loopOut": if on { d?.loopOut() }
        case "reloop": if on { d?.reloopExit() }
        case "reloopStop": if on, let d { d.reloopExit(); if d.loop.on { d.setPlaying(false) } }
        case "loopHalf": if on { d?.loopScale(0.5) }
        case "loopDouble": if on { d?.loopScale(2) }
        case "callPrev": if on { d?.callCue(-1) }
        case "callNext": if on { d?.callCue(1) }
        case "jump": if on, let b = Double(arg) { d?.beatJump(b) }
        case "pfl": if on, deck >= 0 { core.togglePfl(deck) }
        case "masterCue": if on { core.toggleMasterCue() }
        case "fxSelect": if on { core.fx.select(1) }
        case "fxSelectPrev": if on { core.fx.select(-1) }
        case "fxBeatDown": if on { core.fx.beatStep(-1) }
        case "fxBeatUp": if on { core.fx.beatStep(1) }
        case "fxOn": if on { core.fx.setOn(!core.fx.on) }
        case "fxOff": if on { core.fx.setOn(false) }
        case "pfx": if let p = Int(arg), deck >= 0 { on ? core.fx.padDown(deck, .padfx, p) : core.fx.padUp(deck, .padfx, p) }
        case "pfx2": if let p = Int(arg), deck >= 0 { on ? core.fx.padDown(deck, .padfx2, p) : core.fx.padUp(deck, .padfx2, p) }
        case "quant": if on { d?.quant.toggle() }
        case "keylock": if on, let d { d.setMT(!d.mt) }
        case "mode":
            if on { if let m = PadMode(rawValue: arg) { d?.padMode = m } else { status("Pad mode \"\(arg)\" isn't in Cratebox yet") } }
        case "hot": if on, let k = Int(arg) { d?.hotcue(k) }
        case "hotClear": if on, let k = Int(arg) { d?.clearHot(k) }
        case "loop": if on, let b = Double(arg) { d?.beatLoop(b) }
        case "load":
            if on, deck >= 0 {
                if browseFocusTree { browseFocusTree = false; treeCursor = nil; showBrowser(); status("Pick a track, then LOAD"); return }
                loadSelected(deck); hideBrowser()
            }
        case "loadShift":
            // SHIFT + LOAD 1 / 2: decks 3 / 4 (only while they're on)
            if on, deck >= 2 {
                guard core.deckActive(deck) else { status("Deck \(deck + 1) isn't on: press DECKS for \(deck == 2 ? "3" : "4") decks"); return }
                if browseFocusTree { browseFocusTree = false; treeCursor = nil; showBrowser(); status("Pick a track, then LOAD"); return }
                loadSelected(deck); hideBrowser()
            }
        case "browsePress":
            guard on else { break }
            // the first press only brings the browser up, on the list you were in
            if !browserShown { browseFocusTree = false; treeCursor = nil; showBrowser(); break }
            if browseFocusTree {
                if let c = treeCursor { view = c }        // open the playlist under the cursor
                treeCursor = nil; browseFocusTree = false
            } else { treeCursor = view; browseFocusTree = true }
            showBrowser()
        case "browseShift": if on { tab = tab == 0 ? 1 : 0 }
        case "browseUp": if on { moveSelection(-1) }
        case "browseDown": if on { moveSelection(1) }
        case "unsupported": if on { status("\(arg) isn't in Cratebox yet") }
        default: break
        }
    }
    func led(_ name: String, arg: String, deck: Int, blink: Bool) -> Int? {
        if name == "fxOn" { return core.fx.on ? 127 : 0 }
        guard deck >= 0 && deck < 4 else { return nil }
        let d = core.decks[deck]
        let b = { (v: Bool) in v ? 127 : 0 }
        switch name {
        case "play": return b(d.playing ? true : d.loaded ? blink : false)        // PLAY blinks when paused
        case "cue":
            let atCue = d.loaded && abs(d.now() - d.cue) < 0.03
            return b(d.loaded && (atCue || d.previewing) ? true : d.loaded && !d.playing ? blink : false)
        case "sync": return b(d.sync)
        case "pfl": return b(core.mixer.pfl[deck])
        case "loopIn": return b(d.loop.on || (d.loop.a != nil && d.loop.b == nil && blink))
        case "loopOut": return b(d.loop.on)
        case "reloop": return b(d.loop.b != nil)
        case "keylock": return b(d.mt)
        case "quant": return b(d.quant)
        case "mode": return b(d.padMode.rawValue == arg)
        case "hot": return b(d.padMode == .hotcue && (Int(arg).map { d.hot[$0] != nil } ?? false))
        case "loop": return b(d.padMode == .beatloop && d.loop.on && abs(d.loopBeats() - (Double(arg) ?? 0)) < 0.01)
        case "pfx", "pfx2":
            let bank: PadMode = name == "pfx" ? .padfx : .padfx2
            return b(d.padMode == bank && core.fx.pad[deck].map { $0.p == Int(arg) && $0.bank == bank } == true)
        default: return nil
        }
    }
    func vu(deck: Int) -> Double {
        let r = core.lastSnapshot.decks[deck]
        let p = Double(max(r.peakL, r.peakR))
        return p <= 0 ? 0 : min(1, max(0, (20 * log10(p) + 48) / 48))
    }
    func controllerStatus(_ s: String) { status(s, 6) }
}

// ---- rekordbox XML ----
extension AppModel {
    func importXml(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url), let x = try? RekordboxXML.parse(data) else { status("Couldn't read that file: not a rekordbox XML export", 8); return }
        // match rekordbox's tracks to files Cratebox knows (file name + size, then file name)
        var byFile = [String: LibTrack]()
        for t in library.tracks where t.device == nil {
            let f = (t.rec.rel as NSString).lastPathComponent.lowercased()
            byFile["\(f)|\(t.rec.size)"] = t
            if byFile[f] == nil { byFile[f] = t }
        }
        var resolved = [String: LibTrack](), matched = 0, applied = 0
        for id in x.order {
            guard let r = x.tracks[id] else { continue }
            let f = r.filename.lowercased()
            guard let t = byFile["\(f)|\(r.size)"] ?? byFile[f] else { continue }
            matched += 1; resolved[id] = t
            var did = false
            if let g = r.grid, g.bpm > 0, !t.info.gridManual {
                let spb = 60 / g.bpm, bar = 4 * spb
                var first = g.firstBeat - Double(g.beat - 1) * spb           // back to the downbeat
                first -= (first / bar).rounded(.down) * bar
                t.info.bpm = g.bpm; t.info.firstBeat = first; t.info.gridManual = true
                if t.info.autoBpm == nil { t.info.autoBpm = g.bpm; t.info.autoFirst = first }
                did = true
            }
            let k = RekordboxANLZ.keyIndex(r.key)
            if k >= 0 { t.info.key = k; t.info.keyFromRekordbox = true; did = true }
            if t.info.duration == 0 && r.duration > 0 { t.info.duration = r.duration }
            if !r.marks.isEmpty && core.cues.load(t.id) == nil {
                var hot = [Double?](repeating: nil, count: 8)
                for m in r.marks where m.num >= 0 && m.num < 8 { hot[m.num] = m.start }
                let mem = r.marks.filter { $0.num == -1 }.map { $0.start }.min()
                core.cues.save(t.id, cue: mem, hot: hot); did = true
            }
            if did { applied += 1; library.changed(t); if !t.analysed { library.enqueue(t) } }
        }
        // playlists go into a folder of their own
        let df = DateFormatter(); df.dateStyle = .short
        let top = playlists.new("rekordbox (\(df.string(from: Date())))", folder: true)
        var made = [Int: String]()
        for n in x.playlists {
            let parent = n.parent.flatMap { made[$0] } ?? top.id
            let p = playlists.new(n.name, folder: n.folder, parent: parent)
            made[n.key] = p.id
            if !n.folder { playlists.add(n.tracks.compactMap { resolved[$0] }, to: p.id) }
        }
        library.objectWillChange.send()
        status("rekordbox XML: \(x.tracks.count) tracks (\(matched) found in your folders, grids/cues/keys taken from rekordbox for \(applied)), \(x.playlists.filter { !$0.folder }.count) playlists", 12)
    }
    func exportXml() -> URL? {
        let own = library.tracks.filter { $0.device == nil }
        let ts = own.map { t -> RekordboxXML.ExportTrack in
            let c = core.cues.load(t.id)
            let folderName = library.folders.first { $0.id == t.rec.folder }?.name ?? ""
            return RekordboxXML.ExportTrack(id: t.id, title: t.info.title, artist: t.info.artist, file: (t.rec.rel as NSString).lastPathComponent, rel: folderName + "/" + t.rec.rel,
                                            size: Int(t.rec.size), duration: t.info.duration, bpm: t.info.bpm ?? 0, firstBeat: t.info.firstBeat, key: t.info.key, cue: c?.cue, hot: c?.hot ?? [])
        }
        let ls = playlists.lists.map { RekordboxXML.ExportList(id: $0.id, name: $0.name, folder: $0.folder, parent: $0.parent, order: $0.order, items: $0.items) }
        let s = RekordboxXML.export(ts, ls, root: UserDefaults.standard.string(forKey: "cb.basePath") ?? "")
        let u = Recorder.folder.appendingPathComponent("cratebox-rekordbox.xml")
        do { try s.write(to: u, atomically: true, encoding: .utf8) } catch { status("Couldn't write the XML: \(error.localizedDescription)"); return nil }
        status("Exported \(own.count) tracks and \(playlists.lists.filter { !$0.folder }.count) playlists. In rekordbox: Preferences → Advanced → Imported Library = this file.", 12)
        return u
    }
}

enum Settings {
    static var bpmRange: (Double, Double) {
        switch UserDefaults.standard.string(forKey: "cb.bpmRange") ?? "88-175" {
        case "58-115": return (58, 116)
        case "68-135": return (68, 136)
        case "78-155": return (78, 156)
        case "70-180": return (70, 181)   // wider than an octave: most tracks keep the tempo the analyser hears
        case "custom": return customRange(lo: UserDefaults.standard.object(forKey: "cb.bpmLo") as? Int ?? 70,
                                          hi: UserDefaults.standard.object(forKey: "cb.bpmHi") as? Int ?? 180)
        default: return (88, 176)
        }
    }
    /// a custom range made usable: at least an octave wide so every tempo folds into it; top end inclusive
    static func customRange(lo: Int, hi: Int) -> (Double, Double) {
        let lo = min(max(lo, 40), 150)
        return (Double(lo), Double(min(max(hi, 2 * lo - 1), 300) + 1))
    }
}
