import SwiftUI
import AVKit
import CrateboxKit

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @State private var settings = false

    var body: some View {
        // a phone: the whole screen, edge to edge (PhoneScreen keeps the controls clear of the island itself)
        if UIDevice.current.userInterfaceIdiom == .phone {
            PhoneScreen(settings: $settings)
                .sheet(isPresented: $settings) { SettingsView() }
                .sheet(isPresented: $app.eqShown) { MasterEQView() }
                .sheet(item: Binding(get: { app.gridDeck.map { GridTarget(id: $0) } }, set: { app.gridDeck = $0?.id })) { t in GridEditor(deck: core.decks[t.id]) }
        } else { pad }
    }
    var pad: some View {
        // the reader only measures: PadFrame reads the app's state in its own body. Built with Xcode 27, state read
        // only inside a reader's closure doesn't redraw (as PhoneFrame found): reading WAVE out here wasn't enough,
        // 4 DECKS, the controller's name and the status line in the top bar were read in there too
        GeometryReader { g in PadFrame(settings: $settings, size: g.size) }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $app.eqShown) { MasterEQView() }
        .sheet(item: Binding(get: { app.gridDeck.map { GridTarget(id: $0) } }, set: { app.gridDeck = $0?.id })) { t in GridEditor(deck: core.decks[t.id]) }
    }
    struct GridTarget: Identifiable { let id: Int }

}

/// the iPad's screen, sized by ContentView's reader. Reads the app's state in its own body, so a change redraws it
struct PadFrame: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @Binding var settings: Bool
    let size: CGSize
    var body: some View {
        VStack(spacing: 6) {
            topBar
            // a short iPad (mini, ~724 pt): BEAT FX folds into a button and the library can get smaller
            if app.waveMode { WaveStack().frame(maxHeight: .infinity) } else { mix(compact: size.height < 900, short: size.height < 800) }
            LibraryPane().frame(minHeight: size.height < 800 ? 130 : 180)
        }
        .padding(6)
        .background(Theme.bg)
    }
    @ViewBuilder func mix(compact: Bool, short: Bool = false) -> some View {
        if core.four && short {
            // 4 decks on a short iPad (mini): two columns of decks don't fit, so like the iPhone it shows the two
            // decks the controller is on (DECK 1 / 3, 2 / 4 switch on each) around their two channels
            let l = app.midi.side[0], r = app.midi.side[1]
            VStack(spacing: 6) {
                VStack(spacing: 3) { ForEach(core.activeDecks, id: \.self) { i in PhoneLane(deck: core.decks[i]).frame(height: 54) } }
                HStack(alignment: .top, spacing: 6) {
                    DeckView(deck: core.decks[l], phone: true).id(l)
                    MixerView(phone: true)
                    DeckView(deck: core.decks[r], phone: true).id(r)
                }
            }
        } else if core.four {
            // 4 decks on an iPad: all four waveforms across the top, the decks' controls in two columns
            VStack(spacing: 6) {
                VStack(spacing: 3) { ForEach(core.activeDecks, id: \.self) { i in PhoneLane(deck: core.decks[i]).frame(height: compact ? 54 : 70) } }
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 6) { DeckView(deck: core.decks[0], phone: true, chips: false); DeckView(deck: core.decks[2], phone: true, chips: false) }
                    MixerView(compact: true, short: short)
                    VStack(spacing: 6) { DeckView(deck: core.decks[1], phone: true, chips: false); if core.deckCount == 4 { DeckView(deck: core.decks[3], phone: true, chips: false) } }
                }
            }
        } else { mix2(compact: compact, short: short) }
    }
    func mix2(compact: Bool, short: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 6) { DeckView(deck: core.decks[0], compact: compact || core.four); if core.four { DeckView(deck: core.decks[2], compact: true) } }
            MixerView(compact: compact || core.four, short: short)
            VStack(spacing: 6) { DeckView(deck: core.decks[1], compact: compact || core.four); if core.deckCount == 4 { DeckView(deck: core.decks[3], compact: true) } }
        }
    }

    var topBar: some View {
        HStack(spacing: 8) {
            ModeSwitcher()
            Text("CRATEBOX").font(.system(size: 15, weight: .heavy)).tracking(3)
            HStack(spacing: 4) {
                Circle().fill(app.controllerName.isEmpty ? Theme.dim : Theme.ok).frame(width: 7, height: 7)
                Text(app.controllerName.isEmpty ? "No controller" : app.controllerName).font(.system(size: 11)).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.raise))
            Text(app.audio.outputChannels >= 4 ? "4 ch · cue on 3/4" : "2 ch").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            Text(app.statusText).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            RecButton()
            LitButton(label: "WAVE", on: app.waveMode, color: Theme.accent) { withAnimation(.easeInOut(duration: 0.2)) { app.waveMode.toggle() } }
            LitButton(label: "\(core.deckCount) DECKS", on: core.four, color: Theme.fg) { app.cycleDecks() }
            DriveEjectButton()
            Button { settings = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
        }.padding(.horizontal, 4).zIndex(1)
    }
}

