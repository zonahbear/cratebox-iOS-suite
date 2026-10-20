// rekordbox USB sticks and SD cards: picked in the Files app (the drive itself, the folder holding PIONEER).
// Their tracks join the library, their playlist tree shows under DEVICES, and a track loaded from one gets
// rekordbox's own grid, phrases and cues. Playlist editing is opt-in (Settings): changes are written into the
// stick's export.pdb with the same checks as the web app (backup first, checked before and after writing,
// refused if rekordbox wrote the stick since it was opened).
import Foundation
import Darwin
import CrateboxKit

final class Device: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    let root: URL
    @Published var tree: [PDBPlaylist]
    var byRbId = [UInt32: LibTrack]()
    var stamp: String
    var oneLibrary = false
    @Published var saving = false
    @Published var unsaved = false
    var backedUp = false, told = false
    var saveWork: DispatchWorkItem?
    init(id: String, name: String, root: URL, tree: [PDBPlaylist], stamp: String) { self.id = id; self.name = name; self.root = root; self.tree = tree; self.stamp = stamp }
    var pdbURL: URL { root.appendingPathComponent("PIONEER/rekordbox/export.pdb") }
}

final class Devices: ObservableObject {
    static let shared = Devices()
    weak var app: AppModel?
    @Published private(set) var list: [Device] = []
    @Published var editable = UserDefaults.standard.bool(forKey: "cb.rbEdit") { didSet { UserDefaults.standard.set(editable, forKey: "cb.rbEdit") } }

