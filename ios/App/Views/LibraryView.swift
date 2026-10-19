import SwiftUI
import CrateboxKit

enum SortKey: String, CaseIterable { case none, title, artist, bpm, key, time }

struct LibraryPane: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var playlists: Playlists
    @EnvironmentObject var devices: Devices
    @EnvironmentObject var core: Core
    @State private var query = ""
    @State private var sorts: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "cb.sorts") as? [String: [String]]) ?? [:]
    @State private var showSidebar = true
    @State private var pickFolder = false
    @State private var pickUSB = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive

    // ---- what the list shows ----
    var viewKey: String {
        switch app.view {
        case .collection: return "all"
        case .playlist(let id): return "pl:" + id
        case .device(let d): return "dev:" + d
        case .devicePlaylist(let d, let id): return "devpl:\(d):\(id)"
        }
    }
    var sort: (SortKey, Bool) {
        let s = sorts[viewKey] ?? []
        return (SortKey(rawValue: s.first ?? "") ?? .none, s.count > 1 && s[1] == "desc")
    }
    func setSort(_ k: SortKey) {
        let (cur, desc) = sort
        if k == .none { sorts[viewKey] = nil } else { sorts[viewKey] = [k.rawValue, cur == k && !desc ? "desc" : "asc"] }
        UserDefaults.standard.set(sorts, forKey: "cb.sorts")
    }
    struct Row: Identifiable { let id: String; let pos: Int; let t: LibTrack? ; let title: String; let artist: String }
    var rows: [Row] {
        var base: [Row]
        switch app.view {
        case .collection: base = library.tracks.filter { $0.device == nil }.enumerated().map { Row(id: $0.element.id, pos: $0.offset, t: $0.element, title: $0.element.info.title, artist: $0.element.info.artist) }
        case .playlist(let id):
            let p = playlists.get(id)
            base = (p?.items ?? []).enumerated().map { k, tid in
                let t = library.track(tid)
                return Row(id: "\(k)|\(tid)", pos: k, t: t, title: t?.info.title ?? p?.meta[tid]?["title"] ?? tid, artist: t?.info.artist ?? p?.meta[tid]?["artist"] ?? "")
            }
        case .device(let d): base = library.tracks.filter { $0.device == d }.enumerated().map { Row(id: $0.element.id, pos: $0.offset, t: $0.element, title: $0.element.info.title, artist: $0.element.info.artist) }
        case .devicePlaylist(let d, let id):
            let dev = devices.list.first { $0.id == d }, n = dev?.tree.first { $0.id == id }
            base = (n?.tracks ?? []).enumerated().map { k, rid in
                let t = dev?.byRbId[rid]
                return Row(id: "\(k)|\(rid)", pos: k, t: t, title: t?.info.title ?? "Track \(rid)", artist: t?.info.artist ?? "")
            }
        }
        let q = query.lowercased()
        if !q.isEmpty {
            base = base.filter { r in
                r.title.lowercased().contains(q) || r.artist.lowercased().contains(q) || (r.t.flatMap { Keys.camelot($0.info.key)?.label.lowercased() } == q)
            }
        }
        let (k, desc) = sort
        if k != .none {
            func v(_ r: Row) -> (Double, String) {
                switch k {
                case .title: return (0, r.title.lowercased())
                case .artist: return (0, r.artist.lowercased())
                case .bpm: return (r.t?.info.bpm ?? 0, "")
                case .key: return (Double(r.t.flatMap { Keys.camelot($0.info.key)?.sort } ?? 99), "")
                case .time: return (r.t?.info.duration ?? 0, "")
                case .none: return (0, "")
                }
            }
            base = base.stableSort { a, b in let x = v(a), y = v(b); return desc ? (x.0 != y.0 ? x.0 > y.0 : x.1 > y.1) : (x.0 != y.0 ? x.0 < y.0 : x.1 < y.1) }
        }
        return base
    }
    var editable: Bool {
        switch app.view {
        case .playlist: return sort.0 == .none && query.isEmpty
        case .devicePlaylist: return devices.editable && sort.0 == .none && query.isEmpty
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar { sidebar.frame(width: 210) ; Divider() }
            VStack(spacing: 0) {
                toolbar
                header
                list
            }
        }
        .background(Theme.panel)
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in if case .success(let u) = r { _ = library.addFolder(u) } }
        .fileImporter(isPresented: $pickUSB, allowedContentTypes: [.folder]) { r in if case .success(let u) = r { devices.open(u) } }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    var toolbar: some View {
        HStack(spacing: 6) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain)
            Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
            TextField("Search title, artist or key (8A)", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 260)
            Spacer()
            if !library.progress.isEmpty { Text(library.progress).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
            if editable { EditButton().font(.system(size: 12)) }
        }.padding(6).environment(\.editMode, $editMode)
    }
    var title: String {
        switch app.view {
        case .collection: return "Collection"
        case .playlist(let id): return playlists.get(id)?.name ?? "Playlist"
        case .device(let d): return devices.list.first { $0.id == d }?.name ?? "Device"
        case .devicePlaylist(let d, let id): let dev = devices.list.first { $0.id == d }; return "\(dev?.name ?? "") · \(dev?.tree.first { $0.id == id }?.name ?? "")"
        }
    }
    var header: some View {
        HStack(spacing: 0) {
            col("#", .none, 26)
            col("Title", .title, nil)
            col("Artist", .artist, nil)
            col("BPM", .bpm, 54)
            col("Key", .key, 40)
            col("Time", .time, 46)
            Text("Load").frame(width: core.four ? 132 : 70).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(.horizontal, 6).frame(height: 22).background(Theme.raise)
    }
    func col(_ label: String, _ k: SortKey, _ w: CGFloat?) -> some View {
        let (cur, desc) = sort
        let t = label + (cur == k && k != .none ? (desc ? " ▾" : " ▴") : "")
        return Button { setSort(k) } label: {
            Text(t).font(.system(size: 10, weight: cur == k ? .bold : .regular)).foregroundStyle(cur == k && k != .none ? Theme.fg : Theme.muted)
                .frame(maxWidth: w == nil ? .infinity : w, alignment: .leading)
        }.buttonStyle(.plain).frame(width: w)
    }

    var list: some View {
        let rs = rows
        DispatchQueue.main.async { app.visibleTrackIds = rs.compactMap { $0.t?.id } }
        return List(selection: Binding(get: { app.selection.map { Set([$0]) } ?? [] }, set: { app.selection = $0.first })) {
            ForEach(rs) { r in row(r).tag(r.t?.id ?? r.id).listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)).listRowBackground(Theme.panel) }
                .onMove(perform: editable ? { from, to in move(from, to) } : nil)
                .onDelete(perform: editable ? { del($0) } : nil)
        }
        .listStyle(.plain).environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .overlay {
            if rs.isEmpty && app.view == .collection {
                VStack(spacing: 8) {
                    Text("No music yet").font(.headline)
                    Text("Add the folder you DJ from (on this iPhone/iPad, in iCloud Drive, or on a USB drive). Cratebox reads it in place: nothing is copied.").font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("Add music folder…") { pickFolder = true }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
    func row(_ r: Row) -> some View {
        let t = r.t
        let ref = refKey
        return HStack(spacing: 0) {
            Text("\(r.pos + 1)").frame(width: 26, alignment: .leading).foregroundStyle(Theme.dim)
            Text(r.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).foregroundStyle(t == nil ? Theme.dim : Theme.fg)
            Text(r.artist).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).foregroundStyle(Theme.muted)
            Text(t.map { ($0.info.bpm ?? 0) > 0 ? String(format: "%.1f", $0.info.bpm!) : ($0.analysed ? "?" : "…") } ?? "").frame(width: 54, alignment: .leading).font(Theme.mono)
            keyCell(t, ref).frame(width: 40, alignment: .leading)
            Text(t.map { $0.info.duration > 0 ? clockShort($0.info.duration) : "" } ?? "").frame(width: 46, alignment: .leading).font(Theme.mono).foregroundStyle(Theme.muted)
            HStack(spacing: 3) {
                ForEach(0..<(core.four ? 4 : 2), id: \.self) { d in
                    Button { if let t { app.load(t, deck: d) } } label: {
                        Text("\(d + 1)").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 22)
                            .background(RoundedRectangle(cornerRadius: 4).fill(onDeck(t) == d ? Theme.deck[d] : Theme.raise)).foregroundStyle(onDeck(t) == d ? Color.black : Theme.deck[d])
                    }.buttonStyle(.borderless)
                }
            }.frame(width: core.four ? 132 : 70)
        }
        .font(.system(size: 12)).frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let t { app.load(t, deck: core.decks.firstIndex { core.deckActive($0.i) && !$0.playing } ?? 0) } }
        .onTapGesture { app.selection = t?.id }
        .contextMenu { if let t { addToMenu([t]) } }
    }
    var refKey: Int {
        let p = core.decks.filter { $0.playing && $0.loaded }.sorted { $0.startedAt > $1.startedAt }
        return p.first?.keyNow() ?? -1
    }
    func keyCell(_ t: LibTrack?, _ ref: Int) -> some View {
        guard let t, let c = Keys.camelot(t.info.key) else { return AnyView(Text(t.map { $0.analysed ? "?" : "…" } ?? "").foregroundStyle(Theme.dim)) }
        let match = ref >= 0 && Keys.mixes(t.info.key, ref)
        return AnyView(Text(c.label).font(.system(size: 12, weight: match ? .heavy : .semibold, design: .monospaced)).foregroundStyle(Theme.keyColor(c.num, c.letter))
            .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 3).stroke(match ? Theme.ok : .clear)))
    }
    func onDeck(_ t: LibTrack?) -> Int? { guard let t else { return nil }; return core.decks.firstIndex { $0.track === t.info } }
    func clockShort(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    @ViewBuilder func addToMenu(_ tracks: [LibTrack]) {
        Menu("Add to playlist") {
            ForEach(playlists.lists.filter { !$0.folder }) { p in Button(playlists.path(p)) { playlists.add(tracks, to: p.id); app.status("Added to \(p.name)") } }
            Button("New playlist…") { let p = playlists.new(playlists.nextName("Playlist")); playlists.add(tracks, to: p.id); renaming = "pl:" + p.id; renameText = p.name }
        }
        if devices.editable, let d = devices.list.first(where: { tracks.first?.device == $0.id }) {
            Menu("Add to \(d.name) playlist") {
                ForEach(d.tree.filter { !$0.folder }, id: \.id) { n in Button(n.name) { devices.add(tracks, to: n.id, in: d) } }
            }
        }
    }
    func move(_ from: IndexSet, _ to: Int) {
        switch app.view {
        case .playlist(let id): playlists.move(from: from, to: to, in: id)
        case .devicePlaylist(let dv, let id): if let d = devices.list.first(where: { $0.id == dv }) { devices.move(from: from, to: to, in: id, of: d) }
        default: break
        }
    }
    func del(_ at: IndexSet) {
        switch app.view {
        case .playlist(let id): playlists.remove(at: at, from: id)
        case .devicePlaylist(let dv, let id): if let d = devices.list.first(where: { $0.id == dv }) { devices.remove(at: at, from: id, in: d) }
        default: break
        }
    }

    // ---- the tree: collection, playlists, devices ----
    var sidebar: some View {
        List {
            Button { app.view = .collection } label: { Label("Collection", systemImage: "music.note.list") }.listRowBackground(app.view == .collection ? Theme.raise : Theme.panel)
            Section {
                ForEach(treeRows(nil, 0), id: \.0.id) { p, depth in plRow(p, depth) }
            } header: {
                HStack {
                    Text("PLAYLISTS")
                    Spacer()
                    Button { let p = playlists.new(playlists.nextName("Playlist")); renaming = "pl:" + p.id; renameText = p.name } label: { Image(systemName: "plus") }
                    Button { let p = playlists.new(playlists.nextName("Folder"), folder: true); renaming = "pl:" + p.id; renameText = p.name } label: { Image(systemName: "folder.badge.plus") }
                }
            }
            Section {
                ForEach(devices.list) { d in deviceRows(d) }
            } header: {
                HStack { Text("DEVICES"); Spacer(); Button("+ USB") { pickUSB = true }.font(.system(size: 11)) }
            }
            Section("FOLDERS") {
                ForEach(library.folders.filter { !$0.device }) { f in
                    Text(f.name).font(.system(size: 12)).lineLimit(1).contextMenu { Button("Rescan") { library.scan(f) }; Button("Remove", role: .destructive) { library.removeFolder(f) } }
                }
                Button("Add music folder…") { pickFolder = true }.font(.system(size: 12))
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(Theme.panel)
    }
    func treeRows(_ parent: String?, _ depth: Int) -> [(Playlist, Int)] {
        playlists.children(parent).flatMap { p in [(p, depth)] + (p.folder ? treeRows(p.id, depth + 1) : []) }
    }
    func plRow(_ p: Playlist, _ depth: Int) -> some View {
        let cur = app.view == .playlist(p.id)
        return HStack {
            Image(systemName: p.folder ? "folder" : "list.bullet").foregroundStyle(Theme.muted)
            Text(p.name).lineLimit(1)
            Spacer()
            if !p.folder { Text("\(p.items.count)").font(Theme.mono).foregroundStyle(Theme.dim) }
        }
        .font(.system(size: 12)).padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture { if !p.folder { app.view = .playlist(p.id) } }
        .listRowBackground(cur ? Theme.raise : Theme.panel)
        .contextMenu {
            Button("Rename") { renaming = "pl:" + p.id; renameText = p.name }
            Menu("Move to") {
                Button("Top level") { playlists.moveList(p.id, into: nil) }
                ForEach(playlists.lists.filter { $0.folder && $0.id != p.id }) { f in Button(playlists.path(f)) { playlists.moveList(p.id, into: f.id) } }
            }
            Button("Delete", role: .destructive) { if app.view == .playlist(p.id) { app.view = .collection }; playlists.delete(p.id) }
        }
    }
    @ViewBuilder func deviceRows(_ d: Device) -> some View {
        HStack {
            Image(systemName: "externaldrive")
            Text(d.name + (d.saving ? " · saving…" : d.unsaved ? " · not saved" : "")).lineLimit(1)
            Spacer()
            Text("\(d.byRbId.count)").font(Theme.mono).foregroundStyle(Theme.dim)
        }
        .font(.system(size: 12)).contentShape(Rectangle()).onTapGesture { app.view = .device(d.id) }
        .listRowBackground(app.view == .device(d.id) ? Theme.raise : Theme.panel)
        .contextMenu {
            if devices.editable {
                Button("New playlist on \(d.name)") { let id = devices.newNode("Playlist \(d.tree.count + 1)", folder: false, in: d); renaming = "dev:\(d.id):\(id)"; renameText = "Playlist \(d.tree.count)" }
                Button("New folder on \(d.name)") { devices.newNode("Folder", folder: true, in: d) }
                if d.unsaved && !d.saving { Button("Try saving again") { devices.write(d) } }
            }
            Button("Close", role: .destructive) { devices.close(d) }
        }
        ForEach(devTree(d, 0, 1), id: \.0.id) { n, depth in
            let cur = app.view == .devicePlaylist(d.id, n.id)
            HStack {
                Image(systemName: n.folder ? "folder" : "list.bullet").foregroundStyle(Theme.muted)
                Text(n.name).lineLimit(1)
                Spacer()
                if !n.folder { Text("\(n.tracks.count)").font(Theme.mono).foregroundStyle(Theme.dim) }
            }
            .font(.system(size: 12)).padding(.leading, CGFloat(depth) * 12)
            .contentShape(Rectangle())
            .onTapGesture { if !n.folder { app.view = .devicePlaylist(d.id, n.id) } }
            .listRowBackground(cur ? Theme.raise : Theme.panel)
            .contextMenu {
                if !n.folder { Button("Copy to my playlists") { copy(n, d) } }
                if devices.editable {
                    Button("Rename") { renaming = "dev:\(d.id):\(n.id)"; renameText = n.name }
                    Button("Delete from \(d.name)", role: .destructive) { devices.delete(n.id, in: d) }
                }
            }
        }
    }
    func devTree(_ d: Device, _ parent: UInt32, _ depth: Int) -> [(PDBPlaylist, Int)] {
        d.tree.filter { $0.parent == parent }.sorted { $0.sort < $1.sort }.flatMap { n in [(n, depth)] + (n.folder ? devTree(d, n.id, depth + 1) : []) }
    }
    func copy(_ n: PDBPlaylist, _ d: Device) {
        let p = playlists.new(n.name)
        playlists.add(devices.tracks(of: n, in: d), to: p.id)
        app.status("Copied \"\(n.name)\" to your playlists. It plays from \(d.name) while that's plugged in.")
    }
    func commitRename() {
        guard let r = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty else { return }
        if r.hasPrefix("pl:") { playlists.rename(String(r.dropFirst(3)), name); return }
        let parts = r.split(separator: ":")
        if parts.count >= 3, let id = UInt32(parts.last!) {
            let dv = parts.dropFirst().dropLast().joined(separator: ":")
            if let d = devices.list.first(where: { $0.id == dv }) { devices.rename(id, name, in: d) }
        }
    }
}

extension Array {
    func stableSort(_ less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset) }.map { $0.element }
    }
}
