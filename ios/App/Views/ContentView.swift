import SwiftUI
import AVKit
import CrateboxKit

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @State private var settings = CommandLine.arguments.contains("-settings")   // CI screenshots of Settings

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