    /// the drive's own label ("DJ USB"), not the identifier iOS mounts it under ("3F2A-1B7C")
    static func label(_ root: URL) -> String {
        let v = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey, .isVolumeKey])
        let looksLikeId = root.lastPathComponent.range(of: "^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$|^[0-9A-Fa-f-]{16,}$", options: .regularExpression) != nil
        if v?.isVolume == true || looksLikeId, let n = v?.volumeLocalizedName ?? v?.volumeName, !n.isEmpty { return n }
        return looksLikeId ? "USB" : root.lastPathComponent
    }
    static func stamp(_ b: [UInt8]) -> String { b.count >= 24 ? "\(b.count):\(UInt32(b[20]) | UInt32(b[21]) << 8 | UInt32(b[22]) << 16 | UInt32(b[23]) << 24)" : "\(b.count)" }

    func restore() {
        guard let lib = app?.library else { return }
        for f in lib.folders where f.device { if let u = lib.url(of: f) { mount(u, folder: f) } }
        // sticks added as plain music folders (before the + USB fix): open them as rekordbox devices now
        for f in lib.folders where !f.device {
            if let u = lib.url(of: f), Library.isRekordboxExport(u) { lib.removeFolder(f); open(u) }
        }
    }

    func open(_ url: URL) {
        guard let lib = app?.library else { return }
        guard let f = lib.addFolder(url, device: true) else { return }
        mount(lib.url(of: f) ?? url, folder: f)
    }

    func mount(_ root: URL, folder: MusicFolder) {
        let pdb = root.appendingPathComponent("PIONEER/rekordbox/export.pdb")
        guard let data = try? Data(contentsOf: pdb) else {
            app?.status("\"\(Devices.label(root))\" doesn't look like a rekordbox USB/SD export (no PIONEER/rekordbox/export.pdb). Pick the drive itself.", 9)
            return
        }
        let bytes = [UInt8](data), db = PDB.parse(bytes)
        let id = folder.id
        list.removeAll { $0.id == id }
        let dev = Device(id: id, name: UserDefaults.standard.string(forKey: "cb.devName.\(id)") ?? Devices.label(root), root: root, tree: db.playlists, stamp: Devices.stamp(bytes))
        dev.oneLibrary = FileManager.default.fileExists(atPath: root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db").path)
        var tracks = [LibTrack]()
        for r in db.tracks {
            let tid = "\(id)|\(r.path)"
            let saved = app?.library.track(tid)
            let rec = saved?.rec ?? TrackRecord(id: tid, folder: id, rel: r.path, title: r.title.isEmpty ? r.filename : r.title, artist: r.artist, size: Int64(r.size), mtime: 0,
                                                 bpm: r.bpm > 0 ? r.bpm : nil, firstBeat: nil, key: RekordboxANLZ.keyIndex(r.key), duration: Double(r.duration),
                                                 phrases: [], gridManual: false, autoBpm: nil, autoFirst: nil, ver: 0)
            let t = LibTrack(rec)
            t.device = id; t.rb = r
            t.info.keyFromRekordbox = t.info.key >= 0
            dev.byRbId[r.id] = t
            tracks.append(t)
        }
        app?.library.setDeviceTracks(id, tracks)
        list.append(dev)
        app?.status("\(dev.name): \(db.tracks.count) tracks, \(db.playlists.filter { !$0.folder }.count) playlists")
    }
    /// a name for the stick in Cratebox only (the drive's own label is left alone)
    func nickname(_ d: Device, _ n: String) {
        let t = n.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { UserDefaults.standard.removeObject(forKey: "cb.devName.\(d.id)"); d.name = Devices.label(d.root) }
        else { UserDefaults.standard.set(t, forKey: "cb.devName.\(d.id)"); d.name = t }
        objectWillChange.send()
    }
    /// Eject: finish any playlist save, make sure it's on the stick itself (not just in iOS's cache), then let
    /// go of the drive. iOS has no eject of its own for USB drives; after this, unplugging is safe.
    func eject(_ d: Device) {
        if app?.core.decks.contains(where: { $0.track.map { t in d.byRbId.values.contains { $0.info === t } } ?? false }) == true {
            app?.status("A deck is playing from \(d.name): load something else (or stop and unload) first", 7); return
        }
        if d.unsaved && !d.saving { d.saveWork?.cancel(); write(d) }
        if d.saving || d.unsaved {
            app?.status("Finishing the save to \(d.name)…", 3)
            var tries = 0
            func again() {
                tries += 1
                if !d.saving && !d.unsaved { self.eject(d) }
                else if tries > 40 || (!d.saving && d.unsaved) { self.app?.status("Couldn't finish saving to \(d.name). Not ejected: it's not safe to unplug yet.", 10) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: again) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: again)
            return
        }
        // flush what Cratebox wrote to the drive itself
        for u in [d.pdbURL, d.pdbURL.deletingLastPathComponent().appendingPathComponent("export.pdb.cratebox-backup")] {
            if let h = try? FileHandle(forUpdating: u) { _ = fcntl(h.fileDescriptor, F_FULLFSYNC); try? h.synchronize(); try? h.close() }
        }
        let name = d.name
        list.removeAll { $0 === d }
        app?.library.setDeviceTracks(d.id, [])
        if let f = app?.library.folders.first(where: { $0.id == d.id }) { app?.library.removeFolder(f) }
        if case .device(let v) = app?.view, v == d.id { app?.view = .collection }
        if case .devicePlaylist(let v, _) = app?.view, v == d.id { app?.view = .collection }
        app?.status("\(name) ejected: safe to unplug. (Add it again with + USB.)", 8)
    }
    func close(_ d: Device) {
        if app?.core.decks.contains(where: { $0.track.map { t in d.byRbId.values.contains { $0.info === t } } ?? false }) == true { app?.status("Load something else on the decks first"); return }
        if d.saving || d.unsaved { app?.status(d.saving ? "Saving to \(d.name), one moment" : "\(d.name) has playlist changes that aren't saved", 7); return }
        list.removeAll { $0 === d }
        app?.library.setDeviceTracks(d.id, [])
        if let f = app?.library.folders.first(where: { $0.id == d.id }) { app?.library.removeFolder(f) }
    }
    func device(of t: LibTrack) -> Device? { list.first { $0.id == t.device } }
    func url(for t: LibTrack) -> URL? {
        guard let d = device(of: t), let r = t.rb else { return nil }
        return d.root.appendingPathComponent(String(r.path.drop { $0 == "/" }))
    }
    /// rekordbox's own analysis for a stick track: grid, phrases, hot cues and the first memory cue
    func readAnalysis(_ t: LibTrack) {
        guard let d = device(of: t), let r = t.rb, !r.anlzPath.isEmpty else { return }
        let datURL = d.root.appendingPathComponent(String(r.anlzPath.drop { $0 == "/" }))
        guard let dat = try? Data(contentsOf: datURL) else { return }
        let a = RekordboxANLZ.parse([UInt8](dat))
        guard let g = RekordboxANLZ.grid(a.beats) else { return }
        var ext = RekordboxANLZ.parse([UInt8]((try? Data(contentsOf: datURL.deletingPathExtension().appendingPathExtension("EXT"))) ?? Data()))
        ext.beats = a.beats
        if !t.info.gridManual { t.info.bpm = g.bpm; t.info.firstBeat = g.firstBeat; t.info.autoBpm = g.bpm; t.info.autoFirst = g.firstBeat }
        t.info.rbGrid = true
        // beat by beat only when rekordbox's grid actually changes tempo: an even grid is exact as BPM + first
        // beat (its stored beat times are just that, rounded to the millisecond)
        if Set(a.beats.map { $0.bpm }).count > 1 {
            t.info.rbBeats = a.beats.map { Double($0.ms) / 1000 }
            t.info.rbBeat0 = a.beats.firstIndex { $0.n == 1 } ?? 0
        } else { t.info.rbBeats = nil }
        if let ph = RekordboxANLZ.phrases(ext) { t.info.phrases = ph }
        let cueSrc = !ext.hot.isEmpty || !ext.memory.isEmpty ? ext : a
        t.info.rbCues = RekordboxANLZ.cues(cueSrc)
        t.rec.ver = Library.ANALYSIS_VER
    }

    // ---- editing a stick's playlists ----
    func tracks(of n: PDBPlaylist, in d: Device) -> [LibTrack] { n.tracks.compactMap { d.byRbId[$0] } }
    func edit(_ d: Device, _ change: (inout [PDBPlaylist]) -> Void) {
        guard editable else { app?.status("Turn on Settings → rekordbox USB playlists → Editable to change a stick's playlists", 7); return }
        change(&d.tree)
        d.unsaved = true
        d.saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.write(d) }
        d.saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }
    func add(_ tracks: [LibTrack], to id: UInt32, in d: Device) {
        let ok = tracks.filter { $0.device == d.id && $0.rb != nil }
        if ok.count < tracks.count { app?.status("Only tracks on \(d.name) can go in its playlists\(ok.isEmpty ? "" : ": added the \(ok.count) that are")", 7) }
        if ok.isEmpty { return }
        edit(d) { tree in if let k = tree.firstIndex(where: { $0.id == id }) { tree[k].tracks += ok.map { $0.rb!.id } } }
    }
    func remove(at positions: IndexSet, from id: UInt32, in d: Device) { edit(d) { tree in if let k = tree.firstIndex(where: { $0.id == id }) { tree[k].tracks.remove(atOffsets: positions) } } }
    func move(from: IndexSet, to: Int, in id: UInt32, of d: Device) { edit(d) { tree in if let k = tree.firstIndex(where: { $0.id == id }) { tree[k].tracks.move(fromOffsets: from, toOffset: to) } } }
    func rename(_ id: UInt32, _ name: String, in d: Device) { edit(d) { tree in if let k = tree.firstIndex(where: { $0.id == id }) { tree[k].name = name } } }
    func delete(_ id: UInt32, in d: Device) {
        edit(d) { tree in
            var kill: Set<UInt32> = [id], grew = true
            while grew { grew = false; for x in tree where x.parent != 0 && kill.contains(x.parent) && !kill.contains(x.id) { kill.insert(x.id); grew = true } }
            tree.removeAll { kill.contains($0.id) }
        }
    }
    /// move a playlist or folder into another folder (0 = the top level); never into itself or its own subfolders
    func moveNode(_ id: UInt32, into parent: UInt32, in d: Device) {
        var p = parent
        while p != 0 { if p == id { app?.status("Can't move a folder into itself"); return }; p = d.tree.first { $0.id == p }?.parent ?? 0 }
        let sort = (d.tree.filter { $0.parent == parent }.map { $0.sort }.max() ?? 0) + 1
        edit(d) { tree in if let k = tree.firstIndex(where: { $0.id == id }) { tree[k].parent = parent; tree[k].sort = sort } }
    }
    /// a copy of a playlist, next to it
    func duplicate(_ id: UInt32, in d: Device) {
        guard let n = d.tree.first(where: { $0.id == id }), !n.folder else { return }
        let nid = (d.tree.map { $0.id }.max() ?? 0) + 1
        let sort = (d.tree.filter { $0.parent == n.parent }.map { $0.sort }.max() ?? 0) + 1
        edit(d) { tree in var c = PDBPlaylist(id: nid, parent: n.parent, sort: sort, folder: false, name: n.name + " copy"); c.tracks = n.tracks; tree.append(c) }
    }
    @discardableResult func newNode(_ name: String, folder: Bool, parent: UInt32 = 0, in d: Device) -> UInt32 {
        let id = (d.tree.map { $0.id }.max() ?? 0) + 1
        let sort = (d.tree.filter { $0.parent == parent }.map { $0.sort }.max() ?? 0) + 1
        edit(d) { $0.append(PDBPlaylist(id: id, parent: parent, sort: sort, folder: folder, name: name)) }
        return id
    }
    func write(_ d: Device) {
        guard !d.saving else { d.saveWork?.cancel(); let w = DispatchWorkItem { [weak self] in self?.write(d) }; d.saveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w); return }
        d.saving = true
        let nodes = d.tree.enumerated().sorted { ($0.element.parent, $0.element.sort, $0.offset) < ($1.element.parent, $1.element.sort, $1.offset) }.map { e -> PDBPlaylist in
            var n = e.element; if n.folder { n.tracks = [] }; return n
        }
        let stamp = d.stamp, backedUp = d.backedUp, url = d.pdbURL
        DispatchQueue.global(qos: .userInitiated).async {
            var msg: String?, newStamp: String?
            do {
                let cur = [UInt8](try Data(contentsOf: url))
                if Devices.stamp(cur) != stamp { msg = "Not saved: \(d.name) changed since Cratebox opened it (rekordbox exported to it?). Close it and open it again, then redo the change." }
                else {
                    // keep the stick's database as it was when you started editing it this session
                    if !backedUp { try Data(cur).write(to: url.deletingLastPathComponent().appendingPathComponent("export.pdb.cratebox-backup"), options: .atomic) }
                    let out = try PDB.writePlaylists(cur, nodes)          // checks itself: throws rather than write anything wrong
                    try Data(out).write(to: url, options: .atomic)
                    let back = [UInt8](try Data(contentsOf: url))
                    if back != out { msg = "Saving to \(d.name) didn't stick (the file on it isn't what was written). The version from before is in PIONEER/rekordbox/export.pdb.cratebox-backup." }
                    else { newStamp = Devices.stamp(back) }
                }
            } catch { msg = "Not saved to \(d.name): \(error)" }
            DispatchQueue.main.async {
                d.saving = false
                if let s = newStamp {
                    d.stamp = s; d.backedUp = true; d.unsaved = false
                    if !d.told {
                        d.told = true
                        self.app?.status("Saved to \(d.name). Syncing these playlists from rekordbox again replaces the changes.\(d.oneLibrary ? " Newer players that read the stick's OneLibrary database won't see them (only the older export.pdb is updated)." : "")", 14)
                    } else { self.app?.status("Saved to \(d.name)") }
                } else { d.unsaved = true; self.app?.status(msg ?? "Not saved", 12) }
            }
        }
    }
}
