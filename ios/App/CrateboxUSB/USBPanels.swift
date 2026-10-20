// Cratebox USB's other panels: the track inspector (preview, cues, loops, grid, info), the preflight scan,
// the staged changes, and the settings with the Proving Ground for writes that aren't proven yet.
import SwiftUI
import CrateboxKit

// ---- the track you picked ----
struct USBInspector: View {
    @ObservedObject var usb: USBSession
    @ObservedObject var preview: USBPreview
    let key: String?
    var body: some View {
        Group {
            if let key, let t = usb.library?.track(key) {
                USBTrackPanel(usb: usb, preview: preview, deck: preview.deck, t: t)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(Theme.dim)
                    Text("Pick a track to hear it and edit its cues, grid and info").font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
}

struct USBTrackPanel: View {
    @ObservedObject var usb: USBSession
    @ObservedObject var preview: USBPreview
    @ObservedObject var deck: DeckModel
    let t: USBTrack
    @State private var bpmText = ""
    @State private var meta = false
    var onDeck: Bool { preview.key == t.key }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(usb.edits[t.key]?.title ?? t.title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                    Text(usb.edits[t.key]?.artist ?? t.artist).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text("\(t.path) · \(t.ext.uppercased())\(t.sampleRate > 0 ? " · \(t.sampleRate / 1000) kHz" : "")\(t.bitDepth > 0 ? " · \(t.bitDepth)-bit" : "")\(t.bitrate > 0 ? " · \(t.bitrate) kbps" : "")")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(2)
                }
                issues
                player
                if onDeck && deck.loaded {
                    hotCues
                    memory
                    loops
                    grid
                }
                info
                Text("Your cue, grid and info edits stay in Cratebox (Staged): use them in Performance Mode or export rekordbox XML. Writing them into the stick's analysis files is locked until a writer is proven on hardware.")
                    .font(.caption2).foregroundStyle(Theme.dim)
                if usb.edits[t.key] != nil { Button("Revert my edits to this track", role: .destructive) { usb.revert(t.key); preview.load(t) }.font(.caption) }
            }.padding(10)
        }
    }
    @ViewBuilder var issues: some View {
        let list = usb.issues(for: t.key)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list) { i in IssueRow(usb: usb, issue: i, compact: true) }
            }
        }
    }
    var player: some View {
        VStack(spacing: 6) {
            if onDeck && (deck.loaded || deck.loading) {
                WaveformView(deck: deck, color: Theme.accent).frame(height: 92)
                OverviewView(deck: deck, color: Theme.accent).frame(height: 18)
            } else {
                Button { preview.load(t) } label: {
                    Label("Load to preview", systemImage: "play.circle").frame(maxWidth: .infinity, minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
                }.buttonStyle(.plain)
            }
            if onDeck {
                HStack(spacing: 8) {
                    HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                        Text("CUE").font(.system(size: 13, weight: .heavy)).frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(Theme.cue).background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
                    }
                    Button { deck.togglePlay() } label: {
                        Text(deck.playing ? "PAUSE" : "PLAY").font(.system(size: 13, weight: .heavy)).frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(deck.playing ? Color.black : Theme.ok).background(RoundedRectangle(cornerRadius: 8).fill(deck.playing ? Theme.ok : Theme.raise))
                    }.buttonStyle(.plain)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(deck.loading ? "Loading…" : clock(deck.now())).font(.system(size: 12, design: .monospaced))
                        if deck.loaded { Text(String(format: "%.2f BPM", deck.bpm)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted) }
                    }.frame(width: 80)
                }
            }
        }
    }
    var hotCues: some View {
        VStack(alignment: .leading, spacing: 5) {
            section("HOT CUES", "tap: set at the playhead, or jump · long-press: delete")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                ForEach(0..<8, id: \.self) { k in
                    let set = deck.hot[k] != nil
                    Text(String(UnicodeScalar(65 + k)!) + (set ? String(format: " %.1f", deck.hot[k]!) : "")).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(set ? Color.black : Theme.fg)
                        .background(RoundedRectangle(cornerRadius: 6).fill(set ? Theme.hot : Theme.raise))
                        .onTapGesture { deck.hotcue(k); usb.log("Edit \(t.fileName): hot cue \(String(UnicodeScalar(65 + k)!))") }
                        .onLongPressGesture { deck.clearHot(k); usb.log("Edit \(t.fileName): delete hot cue \(String(UnicodeScalar(65 + k)!))") }
                }
            }
        }
    }
    var memory: some View {
        VStack(alignment: .leading, spacing: 5) {
            section("MEMORY CUES & LOOPS", "")
            ForEach(usb.memoryCues(t.key)) { m in
                HStack {
                    Image(systemName: m.loopEnd == nil ? "arrowtriangle.down.fill" : "repeat").font(.system(size: 10)).foregroundStyle(m.loopEnd == nil ? Theme.cue : Theme.loop)
                    Text(clock(m.time) + (m.loopEnd.map { " → " + clock($0) } ?? "")).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button("Go") { deck.seek(m.time) }.font(.caption)
                    Button { usb.deleteMemory(t.key, m.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 6) {
                LitButton(label: "+ MEMORY CUE", wide: true) { let at = deck.snap(deck.now()); usb.addMemory(t.key, time: at); if usb.edits[t.key]?.cue == nil { usb.edit(t.key) { $0.cue = at } } }
                LitButton(label: "+ SAVE LOOP", wide: true) {
                    if let a = deck.loop.a, let b = deck.loop.b { usb.addMemory(t.key, time: a, loopEnd: b) } else { usb.message = "Set a loop first (IN / OUT or 4 BEAT)" }
                }
            }
        }
    }
    var loops: some View {
        HStack(spacing: 5) {
            LitButton(label: "IN", on: deck.loop.a != nil && deck.loop.b == nil, color: Theme.loop, wide: true) { deck.loopIn() }
            LitButton(label: "OUT", on: deck.loop.on, color: Theme.loop, wide: true) { deck.loopOut() }
            LitButton(label: "4 BEAT", wide: true) { deck.beatLoop(4) }
            LitButton(label: "EXIT", wide: true) { deck.reloopExit() }
        }
    }
    var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("BEAT GRID", (deck.track?.gridManual ?? false) ? "edited" : (deck.track?.rbGrid ?? false) ? "rekordbox's" : "Cratebox's analysis")
            HStack(spacing: 6) {
                TextField("BPM", text: $bpmText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 80)
                    .onAppear { bpmText = String(format: "%.2f", deck.bpm) }
                    .onChange(of: deck.bpm) { _, v in bpmText = String(format: "%.2f", v) }
                LitButton(label: "SET") { if let v = Double(bpmText.replacingOccurrences(of: ",", with: ".")), v > 30, v < 300 { deck.setBpm(v) } }
                LitButton(label: "×2") { deck.setBpm(deck.bpm * 2) }
                LitButton(label: "÷2") { deck.setBpm(deck.bpm / 2) }
                LitButton(label: "TAP") { deck.tap() }
            }
            HStack(spacing: 5) {
                LitButton(label: "◀◀ 5ms", wide: true) { deck.nudgeGrid(-0.005) }
                LitButton(label: "◀ 1ms", wide: true) { deck.nudgeGrid(-0.001) }
                LitButton(label: "1ms ▶", wide: true) { deck.nudgeGrid(0.001) }
                LitButton(label: "5ms ▶▶", wide: true) { deck.nudgeGrid(0.005) }
            }
            HStack(spacing: 5) {
                LitButton(label: "BAR 1 HERE", wide: true) { deck.downbeatHere() }
                LitButton(label: "BEAT HERE", wide: true) { deck.beatHere() }
                LitButton(label: "RESET", wide: true) { deck.resetGrid(); usb.edit(t.key) { $0.bpm = nil; $0.firstBeat = nil } }
            }
        }
    }
    var info: some View {
        DisclosureGroup(isExpanded: $meta) { USBMetaEditor(usb: usb, t: t) } label: { section("TRACK INFO", usb.edits[t.key]?.hasMeta == true ? "edited" : "") }
            .tint(Theme.accent)
    }
    func section(_ s: String, _ note: String) -> some View {
        HStack(spacing: 6) {
            Text(s).font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Theme.accent)
            if !note.isEmpty { Text(note).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1) }
        }
    }
}

