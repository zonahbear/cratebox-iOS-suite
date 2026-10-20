// Cratebox USB's screen: playlists on the left, tracks in the middle, the track you picked on the right (it
// plays on the preview deck, with rekordbox's waveform, cues and grid to edit). Readiness, the preflight
// scan, staged changes and eject along the top. On a phone the three panes are tabs.
import SwiftUI
import UniformTypeIdentifiers
import CrateboxKit

struct CrateboxUSBView: View {
    @ObservedObject var usb: USBSession
    @State private var picking = false
    @State private var scanSheet = false
    @State private var stagedSheet = false
    @State private var settingsSheet = false
    @State private var selectedNode: String? = nil            // nil = all tracks
    @State private var selectedTrack: String?
    @State private var tab = 1                                // phones: 0 playlists, 1 tracks, 2 track
    var body: some View {
        VStack(spacing: 4) {
            ModeBar(title: "CRATEBOX USB", subtitle: subtitle) { bar }
            Group {
                if usb.root == nil { empty }
                else if usb.library == nil { ProgressView("Reading \(usb.name)…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { panes }
            }
            if !usb.message.isEmpty {
                Text(usb.message).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 2)
            }
        }
        .background(Theme.bg)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { usb.open(u) } else if case .failure(let e) = r { usb.note("Couldn't open that: \(e.localizedDescription)") }
        }
        .sheet(isPresented: $scanSheet) { USBScanView(usb: usb) }
        .sheet(isPresented: $stagedSheet) { USBStagedView(usb: usb) }
        .sheet(isPresented: $settingsSheet) { USBSettingsView(usb: usb) }
        .onChange(of: usb.report?.finished) { _, _ in if CommandLine.arguments.contains("-usb") && CommandLine.arguments.contains("-demo") { scanSheet = true } }
    }
    var subtitle: String {
        guard usb.root != nil, let l = usb.library else { return usb.ejected ? "Ejected: safe to unplug" : "No stick open" }
        var parts = [usb.name]
        if l.hasDeviceLibrary { parts.append("Device Library") }
        if l.hasOneLibrary { parts.append("OneLibrary") }
        if l.hasDeviceLibrary && l.hasOneLibrary { parts.append(l.inSync ? "in sync" : "\(l.differences.count) out of sync") }
        if !usb.fileSystem.isEmpty { parts.append(usb.fileSystem) }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder var bar: some View {
        if usb.root != nil {
            ReadinessBadge(readiness: usb.readiness, scanning: usb.scanning) { scanSheet = true }
            LitButton(label: "SCAN") { scanSheet = true }
            let n = usb.changeLog.count + usb.editedTracks.count
            LitButton(label: n > 0 ? "STAGED \(n)" : "STAGED", on: n > 0, color: Theme.accent) { stagedSheet = true }
            EjectButton(usb: usb)
        } else {
            LitButton(label: "OPEN USB", on: true, color: Theme.accent) { picking = true }
        }
        Button { settingsSheet = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
    }
    var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: usb.ejected ? "checkmark.circle.fill" : "externaldrive.badge.plus").font(.system(size: 44)).foregroundStyle(usb.ejected ? Theme.ok : Theme.accent)
            Text(usb.ejected ? "Safe to unplug" : "Open a rekordbox USB stick").font(.title3.weight(.bold))
            Text("Plug the stick in (a USB-C stick, or through a hub or Apple's adapter), then pick the drive itself in Files. Cratebox reads both rekordbox libraries on it, checks it against the players you'll use, and lets you prepare the set.")
                .font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 480)
            LitButton(label: "OPEN USB…", on: true, color: Theme.accent) { picking = true }.frame(width: 160)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var panes: some View {
        GeometryReader { g in
            if g.size.width >= 900 {
                HStack(spacing: 6) {
                    USBSidebar(usb: usb, selected: $selectedNode).frame(width: min(240, g.size.width * 0.2))
                    USBTrackList(usb: usb, node: selectedNode, selected: $selectedTrack)
                    USBInspector(usb: usb, preview: usb.preview, key: selectedTrack).frame(width: min(420, g.size.width * 0.36))
                }.padding(.horizontal, 6)
            } else {
                VStack(spacing: 4) {
                    Picker("", selection: $tab) { Text("Playlists").tag(0); Text("Tracks").tag(1); Text("Track").tag(2) }.pickerStyle(.segmented).padding(.horizontal, 8)
                    switch tab {
                    case 0: USBSidebar(usb: usb, selected: Binding(get: { selectedNode }, set: { selectedNode = $0; tab = 1 }))
                    case 1: USBTrackList(usb: usb, node: selectedNode, selected: Binding(get: { selectedTrack }, set: { selectedTrack = $0; if $0 != nil { tab = 2 } }))
                    default: USBInspector(usb: usb, preview: usb.preview, key: selectedTrack)
                    }
                }.padding(.horizontal, 6)
            }
        }
    }
}

