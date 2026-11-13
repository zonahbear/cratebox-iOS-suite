import SwiftUI
import CrateboxKit

/// Settings, in tabs: a rail of icon tabs down the left edge, filling it top to bottom, and one short page per tab beside
/// it under a title bar with Done. Sized for the smallest screen the app gets, an iPhone SE at Display Zoom (568 × 320 pt,
/// safe area 0 / 0 / 0, docs/device-sizes.md): six tabs share the 320 pt height, 53.3 pt each, above Apple's 44 pt
/// minimum. Shorter than 6 × 44 pt (no listed device is), the rail scrolls. Six since 2026-11-12 (Jonah): Sound and
/// Recording became Audio, USB became Library & USB (with the grid order), AI got AI DJ's moves. The open tab is
/// remembered (`cb.settingsTab`, also a CI launch argument: `-settings -cb.settingsTab ai` opens Settings on AI).
enum SettingsTab: String, CaseIterable, Identifiable {
    case audio, decks, controller, look, library, ai
    var id: String { rawValue }
    /// a stored tab from before the six (sound, recording, usb) opens where its settings went
    init(stored: String) {
        switch stored {
        case "sound", "recording": self = .audio
        case "usb": self = .library
        default: self = SettingsTab(rawValue: stored) ?? .audio
        }
    }
    var title: String {
        switch self {
        case .audio: return "Audio"
        case .decks: return "Decks"
        case .controller: return "Controller"
        case .look: return "Look"
        case .library: return "Library & USB"
        case .ai: return "AI"
        }
    }
    /// the rail's shorter label
    var short: String { self == .library ? "Library" : title }
    /// SF Symbols that all exist on iOS 17, the app's minimum
    var icon: String {
        switch self {
        case .audio: return "speaker.wave.2.fill"
        case .decks: return "opticaldisc"
        case .controller: return "slider.horizontal.3"
        case .look: return "paintpalette"
        case .library: return "externaldrive"
        case .ai: return "sparkles"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var devices: Devices
    @EnvironmentObject var playlists: Playlists
    @Environment(\.dismiss) var dismiss
    @AppStorage("cb.settingsTab") var tabRaw = SettingsTab.audio.rawValue
    @AppStorage("cb.bpmRange") var bpmRange = "88-175"
    @AppStorage("cb.bpmLo") var bpmLo = 70
    @AppStorage("cb.bpmHi") var bpmHi = 180
    @AppStorage("cb.split") var split = false
    @AppStorage("cb.recFmt") var recFmt = "wav"
    @AppStorage("cb.phrases") var phrases = true
    @AppStorage("cb.wave") var waveStyle = "rgb"
    @AppStorage("cb.compact") var compact = false
    @AppStorage(AIMode.key) var aiMode = false
    @AppStorage(Haptics.key) var haptics = true
    @AppStorage(AutoTrim.key) var autoTrim = false
    @AppStorage(AutoTrim.targetKey) var autoTrimTarget = -9.0
    @AppStorage(AppleGridMode.key) var gridOrder = 0
    @AppStorage(AppleMusic.whilePlayingKey) var analyseWhilePlaying = false
    @ObservedObject var apple = AppleMusic.shared
    @State private var warn = false
    @State private var confirmClear = false
    @State private var reporting = false
    @ObservedObject var usbCopy = UsbCopy.shared

    var tab: SettingsTab { SettingsTab(stored: tabRaw) }

    /// auto trim turned on or its loudness changed: the loaded decks too (a playing one glides)
    func retrim() { for i in core.activeDecks where core.decks[i].loaded { app.autoTrim(core.decks[i]) } }

    var body: some View {
        let t = tab       // read here, in body, not only inside a closure (Xcode 27 redraws, AGENTS.md)
        NavigationStack {
            HStack(spacing: 0) {
                tabRail(t)
                Divider()
                VStack(spacing: 0) {
                    titleBar(t)
                    Divider()
                    Form { page(t) }
                        .id(t)        // each tab opens at its top
                }
            }
            .toolbar(.hidden, for: .navigationBar)      // the rail and title bar are the header; MIDI learn and Compare still get a back bar
            .sheet(isPresented: $reporting) { ReportView() }
            .alert("Edit playlists on rekordbox USB sticks?", isPresented: $warn) {
                Button("Cancel", role: .cancel) {}
                Button("I understand, turn it on", role: .destructive) { devices.editable = true }
            } message: { Text("This is untested and may damage your USB's rekordbox library. Back up your stick first. Proceed at your own risk.") }
        }
        // CI only: `-screen 568x320` frames the app at a Display Zoom size the simulator can't switch to; the sheet
        // takes that size too, so the screenshot shows what an SE at Display Zoom gets
        .frame(maxWidth: ScreenOverride.size?.width, maxHeight: ScreenOverride.size?.height)
    }

    // MARK: tab rail

    /// the tabs down the left edge, each an equal share of the height (never under 44 pt)
    func tabRail(_ current: SettingsTab) -> some View {
        GeometryReader { g in
            let n = CGFloat(SettingsTab.allCases.count)
            let h = max(44, g.size.height / n)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(SettingsTab.allCases) { k in tabButton(k, on: k == current).frame(height: h) }
                }
            }
            .scrollDisabled(h * n <= g.size.height + 0.5)
        }
        .frame(width: 88)
    }