/// Beat grid: BPM, ◀ ▶ slide, set bar 1 or the nearest beat at the playhead, tap tempo, reset
struct GridEditor: View {
    @ObservedObject var deck: DeckModel
    @Environment(\.dismiss) var dismiss
    @State private var bpmText = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Tempo") {
                    HStack {
                        TextField("BPM", text: $bpmText).keyboardType(.decimalPad).onAppear { bpmText = String(format: "%.2f", deck.bpm) }
                        Button("Set") { if let v = Double(bpmText.replacingOccurrences(of: ",", with: ".")) { deck.setBpm(v) } }
                    }
                    HStack { Button("×2") { deck.setBpm(deck.bpm * 2) }; Spacer(); Button("÷2") { deck.setBpm(deck.bpm / 2) }; Spacer(); Button("TAP") { deck.tap() } }.buttonStyle(.bordered)
                }
                Section("Grid") {
                    HStack { Button("◀ 5 ms") { deck.nudgeGrid(-0.005) }; Spacer(); Button("◀ 1 ms") { deck.nudgeGrid(-0.001) }; Spacer(); Button("1 ms ▶") { deck.nudgeGrid(0.001) }; Spacer(); Button("5 ms ▶") { deck.nudgeGrid(0.005) } }.buttonStyle(.bordered)
                    Button("Bar 1 at the playhead") { deck.downbeatHere() }
                    Button("Beat at the playhead") { deck.beatHere() }
                    Button("Reset to the analysis", role: .destructive) { deck.resetGrid() }
                }
            }
            .navigationTitle("Deck \(deck.i + 1) beat grid")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var devices: Devices
    @Environment(\.dismiss) var dismiss
    @AppStorage("cb.bpmRange") var bpmRange = "88-175"
    @AppStorage("cb.bpmLo") var bpmLo = 70
    @AppStorage("cb.bpmHi") var bpmHi = 180
    @AppStorage("cb.split") var split = false
    @AppStorage("cb.recFmt") var recFmt = "wav"
    @AppStorage("cb.phrases") var phrases = true
    @AppStorage("cb.wave") var waveStyle = "rgb"
    @AppStorage("cb.compact") var compact = false
    @AppStorage(AIMode.key) var aiMode = false
    @AppStorage(AutoTrim.key) var autoTrim = false
    @AppStorage(AutoTrim.targetKey) var autoTrimTarget = -9.0
    @AppStorage(AppleGridMode.key) var appleGrid = 0
    @ObservedObject var apple = AppleMusic.shared
    @State private var warn = false
    @State private var learning = false
    @State private var hint = ""

    /// auto trim turned on or its loudness changed: the loaded decks too (a playing one glides)
    func retrim() { for i in core.activeDecks where core.decks[i].loaded { app.autoTrim(core.decks[i]) } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Sound") {
                    LabeledContent("Output", value: app.audio.routeName.isEmpty ? "—" : app.audio.routeName)
                    LabeledContent("Headphones", value: app.audio.outputChannels >= 4 ? "Controller's headphone jack (outputs 3/4)" : split ? "Split: master left, cue right" : "Master only (no cue)")
                    if !app.audio.lastError.isEmpty { Text("Audio: \(app.audio.lastError)").font(.caption).foregroundStyle(Theme.hot) }
                    if app.audio.outputChannels >= 4 || app.audio.routing != "auto" {
                        Picker("Routing", selection: Binding(get: { app.audio.routing }, set: { app.audio.setRouting($0) })) {
                            Text("Master 1/2, headphones 3/4 (FLX4)").tag("auto")
                            Text("Headphones 1/2, master 3/4").tag("swapped")
                            Text("Stereo only (master on 1/2)").tag("stereo")
                        }
                    }
                    HStack {
                        Text("Output")
                        Spacer()
                        Text(app.audio.outputName).foregroundStyle(Theme.muted).lineLimit(1)
                        RoutePicker().frame(width: 34, height: 30)
                    }
                    if app.audio.wireless {
                        Text("Bluetooth / AirPlay: about \(Int(app.audio.latency * 1000)) ms behind. The waveforms are shifted to match, SYNC still locks, but mixing by ear and scratching feel late, and there's no separate headphone cue.")
                            .font(.caption).foregroundStyle(Theme.cue)
                    } else {
                        Text("Delay to the speakers: \(Int(app.audio.latency * 1000)) ms (the waveforms are shifted to match)").font(.caption2).foregroundStyle(Theme.muted)
                    }
                    Button("Test master (three beeps on the speakers only)") { app.audio.engine.post(.testMaster) }
                    Button("Test cue (three beeps in the headphones only)") { app.audio.engine.post(.testCue) }
                    Button("Restart audio") { app.audio.restart() }
                    Text(app.audio.diagnostics).font(.caption2).foregroundStyle(Theme.muted).textSelection(.enabled)
                    if app.audio.outputChannels < 4 {
                        Toggle("Split (mono master left, mono cue right, with a splitter cable)", isOn: $split).onChange(of: split) { _, v in app.audio.setSplit(v) }
                    }
                    Toggle("Auto trim (every track at the same loudness)", isOn: $autoTrim)
                        .onChange(of: autoTrim) { _, v in if v { retrim() } }
                    if autoTrim {
                        Picker("Loudness", selection: $autoTrimTarget) {
                            ForEach(AutoTrim.targets, id: \.self) { t in Text("\(Int(t)) LUFS\(t == -9 ? " (club masters, default)" : t == -14 ? " (streaming level)" : "")").tag(t) }
                        }
                        .onChange(of: autoTrimTarget) { _, _ in retrim() }
                        Text("Sets each deck's TRIM when a track loads, measured from the track itself (ITU-R BS.1770 loudness). Turn TRIM by hand afterwards as usual. Boosts stop at +6 dB, and before the track's peaks would hit the limiter.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Section {
                    Button("Master EQ…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.eqShown = true } }
                    Button("Show the walkthrough") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.tourShown = true } }
                } footer: { Text("Master EQ: ten bands on the whole mix, \(core.mixer.eq.on ? "on" : "off") now. The walkthrough is the short tour offered the first time the app opens.") }
                Section("Look") {
                    Toggle("Phrases (Intro / Build / Drop… on the waveforms)", isOn: $phrases)
                    Picker("Waveform", selection: $waveStyle) { Text("RGB (red lows, green mids, blue highs)").tag("rgb"); Text("3-band").tag("3band") }
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        let always = PhoneScreen.autoCompactNow()
                        Toggle("Touch mode (big EQ and platters, for playing without a controller)", isOn: always ? .constant(true) : $compact).disabled(always)
                        Text(always ? "This screen always uses Touch mode: it's too small for the full layout, or has no Dynamic Island beside the strips." : "Each deck shows PLAY or PADS, the mixer is a big HI / MID / LOW per channel (tap to cut, tap again to centre), and WAVE, DECKS, FX, REC, TRIM and CFX move into the ⋯ menu.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Section {
                    Toggle("AI mode", isOn: $aiMode).onChange(of: aiMode) { _, _ in apple.kick() }
                    if aiMode {
                        LabeledContent("Ask the library ✨", value: SmartSearch.available ? "On (search box)" : "Needs Apple Intelligence")
                        if let why = AppleMusic.unavailableReason {
                            LabeledContent("Apple music analysis", value: "Off")
                            Text(why).font(.caption).foregroundStyle(Theme.muted)
                        } else {
                            LabeledContent("Apple music analysis", value: "\(apple.analysed) track\(apple.analysed == 1 ? "" : "s")" + (apple.failedCount > 0 ? ", \(apple.failedCount) failed" : ""))
                            if !apple.progress.isEmpty { Text(apple.progress).font(.caption).foregroundStyle(Theme.muted) }
                            Picker("Beat grids", selection: $appleGrid) {
                                Text("rekordbox, then Cratebox").tag(0)
                                Text("rekordbox, then Apple").tag(1)
                                Text("Apple, even over rekordbox").tag(2)
                            }
                            Text(appleGrid == 0 ? "Apple's analysis is only kept beside your grids." : appleGrid == 1 ? "Tracks without a rekordbox grid get Apple's beats and bar 1 when they're loaded. rekordbox's grids stay." : "Every track gets Apple's beats and bar 1 when it's loaded, rekordbox USB tracks too (nothing is written to the stick).")
                                .font(.caption).foregroundStyle(Theme.muted)
                            NavigationLink("Compare with the grids…") { AppleCompareView() }
                            Button("Analyse everything again", role: .destructive) { apple.clear() }
                        }
                    }
                } header: { Text("AI mode") } footer: {
                    Text("One switch for every AI feature, all on this device (nothing is uploaded). Ask the library turns a sentence into a search (Apple Intelligence, iOS 26+). Apple music analysis (iOS 27+) finds beats, bars, key, phrases, vocals and loudness in the background, only while nothing plays. It also sorts the library by MATCH (what would follow the playing track best) and marks MIX IN and MIX OUT on a loaded track's waveform. Beat grids chooses whose grid a track gets at its next load: a grid you fixed by hand always stays, a track Apple hasn't analysed yet or whose tempo wanders keeps the grid it has, and Apple's half-time counts are doubled to match. Keys and cues are never changed.")
                }
                Section("Recording") {
                    Picker("Format", selection: $recFmt) { Text("WAV (lossless, ~650 MB per hour)").tag("wav"); Text("AAC 256 kbps (~115 MB per hour)").tag("aac") }
                    Text("Recordings and their tracklists go to Files → On My iPhone/iPad → \(Recorder.filesName).").font(.caption).foregroundStyle(Theme.muted)
                }
                Section("Decks") {
                    Picker("Decks", selection: Binding(get: { core.deckCount }, set: { app.setDecks($0) })) {
                    Text("2 decks").tag(2); Text("3 decks (1 and 3 on the left)").tag(3); Text("4 decks").tag(4)
                }
                    Toggle("Load lock (a playing deck can't be loaded)", isOn: $core.loadLock)
                    Picker("BPM range (where half/double-time tracks land)", selection: $bpmRange) {
                        ForEach(["58-115", "68-135", "78-155", "88-175", "70-180"], id: \.self) { Text($0) }
                        Text("Custom").tag("custom")
                    }
                    if bpmRange == "custom" {
                        // the top end stays at least an octave above the bottom, so every tempo has a place
                        Stepper("From \(bpmLo) BPM", value: $bpmLo, in: 40...150)
                            .onChange(of: bpmLo) { _, lo in if bpmHi < 2 * lo - 1 { bpmHi = 2 * lo - 1 } }
                        Stepper("To \(bpmHi) BPM", value: $bpmHi, in: max(79, 2 * bpmLo - 1)...300)
                    }
                    Picker("Jog sensitivity", selection: Binding(get: { core.jogSens }, set: { core.jogSens = $0 })) { ForEach([0.5, 0.75, 1, 1.5, 2], id: \.self) { Text("\(String($0))×") } }
                    Picker("Backspin", selection: Binding(get: { core.spinSecs }, set: { core.spinSecs = $0 })) { ForEach([1.0, 1.5, 2.5, 4], id: \.self) { Text("\(String($0)) s") } }
                }
                Section {
                    Picker("Controller", selection: Binding(get: { app.midiHost.preferred.isEmpty ? app.controllerName : app.midiHost.preferred }, set: { app.midiHost.preferred = $0 })) {
                        if app.midiHost.available.isEmpty { Text("No MIDI devices").tag("") }
                        ForEach(app.midiHost.available, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Mapping", selection: Binding(get: { app.midi.profile?.id ?? "learn" }, set: { app.useProfile($0) })) {
                        ForEach(Profiles.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if let p = app.midi.profile { Text((Profiles.srcNote[p.src] ?? "") + (app.midi.mappedCount > 0 ? " You've mapped \(app.midi.mappedCount) control\(app.midi.mappedCount == 1 ? "" : "s") yourself." : "")).font(.caption).foregroundStyle(Theme.muted) }
                    NavigationLink("MIDI learn…") { LearnView() }
                    Button("Deck layers on SMART CFX / SMART FADER…") { dismiss(); app.midi.setupLayerButtons {} }
                    Button("Clear learned controls", role: .destructive) { app.midi.clearLearned() }
                } header: { Text("Controller") }
                Section {
                    Toggle("Editable (writes to the stick)", isOn: Binding(get: { devices.editable }, set: { v in if v { warn = true } else { devices.editable = false } }))
                } header: { Text("rekordbox USB playlists") } footer: { Text("Off: sticks are read-only. On: playlist changes are written into the stick's export.pdb.") }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .alert("Edit playlists on rekordbox USB sticks?", isPresented: $warn) {
                Button("Cancel", role: .cancel) {}
                Button("I understand, turn it on", role: .destructive) { devices.editable = true }
            } message: { Text("This is untested and may damage your USB's rekordbox library. Back up your stick first. Proceed at your own risk.") }
        }
    }
}

/// MIDI learn: pick a control, then move or press it on the controller
/// the system's output picker (Bluetooth speakers and headphones, AirPlay)
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(); v.tintColor = .white; v.activeTintColor = .systemOrange; v.prioritizesVideoDevices = false; return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

struct LearnView: View {
    @EnvironmentObject var app: AppModel
    @State private var hint = "Pick a control, then move or press it on the controller."
    let decked = ["play", "cue", "sync", "jog", "tempo", "fader", "trim", "hi", "mid", "low", "cfx", "pfl", "loopIn", "loopOut", "reloop", "keylock", "quant", "load", "jogSide"]
    let global = ["xfader", "headMix", "master", "masterCue", "browse", "browsePress", "fxOn", "fxSelect", "fxBeatDown", "fxBeatUp", "fxDepth"]
    var body: some View {
        Form {
            Section { Text(hint).font(.callout) }
            ForEach(0..<4, id: \.self) { d in
                Section("Deck \(d + 1)") {
                    ForEach(decked, id: \.self) { a in Button(LEARN_LABEL[a] ?? a) { app.midi.learnPick(action: a, deck: d) } }
                    ForEach(0..<8, id: \.self) { p in Button("Pad \(p + 1) (hot cue)") { app.midi.learnPick(action: "hot:\(p)", deck: d) } }
                }
            }
            Section("Mixer and FX") { ForEach(global, id: \.self) { a in Button(LEARN_LABEL[a] ?? a) { app.midi.learnPick(action: a, deck: -1) } } }
        }
        .navigationTitle("MIDI learn")
        .onAppear { app.midi.learnHint = { h in hint = h }; app.midi.startLearn() }
        .onDisappear { app.midi.stopLearn(); app.library.bpmRangeChanged() }
    }
}

struct RecButton: View {
    @EnvironmentObject var app: AppModel
    var body: some View { RecInner(rec: app.recorder) }
}
struct RecInner: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var rec: Recorder
    var body: some View {
        Button { rec.recording ? rec.stop(app.audio.engine) : rec.start(app.audio.engine) } label: {
            HStack(spacing: 4) {
                Circle().fill(rec.recording ? Theme.hot : Theme.dim).frame(width: 8, height: 8)
                Text(rec.recording ? String(format: "%d:%02d", Int(rec.seconds) / 60, Int(rec.seconds) % 60) : "REC").font(.system(size: 11, weight: .bold, design: .monospaced))
            }.padding(.horizontal, 8).frame(height: 26).background(Capsule().fill(Theme.raise))
        }.buttonStyle(.plain)
    }
}

/// Settings → AI mode → Compare: Apple's beats and bars against the grid each track already has (Cratebox's own,
/// rekordbox's, or one fixed by hand), so the two can be judged on real tracks. Nothing here changes a grid.
struct AppleCompareView: View {
    @ObservedObject var apple = AppleMusic.shared
    @State private var rows: [AppleMusic.Row] = []
    @State private var saved = ""
    var body: some View {
        List {
            Section {
                let tempo = rows.filter { $0.cmp.sameTempo }.count
                let half = rows.filter { $0.cmp.comparable && !$0.cmp.sameTempo }.count
                let beats = rows.filter { $0.cmp.comparable && abs($0.cmp.beatOffset ?? 1) < 0.125 }.count
                let bars = rows.filter { $0.cmp.agrees }.count
                Text("\(rows.count) tracks · same tempo \(tempo) · half or double \(half) · beats within ⅛ beat \(beats) · same bar 1 \(bars)")
                Button("Save as CSV (Files → Cratebox Suite)") {
                    saved = apple.exportCSV().map { "Saved \($0.lastPathComponent)" } ?? "Couldn't save"
                }
                if !saved.isEmpty { Text(saved).font(.caption).foregroundStyle(Theme.muted) }
            } footer: { Text("Bar 1 shift: which beat of our bar Apple's bars start on (0 = the same). Tempo ×2 or ×½ means one of the two counted double or half time.") }
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(line(r)).font(.system(size: 11, design: .monospaced)).foregroundStyle(r.cmp.agrees ? Theme.ok : Theme.muted)
                }
            }
        }
        .navigationTitle("Apple vs grids")
        .onAppear { rows = apple.rows() }
    }
    func line(_ r: AppleMusic.Row) -> String {
        var s = "\(r.source) \(r.bpm.map { String(format: "%.1f", $0) } ?? "–") · Apple \(r.appleBpm.map { String(format: "%.1f", $0) } ?? "–")"
        if let t = r.cmp.tempoRatio, !r.cmp.sameTempo { s += String(format: " (×%.2f)", t) }
        if let ms = r.cmp.beatOffsetMs { s += String(format: " · beats %+.0f ms", ms) }
        if let b = r.cmp.barShift { s += " · bar 1 \(b == 0 ? "same" : "+\(b)")" }
        let k = Keys.camelot(r.key)?.label ?? "–", ak = Keys.camelot(r.appleKey)?.label ?? "–"
        s += " · key \(k)/\(ak)"
        if let v = r.vocals { s += String(format: " · vocals %.0f%%", v * 100) }
        if let l = r.lufs { s += String(format: " · %.1f LUFS", l) }
        return s
    }
}
