import SwiftUI
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
                .sheet(item: Binding(get: { app.gridDeck.map { GridTarget(id: $0) } }, set: { app.gridDeck = $0?.id })) { t in GridEditor(deck: core.decks[t.id]) }
        } else { pad }
    }
    var pad: some View {
        GeometryReader { g in
            let phone = false
            VStack(spacing: 6) {
                topBar(phone)
                if phone {
                    if app.tab == 0 {
                        phoneMix.overlay { if app.browserShown { BrowserOverlay().transition(.opacity) } }
                    } else { LibraryPane() }
                } else {
                    mix(compact: g.size.height < 900)
                    LibraryPane().frame(minHeight: 180)
                }
            }
            .padding(6)
            .background(Theme.bg)
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(item: Binding(get: { app.gridDeck.map { GridTarget(id: $0) } }, set: { app.gridDeck = $0?.id })) { t in GridEditor(deck: core.decks[t.id]) }
    }
    struct GridTarget: Identifiable { let id: Int }

    /// iPhone: the waveforms across the top (all four in 4-deck mode), then the two decks the controller
    /// plays around a small mixer
    var phoneMix: some View {
        let l = core.four ? app.midi.side[0] : 0, r = core.four ? app.midi.side[1] : 1
        return VStack(spacing: 4) {
            VStack(spacing: 3) {
                PhoneLane(deck: core.decks[l]); PhoneLane(deck: core.decks[r])
                if core.four {
                    // the two decks the controller isn't on, side by side in one thin row (tap a number to switch)
                    HStack(spacing: 4) { ForEach([0, 1, 2, 3].filter { $0 != l && $0 != r }, id: \.self) { i in PhoneLane(deck: core.decks[i], active: false) } }
                }
            }.frame(minHeight: 70, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 4) {
                DeckView(deck: core.decks[l], phone: true).id(l)
                MixerView(phone: true)
                DeckView(deck: core.decks[r], phone: true).id(r)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder func mix(compact: Bool) -> some View {
        if core.four {
            // 4 decks on an iPad: all four waveforms across the top, the decks' controls in two columns
            VStack(spacing: 6) {
                VStack(spacing: 3) { ForEach(0..<4, id: \.self) { i in PhoneLane(deck: core.decks[i]).frame(height: compact ? 54 : 70) } }
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 6) { DeckView(deck: core.decks[0], phone: true, chips: false); DeckView(deck: core.decks[2], phone: true, chips: false) }
                    MixerView(compact: true)
                    VStack(spacing: 6) { DeckView(deck: core.decks[1], phone: true, chips: false); DeckView(deck: core.decks[3], phone: true, chips: false) }
                }
            }
        } else { mix2(compact: compact) }
    }
    func mix2(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 6) { DeckView(deck: core.decks[0], compact: compact || core.four); if core.four { DeckView(deck: core.decks[2], compact: true) } }
            MixerView(compact: compact || core.four)
            VStack(spacing: 6) { DeckView(deck: core.decks[1], compact: compact || core.four); if core.four { DeckView(deck: core.decks[3], compact: true) } }
        }
    }

    func topBar(_ phone: Bool) -> some View {
        HStack(spacing: 8) {
            if !phone { Text("CRATEBOX").font(.system(size: 15, weight: .heavy)).tracking(3) }
            HStack(spacing: 4) {
                Circle().fill(app.controllerName.isEmpty ? Theme.dim : Theme.ok).frame(width: 7, height: 7)
                Text(app.controllerName.isEmpty ? "No controller" : app.controllerName).font(.system(size: 11)).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.raise))
            if !phone { Text(app.audio.outputChannels >= 4 ? "4 ch · cue on 3/4" : "2 ch").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted) }
            if phone {
                Picker("", selection: $app.tab) { Text("MIX").tag(0); Text("LIBRARY").tag(1) }.pickerStyle(.segmented).frame(width: 150)
                MixerView(masterBar: true)
            }
            Text(app.statusText).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            RecButton()
            LitButton(label: "4 DECKS", on: core.four, color: Theme.fg) { core.setFour(!core.four); if !core.four { app.midi.resetSides() } }
            Button { settings = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
        }.padding(.horizontal, 4)
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
    @AppStorage("cb.split") var split = false
    @AppStorage("cb.recFmt") var recFmt = "wav"
    @AppStorage("cb.phrases") var phrases = true
    @AppStorage("cb.wave") var waveStyle = "rgb"
    @State private var warn = false
    @State private var learning = false
    @State private var hint = ""

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
                    Button("Test master (three beeps on the speakers only)") { app.audio.engine.post(.testMaster) }
                    Button("Test cue (three beeps in the headphones only)") { app.audio.engine.post(.testCue) }
                    Button("Restart audio") { app.audio.restart() }
                    Text(app.audio.diagnostics).font(.caption2).foregroundStyle(Theme.muted).textSelection(.enabled)
                    if app.audio.outputChannels < 4 {
                        Toggle("Split (mono master left, mono cue right, with a splitter cable)", isOn: $split).onChange(of: split) { _, v in app.audio.setSplit(v) }
                    }
                }
                Section("Look") {
                    Toggle("Phrases (Intro / Build / Drop… on the waveforms)", isOn: $phrases)
                    Picker("Waveform", selection: $waveStyle) { Text("RGB (red lows, green mids, blue highs)").tag("rgb"); Text("3-band").tag("3band") }
                }
                Section("Recording") {
                    Picker("Format", selection: $recFmt) { Text("WAV (lossless, ~650 MB per hour)").tag("wav"); Text("AAC 256 kbps (~115 MB per hour)").tag("aac") }
                    Text("Recordings and their tracklists go to Files → On My iPhone/iPad → Cratebox.").font(.caption).foregroundStyle(Theme.muted)
                }
                Section("Decks") {
                    Toggle("4 decks", isOn: Binding(get: { core.four }, set: { core.setFour($0); if !$0 { app.midi.resetSides() } }))
                    Toggle("Load lock (a playing deck can't be loaded)", isOn: $core.loadLock)
                    Picker("BPM range (where half/double-time tracks land)", selection: $bpmRange) { ForEach(["58-115", "68-135", "78-155", "88-175"], id: \.self) { Text($0) } }
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
        .onDisappear { app.midi.stopLearn() }
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