struct ReadinessBadge: View {
    let readiness: Readiness
    let scanning: Bool
    let tap: () -> Void
    var color: Color {
        switch readiness {
        case .ready: return Theme.ok
        case .warnings: return Theme.warn
        case .notReady: return Theme.hot
        case .unknown: return Theme.dim
        }
    }
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if scanning { ProgressView().controlSize(.mini).tint(Theme.accent) } else { Circle().fill(color).frame(width: 8, height: 8) }
                Text(scanning ? "Scanning…" : readiness.label).font(.system(size: 11, weight: .bold)).lineLimit(1)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.6)))
        }.buttonStyle(.plain)
        .accessibilityLabel("USB readiness: \(readiness.label)")
    }
}

/// eject, with what it's doing: writing (wait), ready to eject, then safe to unplug
struct EjectButton: View {
    @ObservedObject var usb: USBSession
    var body: some View {
        Button { usb.eject() } label: {
            HStack(spacing: 4) {
                Image(systemName: usb.writing ? "arrow.triangle.2.circlepath" : "eject.fill").font(.system(size: 11, weight: .bold))
                Text(usb.writing ? "WRITING…" : "EJECT").font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(usb.writing ? Theme.hot : Theme.fg)
            .padding(.horizontal, 9).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(usb.writing ? Theme.hot : Theme.line2))
        }.buttonStyle(.plain).disabled(usb.writing)
        .accessibilityLabel(usb.writing ? "Writing to the stick, don't unplug" : "Eject the stick")
    }
}

// ---- playlists ----
struct USBSidebar: View {
    @ObservedObject var usb: USBSession
    @Binding var selected: String?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var creating: (folder: Bool, parent: String?)?
    @State private var newName = ""
    var body: some View {
        VStack(spacing: 0) {
            List {
                row(nil, "All tracks", icon: "music.note.list", depth: 0, count: usb.library?.tracks.count ?? 0)
                let rs = rows
                ForEach(rs.indices, id: \.self) { i in
                    let n = rs[i].0, depth = rs[i].1
                    row(n.id, n.name, icon: n.folder ? "folder" : "music.note.list", depth: depth, count: n.folder ? nil : n.tracks.count)
                        .contextMenu { menu(n) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            HStack(spacing: 6) {
                LitButton(label: "+ PLAYLIST", wide: true) { creating = (false, folderOfSelection); newName = "" }
                LitButton(label: "+ FOLDER", wide: true) { creating = (true, folderOfSelection); newName = "" }
            }.padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") { if let r = renaming { usb.rename(r, renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert(creating?.folder == true ? "New folder" : "New playlist", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") { if let c = creating, !newName.isEmpty { usb.newNode(newName, folder: c.folder, parent: c.parent) }; creating = nil }
            Button("Cancel", role: .cancel) { creating = nil }
        } message: { Text("Staged: it reaches the stick when you write the staged changes.") }
    }
    var folderOfSelection: String? { selected.flatMap { usb.node($0) }.flatMap { $0.folder ? $0.id : $0.parent } }
    var rows: [(USBNode, Int)] {
        var out = [(USBNode, Int)]()
        func walk(_ p: String?, _ d: Int) { for n in usb.children(p) { out.append((n, d)); if n.folder { walk(n.id, d + 1) } } }
        walk(nil, 0)
        return out
    }
    func row(_ id: String?, _ name: String, icon: String, depth: Int, count: Int?) -> some View {
        let on = selected == id
        let isSet = id != nil && usb.setPlaylist == id
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(on ? Theme.accent : Theme.muted)
            Text(name).font(.system(size: 13, weight: on ? .bold : .regular)).lineLimit(1)
            if isSet { Text("SET").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.black).padding(.horizontal, 4).background(Capsule().fill(Theme.accent)) }
            Spacer(minLength: 2)
            if let count { Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted) }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture { selected = id }
        .listRowBackground(on ? Theme.accent.opacity(0.14) : Color.clear)
    }
    @ViewBuilder func menu(_ n: USBNode) -> some View {
        if !n.folder || usb.library?.trackKeys(of: n.id).isEmpty == false {
            Button(usb.setPlaylist == n.id ? "Not the set any more" : "Make this the set (Set Priority)") { usb.setPlaylist = usb.setPlaylist == n.id ? nil : n.id }
        }
        Button("Rename") { renameText = n.name; renaming = n.id }
        if n.folder {
            Button("New playlist inside") { creating = (false, n.id); newName = "" }
            Button("New folder inside") { creating = (true, n.id); newName = "" }
        }
        Button("Delete", role: .destructive) { usb.delete(n.id); if selected == n.id { selected = nil } }
    }
}