struct USBMetaEditor: View {
    @ObservedObject var usb: USBSession
    let t: USBTrack
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var genre = ""
    @State private var comment = ""
    @State private var rating = 0
    var body: some View {
        VStack(spacing: 6) {
            field("Title", $title); field("Artist", $artist); field("Album", $album); field("Genre", $genre); field("Comment", $comment)
            Stepper("Rating: " + String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating), value: $rating, in: 0...5).font(.system(size: 12))
            LitButton(label: "KEEP THESE", on: true, color: Theme.accent, wide: true) {
                usb.edit(t.key) { e in
                    e.title = title == t.title ? nil : title; e.artist = artist == t.artist ? nil : artist; e.album = album == t.album ? nil : album
                    e.genre = genre == t.genre ? nil : genre; e.comment = comment == t.comment ? nil : comment; e.rating = rating == t.rating ? nil : rating
                }
                usb.log("Edit \(t.fileName): track info")
            }
        }
        .padding(.top, 4)
        .onAppear {
            let e = usb.edits[t.key]
            title = e?.title ?? t.title; artist = e?.artist ?? t.artist; album = e?.album ?? t.album; genre = e?.genre ?? t.genre
            comment = e?.comment ?? t.comment; rating = e?.rating ?? t.rating
        }
    }
    func field(_ l: String, _ b: Binding<String>) -> some View {
        HStack { Text(l).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading); TextField(l, text: b).textFieldStyle(.roundedBorder).font(.system(size: 12)) }
    }
}

