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
    private var lastSec = 0.0
    @Published var statusText = ""
    @Published var controllerName = ""
    @Published var selection: String?           // the library row the browse knob and LOAD use
    @Published var view: LibraryView = .collection
    @Published var browseFocusTree = false
    @Published var zoomSecs = 8.0
    @Published var tab = 0                       // phones: 0 = mix, 1 = library
    @Published var gridDeck: Int?                // the deck whose beat grid editor is open
    var visibleTrackIds: [String] = []           // the library list as shown (for the browse knob)
    private var statusUntil = 0.0
    private var timer: CADisplayLink?
    private var lastLed = 0.0, lastKeep = 0.0, frame = 0

    enum LibraryView: Hashable { case collection, playlist(String), device(String), devicePlaylist(String, UInt32) }

    init() {
        core = Core(engine: audio.engine, prefs: DefaultsPrefs(), cues: UserCueStore())
        core.clock = { [unowned self] in
            let s = self.core.lastSnapshot
            if s.host == 0 { return s.time }
            return s.time + min(0.25, max(0, hostSeconds() - s.host))
        }
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
        midiHost.onMessage = { [weak self] m in self?.midi.receive(m) }
        midiHost.onChange = { [weak self] name in self?.controllerConnected(name) }
    }

    func start() {
        audio.start()
        midiHost.start()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        timer = link
        for f in library.folders where !f.device { library.scan(f) }
        Devices.shared.app = self
        Devices.shared.restore()
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
                for k in 0..<2 {
                    let info = TrackInfo(id: "demo\(k)", title: k == 0 ? "Demo Groove" : "Demo Groove (dub)", artist: "Cratebox")
                    let d = self.core.decks[k]
                    d.beginLoad(info)
                    d.finishLoad(info, pcm: t, analysis: DeckAnalysis(bpm: r.bpm, firstBeat: r.firstBeat, key: r.key, phrases: r.phrases, wave: r.wave, duration: 90), mono: m)
                }
                self.core.decks[0].seek(20); self.core.decks[0].togglePlay()
                self.core.decks[0].hotcue(0)
                self.core.decks[1].seek(12)
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

    @objc func tick() {
        core.tick()
        let now = hostSeconds()
        if now - lastLed > 0.05 { lastLed = now; midi.updateLeds(blink: Int(now * 2) % 2 == 0) }
        if now - lastKeep > 0.2 { lastKeep = now; midi.keepAliveTick() }
        if now - lastSec > 1 { lastSec = now; recorder.noteAudible(core) }
        if statusUntil > 0 && now > statusUntil { statusUntil = 0; statusText = "" }
        frame += 1
        // the decks' readouts (time, beat, sync offset) follow the playhead: refresh ~20 times a second
        if frame % 3 == 0 { for d in core.decks where d.loaded { d.objectChanged() } }
    }

    func status(_ s: String, _ secs: Double = 4) {
        statusText = s
        statusUntil = secs > 0 ? hostSeconds() + secs : 0
    }

    func controllerConnected(_ name: String) {
        controllerName = name
        guard !name.isEmpty else { status("Controller disconnected"); return }
        let forced = UserDefaults.standard.string(forKey: "cb.profileFor.\(name)") ?? ""
        let p = midi.use(Profiles.byId(forced) ?? Profiles.profile(for: name))
        midi.connected()
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
        let cached = t.analysed && (t.info.bpm ?? 0) > 0 && t.info.firstBeat != nil
        let info = t.info
        Task.detached(priority: .userInitiated) {
            do {
                if t.device != nil { Devices.shared.readAnalysis(t) }
                let pcm = try AudioDecoder.decode(url)
                let m = AudioDecoder.mono(pcm, 11025), w = AudioDecoder.mono(pcm, 22050)
                let dur = Double(pcm.count) / pcm.sampleRate
                var a: DeckAnalysis
                if cached || info.gridManual {
                    let wave = Analysis.waveform(w.x, w.fs)
                    let ph = cached && !info.phrases.isEmpty ? info.phrases : Analysis.phraseAnalysis(m.x, m.fs, info.bpm ?? 120, info.firstBeat ?? 0)
                    var key = info.key
                    if !cached { key = Analysis.detectKey(m.x, m.fs).key }
                    a = DeckAnalysis(bpm: info.bpm ?? 120, firstBeat: info.firstBeat ?? 0, key: key, phrases: ph, wave: wave, duration: dur)
                } else {
                    let r = Analysis.analyze(m.x, fs: m.fs, range: Settings.bpmRange, waveSource: w)
                    a = DeckAnalysis(bpm: r.bpm, firstBeat: r.firstBeat, key: info.keyFromRekordbox && info.key >= 0 ? info.key : r.key, phrases: r.phrases, wave: r.wave, duration: dur)
                    info.autoBpm = r.bpm; info.autoFirst = r.firstBeat
                }
                await MainActor.run {
                    t.rec.ver = Library.ANALYSIS_VER
                    d.finishLoad(info, pcm: pcm, analysis: a, mono: m)
                    self.library.changed(t)
                    self.library.objectWillChange.send()
                }
            } catch {
                await MainActor.run { d.failLoad(info, error.localizedDescription) }
            }
        }
    }
    func loadSelected(_ deck: Int) {
        guard let id = selection, let t = library.track(id) else { status("Select a track first"); return }
        load(t, deck: deck)
    }
    func moveSelection(_ n: Int) {
        let ids = visibleTrackIds
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: selection ?? "") ?? -1
        selection = ids[max(0, min(ids.count - 1, i + n))]
    }

    // ---- ControlTarget: what the controller's actions do ----
    var fourDecks: Bool { core.four }
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
        case "load": if on, deck >= 0 { loadSelected(midi.side.indices.contains(deck) && core.four ? deck : deck) }
        case "browsePress": if on { browseFocusTree.toggle() }
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
        default: return (88, 176)
        }
    }
}