// ---- tracks ----
struct USBTrackList: View {
    @ObservedObject var usb: USBSession
    let node: String?
    @Binding var selected: String?
    @State private var query = ""
    @State private var editMode: EditMode = .inactive
    var keys: [String] {
        guard let lib = usb.library else { return [] }
        let base: [String]
        if let node, let n = usb.node(node) {
            if n.folder {
                var seen = Set<String>(), out = [String]()
                func walk(_ p: String) { for c in usb.children(p) { if c.folder { walk(c.id) } else { for k in c.tracks where seen.insert(k).inserted { out.append(k) } } } }
                walk(n.id); base = out
            } else { base = n.tracks }
        } else { base = lib.tracks.map { $0.key } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return base }
        return base.filter { k in lib.track(k).map { "\($0.title) \($0.artist) \($0.fileName)".lowercased().contains(q) } ?? false }
    }
    var editablePlaylist: Bool { node.flatMap { usb.node($0) }.map { !$0.folder } ?? false }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(node.flatMap { usb.node($0)?.name } ?? "All tracks").font(.system(size: 13, weight: .bold)).lineLimit(1)
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 220)
                Spacer()
                if editablePlaylist { EditButton().font(.system(size: 12)) }
            }.padding(6)
            List {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if let t = usb.library?.track(k) { row(t, i) }
                }
                .onMove(perform: editablePlaylist ? { f, to in usb.moveTracks(in: node!, from: f, to: to) } : nil)
                .onDelete(perform: editablePlaylist ? { at in usb.removeTracks(in: node!, at: at) } : nil)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    func row(_ t: USBTrack, _ i: Int) -> some View {
        let issues = usb.issues(for: t.key)
        let worst = issues.map { $0.severity }.max()
        let dot: Color = usb.report == nil ? Theme.dim : worst == .critical ? Theme.hot : worst == .warning ? Theme.warn : Theme.ok
        let on = selected == t.key
        return HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(usb.edits[t.key]?.title ?? t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if usb.edits[t.key] != nil { Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                    if usb.fixList.contains(t.key) { Image(systemName: "wrench.adjustable").font(.system(size: 9)).foregroundStyle(Theme.warn) }
                }
                Text(usb.edits[t.key]?.artist ?? t.artist).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(t.bpm > 0 ? String(format: "%.1f", usb.edits[t.key]?.bpm ?? t.bpm) : "—").font(.system(size: 11, design: .monospaced)).frame(width: 44, alignment: .trailing)
            let k = RekordboxANLZ.keyIndex(t.keyName)
            Text(Keys.camelot(k)?.label ?? "").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Keys.camelot(k).map { Theme.keyColor($0.num, $0.letter) } ?? Theme.muted).frame(width: 30)
            Text(String(format: "%d:%02d", Int(t.duration) / 60, Int(t.duration) % 60)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 40, alignment: .trailing)
            Text(t.ext.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim).frame(width: 34)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = t.key; usb.preview.load(t) }
        .listRowBackground(on ? Theme.accent.opacity(0.14) : Color.clear)
        .contextMenu {
            Menu("Add to playlist") {
                ForEach(usb.nodes.filter { !$0.folder }) { n in Button(n.name) { usb.add([t.key], to: n.id) } }
            }
            Button(usb.fixList.contains(t.key) ? "Take off the fix list" : "Add to the fix list") {
                if let i = usb.fixList.firstIndex(of: t.key) { usb.fixList.remove(at: i) } else { usb.fixList.append(t.key) }
            }
            if usb.edits[t.key] != nil { Button("Revert my edits", role: .destructive) { usb.revert(t.key) } }
        }
    }
}