// ---- one scan issue, with Fix / Review / Skip ----
struct IssueRow: View {
    @ObservedObject var usb: USBSession
    let issue: ScanIssue
    var compact = false
    @State private var review = false
    var color: Color { issue.severity == .critical ? Theme.hot : issue.severity == .warning ? Theme.warn : Theme.muted }
    var locked: Bool { (issue.fix == .removeFromPlaylists || issue.fix == .syncPlaylists) && usb.playlistBlocker != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: issue.severity == .critical ? "exclamationmark.octagon.fill" : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(issue.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        if issue.inSet { Text("SET").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.black).padding(.horizontal, 4).background(Capsule().fill(Theme.accent)) }
                        if issue.conflict { Text("CONFLICT").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.black).padding(.horizontal, 4).background(Capsule().fill(Theme.warn)) }
                    }
                    if !compact || review { Text(issue.detail).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }
            }
            HStack(spacing: 6) {
                if let f = issue.fix, f != .skip, f != .reexport {
                    Button { usb.fix(issue) } label: {
                        Label(f.title + (locked ? " (staged)" : ""), systemImage: locked ? "lock" : "wand.and.stars").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.bordered).tint(Theme.accent)
                }
                Button(review ? "Hide" : "Review") { review.toggle() }.buttonStyle(.bordered).font(.system(size: 11))
                Button("Skip") { usb.skip(issue) }.buttonStyle(.bordered).font(.system(size: 11)).tint(Theme.muted)
            }.padding(.leading, 18)
            if review {
                VStack(alignment: .leading, spacing: 3) {
                    if let k = issue.trackKey, let t = usb.library?.track(k) {
                        Text(t.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                        let inLists = usb.nodes.filter { $0.tracks.contains(k) }.map { $0.name }
                        if !inLists.isEmpty { Text("In: " + inLists.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Theme.dim) }
                    }
                    if issue.fix == .reexport { Text("Only rekordbox can fix this one: fix it there, export to the stick again, then rescan.").font(.system(size: 10)).foregroundStyle(Theme.dim) }
                    if locked, let b = usb.playlistBlocker { Text(b).font(.system(size: 10)).foregroundStyle(Theme.dim) }
                }.padding(.leading, 18)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise.opacity(0.6)))
    }
}

