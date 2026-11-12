import SwiftUI
import CrateboxKit

/// Settings, in tabs: a strip of icon tabs across the top (with Done), one short page per tab underneath. Was one long
/// page. The strip fits the smallest screen the app gets, an iPhone SE at Display Zoom (568 × 320 pt, docs/device-sizes.md):
/// seven 44 pt tall tabs and Done in one row, the page gets the rest. Narrower than that, the strip scrolls sideways.
/// Same grouping idea as the Linux app's SETTINGS_TABS. The open tab is remembered (`cb.settingsTab`, also a CI launch
/// argument: `-settings -cb.settingsTab ai` opens Settings on AI mode).
enum SettingsTab: String, CaseIterable, Identifiable {
    case sound, decks, controller, look, recording, usb, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sound: return "Sound"
        case .decks: return "Decks"
        case .controller: return "Controller"
        case .look: return "Look"
        case .recording: return "Recording"
        case .usb: return "USB"
        case .ai: return "AI mode"
        }
    }
    /// SF Symbols that all exist on iOS 17, the app's minimum
    var icon: String {
        switch self {
        case .sound: return "speaker.wave.2.fill"
        case .decks: return "opticaldisc"
        case .controller: return "slider.horizontal.3"
        case .look: return "paintpalette"
        case .recording: return "record.circle"
        case .usb: return "externaldrive"
        case .ai: return "sparkles"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var devices: Devices
    @Environment(\.dismiss) var dismiss
    @AppStorage("cb.settingsTab") var tabRaw = SettingsTab.sound.rawValue
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

    var tab: SettingsTab { SettingsTab(rawValue: tabRaw) ?? .sound }

    /// auto trim turned on or its loudness changed: the loaded decks too (a playing one glides)
    func retrim() { for i in core.activeDecks where core.decks[i].loaded { app.autoTrim(core.decks[i]) } }

    var body: some View {
        let t = tab       // read here, in body, not only inside a closure (Xcode 27 redraws, AGENTS.md)
        NavigationStack {
            VStack(spacing: 0) {
                tabStrip(t)
                Divider()
                Form { page(t) }
                    .id(t)        // each tab opens at its top
            }
            .toolbar(.hidden, for: .navigationBar)      // the strip is the header; MIDI learn and Compare still get a back bar
            .alert("Edit playlists on rekordbox USB sticks?", isPresented: $warn) {
                Button("Cancel", role: .cancel) {}
                Button("I understand, turn it on", role: .destructive) { devices.editable = true }
            } message: { Text("This is untested and may damage your USB's rekordbox library. Back up your stick first. Proceed at your own risk.") }
        }
        // CI only: `-screen 568x320` frames the app at a Display Zoom size the simulator can't switch to; the sheet
        // takes that size too, so the screenshot shows what an SE at Display Zoom gets
        .frame(maxWidth: ScreenOverride.size?.width, maxHeight: ScreenOverride.size?.height)
    }

    // MARK: tab strip

    func tabStrip(_ current: SettingsTab) -> some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                tabs(current)
                ScrollView(.horizontal, showsIndicators: false) { tabs(current) }
            }
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
                .frame(minWidth: 52, minHeight: 44)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    func tabs(_ current: SettingsTab) -> some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { k in
                let on = k == current
                Button { tabRaw = k.rawValue } label: {
                    VStack(spacing: 2) {
                        Image(systemName: k.icon).font(.system(size: 16, weight: .medium)).frame(height: 20)
                        Text(k.title).font(.system(size: 10, weight: on ? .bold : .regular)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.muted)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: 44)          // Apple's 44 pt minimum tap target
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.raise : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: pages

    @ViewBuilder func page(_ t: SettingsTab) -> some View {
        switch t {
        case .sound: sound
        case .decks: decks
        case .controller: controller
        case .look: look
        case .recording: recording
        case .usb: usb
        case .ai: ai
        }
    }

    @ViewBuilder var sound: some View {
        Section("Output") {
            HStack {
                Text("Output")
                Spacer()
                Text(app.audio.outputName).foregroundStyle(Theme.muted).lineLimit(1)
                RoutePicker().frame(width: 34, height: 30)
            }
            LabeledContent("Route", value: app.audio.routeName.isEmpty ? "—" : app.audio.routeName)
            LabeledContent("Headphones", value: app.audio.outputChannels >= 4 ? "Controller's headphone jack (outputs 3/4)" : split ? "Split: master left, cue right" : "Master only (no cue)")
            if !app.audio.lastError.isEmpty { Text("Audio: \(app.audio.lastError)").font(.caption).foregroundStyle(Theme.hot) }
            if app.audio.outputChannels >= 4 || app.audio.routing != "auto" {
                Picker("Routing", selection: Binding(get: { app.audio.routing }, set: { app.audio.setRouting($0) })) {
                    Text("Master 1/2, headphones 3/4 (FLX4)").tag("auto")
                    Text("Headphones 1/2, master 3/4").tag("swapped")
                    Text("Stereo only (master on 1/2)").tag("stereo")
                }
            }
            if app.audio.outputChannels < 4 {
                Toggle("Split (mono master left, mono cue right, with a splitter cable)", isOn: $split).onChange(of: split) { _, v in app.audio.setSplit(v) }
            }
            if app.audio.wireless {
                Text("Bluetooth / AirPlay: about \(Int(app.audio.latency * 1000)) ms behind. The waveforms are shifted to match, SYNC still locks, but mixing by ear and scratching feel late, and there's no separate headphone cue.")
                    .font(.caption).foregroundStyle(Theme.cue)
            } else {
                Text("Delay to the speakers: \(Int(app.audio.latency * 1000)) ms (the waveforms are shifted to match)").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        // the loudness of the tracks themselves: auto trim (AI DJ uses the same switch), and the master EQ
        Section {
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
            Button("Master EQ…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.eqShown = true } }
        } header: { Text("Level and EQ") } footer: { Text("Master EQ: ten bands on the whole mix, \(core.mixer.eq.on ? "on" : "off") now.") }
        Section("Check") {
            Button("Test master (three beeps on the speakers only)") { app.audio.engine.post(.testMaster) }
            Button("Test cue (three beeps in the headphones only)") { app.audio.engine.post(.testCue) }
            Button("Restart audio") { app.audio.restart() }
            Text(app.audio.diagnostics).font(.caption2).foregroundStyle(Theme.muted).textSelection(.enabled)
        }
    }

    @ViewBuilder var decks: some View {
        Section {
            Picker("Decks", selection: Binding(get: { core.deckCount }, set: { app.setDecks($0) })) {
                Text("2 decks").tag(2); Text("3 decks (1 and 3 on the left)").tag(3); Text("4 decks").tag(4)
            }
            Toggle("Load lock (a playing deck can't be loaded)", isOn: $core.loadLock)
        }
        Section("Tempo") {
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
        }
        Section("Platters") {
            Picker("Jog sensitivity", selection: Binding(get: { core.jogSens }, set: { core.jogSens = $0 })) { ForEach([0.5, 0.75, 1, 1.5, 2], id: \.self) { Text("\(String($0))×") } }
            Picker("Backspin", selection: Binding(get: { core.spinSecs }, set: { core.spinSecs = $0 })) { ForEach([1.0, 1.5, 2.5, 4], id: \.self) { Text("\(String($0)) s") } }
        }
    }

    @ViewBuilder var controller: some View {
        Section {
            Picker("Controller", selection: Binding(get: { app.midiHost.preferred.isEmpty ? app.controllerName : app.midiHost.preferred }, set: { app.midiHost.preferred = $0 })) {
                if app.midiHost.available.isEmpty { Text("No MIDI devices").tag("") }
                ForEach(app.midiHost.available, id: \.self) { Text($0).tag($0) }
            }
            Picker("Mapping", selection: Binding(get: { app.midi.profile?.id ?? "learn" }, set: { app.useProfile($0) })) {
                ForEach(Profiles.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            if let p = app.midi.profile { Text((Profiles.srcNote[p.src] ?? "") + (app.midi.mappedCount > 0 ? " You've mapped \(app.midi.mappedCount) control\(app.midi.mappedCount == 1 ? "" : "s") yourself." : "")).font(.caption).foregroundStyle(Theme.muted) }
        }
        Section("Mapping your own") {
            NavigationLink("MIDI learn…") { LearnView() }
            Button("Deck layers on SMART CFX / SMART FADER…") { dismiss(); app.midi.setupLayerButtons {} }
            Button("Clear learned controls", role: .destructive) { app.midi.clearLearned() }
        }
    }

    @ViewBuilder var look: some View {
        Section("Waveforms") {
            Picker("Waveform", selection: $waveStyle) { Text("RGB (red lows, green mids, blue highs)").tag("rgb"); Text("3-band").tag("3band") }
            Toggle("Phrases (Intro / Build / Drop… on the waveforms)", isOn: $phrases)
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            Section("Layout") {
                let always = PhoneScreen.autoCompactNow()
                Toggle("Touch mode (big EQ and platters, for playing without a controller)", isOn: always ? .constant(true) : $compact).disabled(always)
                Text(always ? "This screen always uses Touch mode: it's too small for the full layout, or has no Dynamic Island beside the strips." : "Each deck shows PLAY or PADS, the mixer is a big HI / MID / LOW per channel (tap to cut, tap again to centre), and WAVE, DECKS, FX, REC, TRIM and CFX move into the ⋯ menu.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        Section {
            Button("Show the walkthrough") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.tourShown = true } }
        } footer: { Text("The short tour offered the first time the app opens.") }
    }

    @ViewBuilder var recording: some View {
        Section {
            Picker("Format", selection: $recFmt) { Text("WAV (lossless, ~650 MB per hour)").tag("wav"); Text("AAC 256 kbps (~115 MB per hour)").tag("aac") }
        } footer: { Text("REC records the master. Recordings and their tracklists go to Files → On My iPhone/iPad → \(Recorder.filesName).") }
    }

    @ViewBuilder var usb: some View {
        Section {
            Toggle("Editable (writes to the stick)", isOn: Binding(get: { devices.editable }, set: { v in if v { warn = true } else { devices.editable = false } }))
        } header: { Text("rekordbox USB playlists") } footer: { Text("Off: sticks are read-only. On: playlist changes are written into the stick's export.pdb.") }
    }

    @ViewBuilder var ai: some View {
        Section {
            Toggle("AI mode", isOn: $aiMode).onChange(of: aiMode) { _, _ in apple.kick() }
        } footer: {
            Text("One switch for every AI feature, all on this device (nothing is uploaded).")
        }
        if aiMode {
            Section {
                LabeledContent("Ask the library ✨", value: SmartSearch.available ? "On (search box)" : "Needs Apple Intelligence")
            } footer: { Text("Turns a sentence into a search (Apple Intelligence, iOS 26+).") }
            Section {
                if let why = AppleMusic.unavailableReason {
                    LabeledContent("Apple music analysis", value: "Off")
                    Text(why).font(.caption).foregroundStyle(Theme.muted)
                } else {
                    LabeledContent("Apple music analysis", value: "\(apple.analysed) track\(apple.analysed == 1 ? "" : "s")" + (apple.failedCount > 0 ? ", \(apple.failedCount) failed" : ""))
                    if !apple.progress.isEmpty { Text(apple.progress).font(.caption).foregroundStyle(Theme.muted) }
                }
            } header: { Text("Apple music analysis") } footer: {
                Text("iOS 27+. Finds beats, bars, key, phrases, vocals and loudness in the background, only while nothing plays. It also sorts the library by MATCH (what would follow the playing track best) and marks MIX IN and MIX OUT on a loaded track's waveform.")
            }
            if AppleMusic.unavailableReason == nil {
                Section {
                    Picker("Beat grids", selection: $appleGrid) {
                        Text("rekordbox, then Cratebox").tag(0)
                        Text("rekordbox, then Apple").tag(1)
                        Text("Apple, even over rekordbox").tag(2)
                    }
                    Text(appleGrid == 0 ? "Apple's analysis is only kept beside your grids." : appleGrid == 1 ? "Tracks without a rekordbox grid get Apple's beats and bar 1 when they're loaded. rekordbox's grids stay." : "Every track gets Apple's beats and bar 1 when it's loaded, rekordbox USB tracks too (nothing is written to the stick).")
                        .font(.caption).foregroundStyle(Theme.muted)
                    NavigationLink("Compare with the grids…") { AppleCompareView() }
                    Button("Analyse everything again", role: .destructive) { apple.clear() }
                } header: { Text("Beat grids") } footer: {
                    Text("Chooses whose grid a track gets at its next load. A grid you fixed by hand always stays, a track Apple hasn't analysed yet or whose tempo wanders keeps the grid it has, and Apple's half-time counts are doubled to match. Keys and cues are never changed.")
                }
            }
        }
    }
}