    func tabButton(_ k: SettingsTab, on: Bool) -> some View {
        Button { if tabRaw != k.rawValue { Haptics.step() }; tabRaw = k.rawValue } label: {
            VStack(spacing: 3) {
                Image(systemName: k.icon).font(.system(size: 20, weight: .medium)).frame(height: 24)
                Text(k.short).font(.system(size: 11, weight: on ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Theme.accent : Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.raise : Color.clear).padding(3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(k.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// the open tab's name and Done, over its page
    func titleBar(_ current: SettingsTab) -> some View {
        HStack(spacing: 4) {
            Text(current.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
            Spacer(minLength: 0)
            Button { reporting = true } label: { Image(systemName: "ladybug").font(.system(size: 17)) }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Report a problem (send this session to GitHub)")
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
                .frame(minWidth: 52, minHeight: 44)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
    }

    // MARK: pages

    @ViewBuilder func page(_ t: SettingsTab) -> some View {
        switch t {
        case .audio:
            sound
            recording
        case .decks: decks
        case .controller: controller
        case .look: look
        case .library:
            grids
            AnalysisProblems(library: app.library)
            usb
            if let d = CrashLog.latest {
                Section("Crash reports") {
                    Text("Cratebox crashed \(d.formatted(date: .abbreviated, time: .shortened)). The report is in Files → On My iPhone → Cratebox → Crash reports: send it along with what you were doing.")
                        .font(.caption)
                }
            }
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
            Toggle("Haptics", isOn: $haptics)
        } footer: { Text("A light tap under your finger for buttons, and a click when a knob or the crossfader passes its centre. Only for your touches: a controller or AI DJ moving the same control stays silent.") }
        Section {
            Button("Show the walkthrough") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.tourShown = true } }
        } footer: { Text("The short tour offered the first time the app opens.") }
    }

    @ViewBuilder var recording: some View {
        Section {
            Picker("Format", selection: $recFmt) { Text("WAV (lossless, ~650 MB per hour)").tag("wav"); Text("AAC 256 kbps (~115 MB per hour)").tag("aac") }
        } header: { Text("Recording") } footer: { Text("REC records the master. Recordings and their tracklists go to Files → On My iPhone/iPad → \(Recorder.filesName).") }
    }

    @ViewBuilder var usb: some View {
        Section {
            if devices.list.isEmpty {
                Text("Plug in a rekordbox USB and open it (Library → DEVICES → + USB) to copy its tracks here.").font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(devices.list) { d in
                let missing = usbCopy.busy == nil ? UsbCopy.shared.missing(d, in: app.library).count : 0
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name)
                        Text(usbCopy.busy != nil ? "…" : missing == 0 ? "Everything's on this device" : "\(missing) track\(missing == 1 ? "" : "s") not on this device yet")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Sync") { UsbCopy.shared.sync(d, app: app) }.buttonStyle(.borderedProminent).disabled(usbCopy.busy != nil)
                }
                Button("Re-sync grids from \(d.name)") { UsbCopy.shared.regrid(d, app: app) }.disabled(usbCopy.busy != nil)
            }
            if !usbCopy.progress.isEmpty {
                HStack { Text(usbCopy.progress).font(.caption); Spacer(); Button("Stop") { UsbCopy.shared.cancel() } }
            } else if !usbCopy.result.isEmpty {
                Text(usbCopy.result).font(.caption).foregroundStyle(Theme.muted)        // what Sync / Re-sync just did
            }
        } header: { Text("Copy to this device") } footer: {
            Text("Sync copies the stick's tracks that aren't here yet, with rekordbox's grid and key, so they play without the stick, and makes the stick's rekordbox playlists in your playlists (in a folder named after the stick). A track already in your library (same file name and size) is never copied twice. Nothing is deleted, here or on the stick. Re-sync grids puts rekordbox's grid, key and phrases back on every track here that's also on the stick (same file name and size), except grids you fixed yourself. To copy one playlist or a few tracks: long-press it in the library, or open it and press Copy.")
        }
        Section {
            Toggle("Editable (writes to the stick)", isOn: Binding(get: { devices.editable }, set: { v in if v { warn = true } else { devices.editable = false } }))
        } header: { Text("rekordbox USB playlists") } footer: { Text("Off: sticks are read-only. On: playlist changes are written into the stick's export.pdb.") }
    }

    /// whose grid a track plays on (Jonah, 2026-11-12): one you set here, then Apple's (AI mode on a device that has
    /// it), then rekordbox's, then Cratebox's own analysis
    @ViewBuilder var grids: some View {
        Section {
            Picker("Order", selection: $gridOrder) {
                Text("Yours, Apple, rekordbox, Cratebox").tag(0)
                Text("Yours, rekordbox, Apple, Cratebox").tag(1)
                Text("Yours, rekordbox, Cratebox (no Apple)").tag(2)
            }
            Text(AppleMusic.unavailableReason.map { "Apple's grids: \($0)" } ?? (!aiMode ? "Apple's grids need AI mode (Settings → AI); until then it's rekordbox, then Cratebox." :
                 gridOrder == 0 ? "Every track gets Apple's beats and bar 1 when it's loaded, rekordbox USB tracks too (nothing is written to the stick). Tracks Apple hasn't analysed keep rekordbox's, else Cratebox's." :
                 gridOrder == 1 ? "rekordbox's grids stay; tracks without one get Apple's, else Cratebox's." : "Apple's analysis is only kept beside your grids."))
                .font(.caption).foregroundStyle(Theme.muted)
            if aiMode && AppleMusic.unavailableReason == nil {
                NavigationLink("Compare with the grids…") { AppleCompareView() }
                Button("Analyse everything again", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Throw away Apple's analysis of all \(apple.analysed) tracks?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Delete and analyse again", role: .destructive) { apple.clear() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("There's no copy: every track on this device is analysed again from scratch, only while nothing plays. Your grids, rekordbox's and Cratebox's aren't touched.") }
            }
        } header: { Text("Beat grids") } footer: {
            Text("Used from a track's next load, for playing and for AI DJ's mix points. A grid you fix here (TAP · GRID) always wins; so does a CUE you set, as AI DJ's mix-in point. rekordbox doesn't say which of its grids were fixed by hand, so they count as rekordbox's: nudge one here once to make it yours. Apple's half-time counts are doubled to match.")
        }
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
                    if !aiMode { Text("Turn on AI mode above to analyse.").font(.caption).foregroundStyle(Theme.muted) }
                    Toggle("Analyse while tracks play", isOn: Binding(get: { analyseWhilePlaying }, set: { analyseWhilePlaying = $0; apple.kick() }))
                    Button("Analyse the whole library on this device") { apple.request(app.library.tracks.filter { $0.device == nil }) }.disabled(!aiMode)
                    ForEach(devices.list) { d in
                        Button("Analyse the USB \(d.name)") { apple.request(Array(d.byRbId.values)) }.disabled(!aiMode)
                    }
                    if devices.list.isEmpty { Text("Analyse USB: plug in and open a rekordbox USB first").font(.caption).foregroundStyle(Theme.muted) }
                    Menu("Analyse a playlist") {
                        ForEach(playlists.lists.filter { !$0.folder }) { p in
                            Button("\(playlists.path(p)) (\(p.items.count))") { apple.request(p.items.compactMap { app.library.track($0) }) }
                        }
                    }.disabled(!aiMode || playlists.lists.allSatisfy { $0.folder })
                    Button("Analyse the selected track") { if let id = app.selection, let t = app.library.track(id) { apple.request([t]) } }
                        .disabled(!aiMode || app.selection.flatMap { app.library.track($0) } == nil)
                    if apple.waiting > 0 {
                        HStack {
                            Text("\(apple.waiting) waiting").font(.caption).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Stop", role: .destructive) { apple.cancelRequests() }
                        }
                    }
                    if apple.failedCount > 0 {
                        DisclosureGroup("Why \(apple.failedCount) failed") {
                            ForEach(Array(apple.failures.prefix(200).enumerated()), id: \.offset) { _, f in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.title).lineLimit(1)
                                    Text(f.why).font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                            Button("Try these again") { apple.retryFailed() }
                        }
                    }
                }
            } header: { Text("Apple music analysis") } footer: {
                Text("iOS 27+. Only what you ask for is analysed: pick it here, or long-press a track, playlist or stick in the library → Analyse. It finds beats, bars, key, phrases, vocals and loudness in the background, only while nothing plays and the app is left alone, unless Analyse while tracks play is on (that shares the processors with the decks: on an older phone it could cause dropouts or warm the phone; it still pauses when the phone gets hot or in Low Power Mode). It also sorts the library by MATCH (what would follow the playing track best) and marks MIX IN and MIX OUT on a loaded track's waveform. Whose grid wins: Library & USB → Beat grids.")
            }
            Section {
                ForEach(AutoMix.Transition.allCases, id: \.self) { k in
                    MoveToggle(key: AIDJMoves.key(k), title: k.name, detail: Self.moveDetail(k))
                }
            } header: { Text("AI DJ: transitions") } footer: {
                Text("AI DJ picks one of these for each pair of tracks. With all of them off it uses the bass swap.")
            }
            Section {
                MoveToggle(key: AIDJMoves.variableLength, title: "Variable length", detail: "Shorter or longer per pair (4 to 32 bars), not only each transition's usual length.")
                MoveToggle(key: AIDJMoves.skipIntros, title: "Skip long intros", detail: "Bring the next track in at your CUE, else Apple's mix-in point, instead of its first beat.")
                MoveToggle(key: AIDJMoves.outro, title: "Mix out at the outro", detail: "Start the transition near where the playing track's outro begins (Apple's mix-out point).")
                MoveToggle(key: AIDJMoves.vocals, title: "Keep vocals apart", detail: "Plan around Apple's vocals so two singers aren't heard at once.")
                MoveToggle(key: AIDJMoves.loopBridge, title: "Loop bridge", detail: "A track too short to mix out of loops its last 8 bars until the next one is in.", def: false)
                MoveToggle(key: AIDJMoves.thirdDeck, title: "Third deck", detail: "Deck 3 loads the track after next while a transition runs, so the next mix can come sooner. Never more than two tracks heard at once.", def: false)
            } header: { Text("AI DJ: moves") } footer: {
                Text("Always on: the next track runs beat-matched with its fader down for a bar before it's heard, only one bass line plays at a time, and the tempo glides to the new track's own. MIX NOW mixes within two bars. Changes apply from the next transition; the third deck from the next START.")
            }
        }
    }

    static func moveDetail(_ k: AutoMix.Transition) -> String {
        switch k {
        case .bassSwap: return "The next track comes in with its bass cut; the basses swap on the halfway downbeat. 8 to 32 bars."
        case .eqHandoff: return "The highs swap first, then the basses on the halfway downbeat, then the mids. 16 or 32 bars."
        case .colorSweep: return "In through COLOR's high-pass, out through its low-pass, the basses swapped halfway. 8 or 16 bars."
        case .cut: return "Beat-matched and silent, then a clean cut on a downbeat. Used when vocals would clash or there's no room."
        }
    }
}

/// one AI DJ move on or off (UserDefaults key, on by default unless `def` says otherwise)
struct MoveToggle: View {
    let title: String, detail: String
    @AppStorage var on: Bool
    init(key: String, title: String, detail: String, def: Bool = true) {
        self.title = title; self.detail = detail
        _on = AppStorage(wrappedValue: def, key)
    }
    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Settings → Library & USB: tracks Cratebox's own analysis couldn't do, and why
struct AnalysisProblems: View {
    @ObservedObject var library: Library
    var body: some View {
        let bad = library.failed
        if !bad.isEmpty {
            Section {
                DisclosureGroup("\(bad.count) track\(bad.count == 1 ? "" : "s") couldn't be analysed") {
                    ForEach(bad.prefix(200), id: \.id) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.rec.artist.isEmpty ? t.rec.title : "\(t.rec.artist) - \(t.rec.title)").lineLimit(1)
                            Text(t.rec.fail ?? "").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Button("Try again") { library.retryFailed() }
            } header: { Text("Analysis problems") } footer: {
                Text("These tracks have no beat grid, so AI DJ and SYNC skip them. Fix the cause (plug the drive back in, add the folder again, or convert the file), then try again.")
            }
        }
    }
}