// ---- the preflight scan ----
struct USBScanView: View {
    @ObservedObject var usb: USBSession
    @Environment(\.dismiss) var dismiss
    @State private var showSkipped = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach(ScanMode.allCases) { m in
                            Button { usb.mode = m } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.title).font(.system(size: 13, weight: .heavy))
                                    Text(m.blurb).font(.system(size: 10)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading).padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(usb.mode == m ? Theme.accent.opacity(0.2) : Theme.raise))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(usb.mode == m ? Theme.accent : Theme.line2))
                            }.buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PLAYERS AT THE GIG").font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Theme.accent)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                            ForEach(PlayerProfiles.all + [PlayerProfiles.unknown]) { p in
                                let on = usb.players.contains(p.id)
                                Button {
                                    if on { usb.players.removeAll { $0 == p.id } } else { usb.players.append(p.id) }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(p.name).font(.system(size: 11, weight: .bold)).lineLimit(1)
                                        if !p.confirmed { Text("?").font(.system(size: 9, weight: .bold)).foregroundStyle(on ? Color.black.opacity(0.6) : Theme.dim) }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .foregroundStyle(on ? Color.black : Theme.fg)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent : Theme.raise))
                                }.buttonStyle(.plain)
                            }
                        }
                        let req = PlayerProfiles.requirement(usb.players)
                        Text("Needs: \([req.deviceLibrary ? "Device Library" : nil, req.oneLibrary ? "OneLibrary" : nil].compactMap { $0 }.joined(separator: " + ")) · \(req.codecs.map { $0.rawValue.uppercased() }.sorted().joined(separator: ", ")) up to \(req.maxSampleRate / 1000) kHz / \(req.maxBitDepth)-bit · \(req.hotCues) hot cues · \(req.fileSystems.map { $0.sorted().joined(separator: "/") } ?? "any file system"). Players marked ? weren't confirmed against their manual: checked strictly.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 8) {
                        Text("SET PRIORITY").font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Theme.accent)
                        Menu {
                            Button("None (whole stick)") { usb.setPlaylist = nil }
                            ForEach(usb.library?.playlists ?? []) { p in Button(String(repeating: "  ", count: p.depth) + p.name) { usb.setPlaylist = p.id } }
                        } label: {
                            Text(usb.setPlaylist.flatMap { usb.library?.playlist($0)?.name } ?? "Pick the set you'll play").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(height: 28).background(Capsule().fill(Theme.raise))
                        }
                        Spacer()
                        if usb.scanning {
                            ProgressView(value: usb.scanProgress).frame(width: 120).tint(Theme.accent)
                            Button("Stop") { usb.stopScan() }
                        } else {
                            LitButton(label: "SCAN \(usb.mode.title.uppercased())", on: true, color: Theme.accent) { usb.scan() }
                        }
                    }
                    if let r = usb.report { results(r) }
                }.padding()
            }
            .background(Theme.bg)
            .navigationTitle("Preflight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ReadinessBadge(readiness: usb.readiness, scanning: usb.scanning) {} }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
    @ViewBuilder func results(_ r: ScanReport) -> some View {
        let open = r.issues.filter { showSkipped || !usb.skipped.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            Text("\(r.options.mode.title): \(r.tracksChecked) tracks\(r.setTracks > 0 ? ", set of \(r.setTracks) first" : "") · \(Int(r.finished.timeIntervalSince(r.started) * 1000)) ms\(r.cancelled ? " · stopped" : "")")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if !usb.quickFixes.isEmpty {
                Text("QUICK FIX").font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Theme.accent)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(usb.quickFixes) { q in
                            let writes = q.fix == .removeFromPlaylists || q.fix == .syncPlaylists
                            Button { usb.runQuickFix(q.fix) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: writes && usb.playlistBlocker != nil ? "lock" : "wand.and.stars")
                                    Text(q.fix == .skip ? "Skip \(q.count) notes" : "\(q.fix.title) · \(q.count)")
                                }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 32)
                                .background(Capsule().fill(Theme.accent.opacity(0.18))).overlay(Capsule().stroke(Theme.accent.opacity(0.6)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if open.isEmpty { Label("Nothing to fix for these players", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok).font(.callout) }
            ForEach(IssueCategory.allCases, id: \.self) { c in
                let list = open.filter { $0.category == c }
                if !list.isEmpty {
                    Text("\(c.rawValue.uppercased()) · \(list.count)").font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Theme.muted)
                    ForEach(list.prefix(60)) { i in IssueRow(usb: usb, issue: i).opacity(usb.skipped.contains(i.id) ? 0.45 : 1) }
                    if list.count > 60 { Text("…and \(list.count - 60) more").font(.caption).foregroundStyle(Theme.dim) }
                }
            }
            HStack {
                Toggle("Show skipped", isOn: $showSkipped).font(.caption).fixedSize()
                Spacer()
                if !usb.skipped.isEmpty { Button("Unskip all (\(usb.skipped.count))") { usb.unskipAll() }.font(.caption) }
            }
        }
    }
}

