import SwiftUI
import CrateboxKit

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @State private var settings = false

    var body: some View {
        GeometryReader { g in
            let phone = g.size.height < 600
            VStack(spacing: 6) {
                topBar(phone)
                if phone {
                    if app.tab == 0 { mix(compact: true) } else { LibraryPane() }
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

    func mix(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 6) { DeckView(deck: core.decks[0], compact: compact || core.four); if core.four { DeckView(deck: core.decks[2], compact: true) } }
            MixerView(compact: compact || core.four)
            VStack(spacing: 6) { DeckView(deck: core.decks[1], compact: compact || core.four); if core.four { DeckView(deck: core.decks[3], compact: true) } }
        }
    }

    func topBar(_ phone: Bool) -> some View {
        HStack(spacing: 8) {
            Text("CRATEBOX").font(.system(size: 15, weight: .heavy)).tracking(3)
            HStack(spacing: 4) {
                Circle().fill(app.controllerName.isEmpty ? Theme.dim : Theme.ok).frame(width: 7, height: 7)
                Text(app.controllerName.isEmpty ? "No controller" : app.controllerName).font(.system(size: 11)).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.raise))
            Text(app.audio.outputChannels >= 4 ? "4 ch · cue on 3/4" : "2 ch").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            if phone {
                Picker("", selection: $app.tab) { Text("MIX").tag(0); Text("LIBRARY").tag(1) }.pickerStyle(.segmented).frame(width: 170)
            }
            Text(app.statusText).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var warn = false
    @State private var learning = false
    @State private var hint = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Sound") {
                    LabeledContent("Output", value: app.audio.routeName.isEmpty ? "—" : app.audio.routeName)
                    LabeledContent("Headphones", value: app.audio.outputChannels >= 4 ? "Controller's headphone jack (outputs 3/4)" : split ? "Split: master left, cue right" : "Master only (no cue)")
                    if app.audio.outputChannels < 4 {
                        Toggle("Split (mono master left, mono cue right, with a splitter cable)", isOn: $split).onChange(of: split) { _, v in app.audio.setSplit(v) }
                    }
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