// ---- staged changes and where they can go ----
struct USBStagedView: View {
    @ObservedObject var usb: USBSession
    @Environment(\.dismiss) var dismiss
    @State private var shared: URL?
    @State private var base = UserDefaults.standard.string(forKey: "cb.usb.xmlBase") ?? ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if usb.changeLog.isEmpty && !usb.playlistsChanged { Text("No playlist changes").foregroundStyle(Theme.muted) }
                    ForEach(Array(usb.changeLog.filter { !$0.hasPrefix("Edit ") }.enumerated()), id: \.offset) { _, s in Text(s).font(.system(size: 13)) }
                    Button { usb.writePlaylists() } label: { Label(usb.writing ? "Writing…" : "Write playlists to the stick", systemImage: usb.playlistBlocker == nil ? "square.and.arrow.down" : "lock") }
                        .disabled(usb.playlistBlocker != nil || usb.writing || !usb.playlistsChanged)
                    if usb.playlistsChanged { Button("Discard playlist changes", role: .destructive) { usb.discardPlaylistChanges() } }
                } header: { Text("Playlists") } footer: {
                    Text(usb.playlistBlocker ?? "Writes go to every library on the stick, or none: backed up first, staged, checked, swapped in, and recoverable if the stick is pulled half way.")
                }
                Section {
                    if usb.editedTracks.isEmpty { Text("No cue, grid or info edits").foregroundStyle(Theme.muted) }
                    ForEach(usb.editedTracks, id: \.self) { k in
                        let e = usb.edits[k]!
                        HStack {
                            Text(usb.library?.track(k)?.title ?? k).lineLimit(1)
                            Spacer()
                            Text([e.hasCues ? "cues" : nil, e.hasGrid ? "grid" : nil, e.hasMeta ? "info" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Button("Use in Performance Mode") { usb.applyToPerformance() }.disabled(usb.editedTracks.isEmpty)
                    HStack {
                        TextField("Stick's path on the computer (e.g. E:/ or /Volumes/DJ USB)", text: $base).font(.system(size: 12))
                        Button("Export rekordbox XML") { UserDefaults.standard.set(base, forKey: "cb.usb.xmlBase"); shared = usb.exportXML(base: base) }
                    }
                } header: { Text("Cues, grid and track info") } footer: {
                    Text("rekordbox's analysis files have no proven writer yet, so these don't go onto the stick. Performance Mode uses them when it plays this stick; the XML carries them to rekordbox (Preferences → View → rekordbox xml) to apply and export again.")
                }
                Section("Fix list") {
                    if usb.fixList.isEmpty { Text("Empty").foregroundStyle(Theme.muted) }
                    ForEach(usb.fixList, id: \.self) { k in Text(usb.library?.track(k)?.fileName ?? k).font(.system(size: 12)) }
                    if !usb.fixList.isEmpty { Button("Share fix list (CSV)") { shared = usb.exportFixListFile() } }
                }
            }
            .navigationTitle("Staged changes")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: Binding(get: { shared.map { Shared(url: $0) } }, set: { shared = $0?.url })) { s in ShareSheet(items: [s.url]) }
        }
    }
}

// ---- settings, backups and the Proving Ground ----
struct USBSettingsView: View {
    @ObservedObject var usb: USBSession
    @Environment(\.dismiss) var dismiss
    @State private var confirm: USBWriteKind?
    var body: some View {
        NavigationStack {
            Form {
                if let l = usb.library {
                    Section("This stick") {
                        LabeledContent("Name", value: usb.name)
                        LabeledContent("File system", value: usb.fileSystem.isEmpty ? "not reported" : usb.fileSystem)
                        LabeledContent("Device Library", value: l.hasDeviceLibrary ? "\(l.pdb?.tracks.count ?? 0) tracks" : "none")
                        LabeledContent("OneLibrary", value: l.hasOneLibrary ? "\(l.one?.tracks.count ?? 0) tracks\(l.one?.integrity == ["ok"] ? ", integrity ok" : "")" : (l.oneError ?? "none"))
                        if l.hasDeviceLibrary && l.hasOneLibrary { LabeledContent("Sync", value: l.inSync ? "the two agree" : "\(l.differences.count) differences") }
                        Button("Read the stick again") { usb.reload(keepNodes: true) }
                    }
                    Section {
                        Button("Restore export.pdb from Cratebox's last backup") { usb.restoreBackup("PIONEER/rekordbox/export.pdb") }
                        Button("Restore exportLibrary.db from Cratebox's last backup") { usb.restoreBackup("PIONEER/rekordbox/exportLibrary.db") }
                    } header: { Text("Backups") } footer: { Text("Cratebox backs up a database every time it writes one, in PIONEER/rekordbox/.cratebox/backups on the stick (the newest five) and in the app.") }
                }
                Section {
                    ForEach(USBWriteKind.allCases) { k in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(k.title).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if k.status == .unsupported { Text("NO WRITER").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.dim) }
                                else {
                                    Toggle("", isOn: Binding(get: { usb.proven.contains(k) }, set: { v in if v { confirm = k } else { usb.proven.remove(k) } })).labelsHidden()
                                }
                            }
                            Text(k.note).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                } header: { Text("Proving Ground: writes to the stick") } footer: {
                    Text("Every write is locked until it's proven on your hardware. To prove one: copy a stick (or export a spare), make a change on the copy here, play it on each player you'll use (the playlist shows, tracks load, cues and grid as expected), then switch it on. Switching it on is your confirmation; it only unlocks that write.")
                }
            }
            .navigationTitle("Cratebox USB")
            .toolbar { Button("Done") { dismiss() } }
            .alert("Unlock \(confirm?.title ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Cancel", role: .cancel) { confirm = nil }
                Button("I tested it on my players") { if let k = confirm { usb.proven.insert(k) }; confirm = nil }
            } message: { Text("Only if you've checked it on a spare stick on the players you'll use. Cratebox still backs up, checks and can recover every write, but a write that isn't proven may leave a stick the players read wrongly.") }
        }
    }
}
