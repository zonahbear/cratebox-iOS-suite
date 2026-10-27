// Cratebox USB: the stick that's open, both its libraries, the preflight scan, your edits (kept as staged
// changes until they can go somewhere), and every write to the stick (through USBSafeWrite, and only the
// kinds USBWriteGate lets through).
import Foundation
import SwiftUI
import Darwin
import CrateboxKit

/// one memory cue or saved loop
struct USBMemoryCue: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var loopEnd: Double?
    var comment = ""
}
/// your changes to one track (nil = left as rekordbox has it)
struct USBTrackEdit: Codable, Equatable {
    var cue: Double?
    var hot: [Double?]?
    var memory: [USBMemoryCue]?
    var bpm: Double?, firstBeat: Double?
    var title: String?, artist: String?, album: String?, genre: String?, comment: String?, rating: Int?
    var isEmpty: Bool { self == USBTrackEdit() }
    var hasCues: Bool { cue != nil || hot != nil || memory != nil }
    var hasGrid: Bool { bpm != nil || firstBeat != nil }
    var hasMeta: Bool { title != nil || artist != nil || album != nil || genre != nil || comment != nil || rating != nil }
}
/// the playlist tree being edited: one node per playlist, both libraries' ids where they exist
struct USBNode: Identifiable, Equatable, Codable {
    var id: String                      // stable within the session
    var name: String
    var folder: Bool
    var parent: String?                 // nil = top level
    var tracks: [String]                // track keys
    var pdbId: UInt32?, olId: Int64?
}

final class USBSession: ObservableObject {
    weak var app: AppModel?
    let preview: USBPreview

    // ---- the stick ----
    @Published private(set) var root: URL?
    @Published private(set) var name = ""
    @Published private(set) var library: USBLibrary?
    @Published private(set) var fileSystem = ""
    @Published private(set) var loading = false
    @Published var message = "" // the last thing that happened, for the status line
    private(set) var pdbBytes: [UInt8]?, olBytes: [UInt8]?
    var stickId: String { root.map { "usb-" + $0.lastPathComponent } ?? "" }

    // ---- the scan ----
    @Published var players: [String] { didSet { UserDefaults.standard.set(players, forKey: "cb.usb.players") } }
    @Published var setPlaylist: String? { didSet { UserDefaults.standard.set(setPlaylist, forKey: "cb.usb.set.\(stickId)") } }
    @Published var mode: ScanMode = .standard
    @Published private(set) var report: ScanReport?
    @Published private(set) var scanning = false
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var scanText = ""
    @Published var skipped: Set<String> = [] { didSet { UserDefaults.standard.set(Array(skipped), forKey: "cb.usb.skipped.\(stickId)") } }
    @Published var fixList: [String] = []           // track keys to sort out in rekordbox
    private var cancelScan = false
    var readiness: Readiness {
        guard let r = report else { return .unknown }
        if r.pdbHash != pdbBytes.map(USBSafeWrite.hash) || r.olHash != olBytes.map(USBSafeWrite.hash) { return .unknown }   // the stick changed since
        // the scan was for other players or another set: it says nothing about these
        if Set(r.options.players) != Set(players) || r.options.setPlaylist != setPlaylist { return .unknown }
        return r.readiness(skipped: skipped)
    }
    func issues(for key: String) -> [ScanIssue] { report?.issues.filter { $0.trackKey == key && !skipped.contains($0.id) } ?? [] }

    // ---- edits ----
    @Published var nodes: [USBNode] = [] { didSet { saveStagedPlaylists() } }
    @Published private(set) var originalNodes: [USBNode] = []
    @Published var edits: [String: USBTrackEdit] = [:] { didSet { saveEdits() } }
    @Published private(set) var changeLog: [String] = []
    /// a staged tree edit, or a staged "make both libraries the same" (writing the tree does that)
    var playlistsChanged: Bool { nodes != originalNodes || syncPending }
    var editedTracks: [String] { edits.filter { !$0.value.isEmpty }.map { $0.key }.sorted() }

    // ---- writing ----
    @Published var proven: Set<USBWriteKind> { didSet { UserDefaults.standard.set(proven.map { $0.rawValue }, forKey: "cb.usb.proven") } }
    var gate: USBWriteGate { USBWriteGate(proven: proven) }
    @Published private(set) var writing = false
    @Published private(set) var ejected = false
    var safeToRemove: Bool { root == nil ? ejected : false }
    var playlistBlocker: String? {
        guard let l = library else { return "No stick open" }
        return gate.playlistWriteBlocker(deviceLibrary: l.hasDeviceLibrary, oneLibrary: l.hasOneLibrary)
    }

    init(app: AppModel) {
        self.app = app
        preview = USBPreview(audio: app.audio)
        players = UserDefaults.standard.stringArray(forKey: "cb.usb.players") ?? ["unknown"]
        proven = Set((UserDefaults.standard.stringArray(forKey: "cb.usb.proven") ?? []).compactMap(USBWriteKind.init))
        preview.session = self
    }

    private var reopened = false
    func setActive(_ on: Bool) {
        preview.setActive(on)
        if on && !reopened {
            reopened = true
            if CommandLine.arguments.contains("-usb") && CommandLine.arguments.contains("-demo") { demo(); return }
            if root == nil, let bm = UserDefaults.standard.data(forKey: "cb.usb.bookmark") {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: u.appendingPathComponent("PIONEER").path) {
                    open(u, remember: false)
                }
            }
        }
    }

    // ---- opening ----
    func open(_ url: URL, remember: Bool = true) {
        _ = url.startAccessingSecurityScopedResource()
        if remember, let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(bm, forKey: "cb.usb.bookmark") }
        if let r = root, r != url { r.stopAccessingSecurityScopedResource() }
        root = url; ejected = false
        name = Devices.label(url)
        let v = try? url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey, .volumeTypeNameKey])
        fileSystem = v?.volumeTypeName ?? v?.volumeLocalizedFormatDescription ?? ""
        skipped = Set(UserDefaults.standard.stringArray(forKey: "cb.usb.skipped.\(stickId)") ?? [])
        setPlaylist = UserDefaults.standard.string(forKey: "cb.usb.set.\(stickId)")
        loadEdits()
        // a save that was cut off last time comes first
        let rec = USBSafeWrite.recover(root: url)
        for r in rec {
            switch r {
            case .restored(let m), .cleanedUp(let m): note(m)
            case .needsAttention(let m): note("Needs attention: \(m)")
            case .nothing: break
            }
        }
        reload()
    }

    /// (re)read both libraries off the stick
    func reload(keepNodes: Bool = false) {
        guard let root else { return }
        loading = true
        let pdbURL = root.appendingPathComponent("PIONEER/rekordbox/export.pdb"), olURL = root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")
        DispatchQueue.global(qos: .userInitiated).async {
            let pdb = (try? Data(contentsOf: pdbURL)).map { [UInt8]($0) }
            let ol = (try? Data(contentsOf: olURL)).map { [UInt8]($0) }
            var one: OneLibraryDatabase?, oneErr: String?
            if let ol { do { one = try OneLibrary.read(ol) } catch { oneErr = "\(error)" } }
            var lib = USBLibrary(pdb: pdb.map(PDB.parse), one: one, oneError: oneErr)
            if let pdb { lib.setFormats(PDB.trackFormats(pdb)) }
            DispatchQueue.main.async {
                guard self.root == root else { return }      // ejected (or another stick opened) while reading
                self.pdbBytes = pdb; self.olBytes = ol
                self.library = lib
                self.loading = false
                let fresh = USBSession.nodes(from: lib)
                self.originalNodes = fresh
                if !keepNodes || self.nodes.isEmpty { self.restoringPlaylists = true; self.nodes = fresh; self.restoringPlaylists = false; self.restoreStagedPlaylists() }
                else { self.saveStagedPlaylists() }          // kept: they now go with this version of the libraries
                if self.setPlaylist != nil && lib.playlist(self.setPlaylist!) == nil { self.setPlaylist = nil }
                if pdb == nil && ol == nil { self.note("\(self.name) has no rekordbox library (no PIONEER/rekordbox/export.pdb or exportLibrary.db)") }
                else { self.note("\(self.name): \(lib.tracks.count) tracks, \(lib.playlists.filter { !$0.folder }.count) playlists · \(lib.hasDeviceLibrary ? "Device Library" : "")\(lib.hasDeviceLibrary && lib.hasOneLibrary ? " + " : "")\(lib.hasOneLibrary ? "OneLibrary" : "")\(oneErr != nil ? " (OneLibrary unreadable)" : "")") }
            }
        }
    }
    static func nodes(from lib: USBLibrary) -> [USBNode] {
        lib.playlists.map { p in
            USBNode(id: p.id, name: p.name, folder: p.folder, parent: p.treePath.count > 1 ? p.treePath.dropLast().joined(separator: "\u{1f}") : nil,
                    tracks: p.tracks, pdbId: p.pdbId, olId: p.olId)
        }
    }
    func note(_ s: String) { message = s; app?.status(s, 8) }

    // ---- scanning ----
    func scan(_ m: ScanMode? = nil) {
        guard let lib = library, let root, !scanning else { return }
        let opts = ScanOptions(mode: m ?? mode, players: players, setPlaylist: setPlaylist, fileSystem: fileSystem)
        scanning = true; cancelScan = false; scanProgress = 0; scanText = "Starting…"
        let pdb = pdbBytes, ol = olBytes
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Preflight.run(lib, root: root, options: opts, pdbBytes: pdb, olBytes: ol,
                                  progress: { p, t in DispatchQueue.main.async { self.scanProgress = p; self.scanText = t } },
                                  cancelled: { self.cancelScan },
                                  decode: opts.mode == .deep ? USBPreview.decodeCheck : nil)
            DispatchQueue.main.async {
                self.scanning = false
                guard self.root == root else { return }      // ejected mid-scan: the result is for a stick that's gone
                self.report = r
                self.note("\(opts.mode.title) scan: \(r.tracksChecked) tracks · \(self.readiness.label)")
            }
        }
    }
    func stopScan() { cancelScan = true }

    // ---- quick fixes ----
    /// the fixes that can be run in one go, with how many issues each covers
    struct QuickFixGroup: Identifiable { let fix: QuickFix; let count: Int; var id: String { fix.rawValue } }
    var quickFixes: [QuickFixGroup] {
        guard let r = report else { return [] }
        let open = r.issues.filter { !skipped.contains($0.id) }
        var out = [QuickFixGroup]()
        for f in [QuickFix.recoverWrite, .restoreBackup, .removeFromPlaylists, .syncPlaylists, .exportFixList] {
            let n = open.filter { $0.fix == f }.count
            if n > 0 { out.append(QuickFixGroup(fix: f, count: n)) }
        }
        let info = open.filter { $0.severity == .info }.count
        if info > 0 { out.append(QuickFixGroup(fix: .skip, count: info)) }
        return out
    }
    func runQuickFix(_ f: QuickFix) {
        guard let r = report else { return }
        let open = r.issues.filter { !skipped.contains($0.id) }
        if f == .skip { for i in open where i.severity == .info { skipped.insert(i.id) }; return }
        for i in open where i.fix == f { fix(i, batch: true) }
        finishBatch(f)
    }
    private var batchNotes = [String]()
    private func finishBatch(_ f: QuickFix) {
        if f == .removeFromPlaylists || f == .syncPlaylists { stagedPlaylistsNote() }
        if f == .exportFixList { note("\(fixList.count) track\(fixList.count == 1 ? "" : "s") on the fix list (Staged → Share fix list)") }
    }
    private func stagedPlaylistsNote() {
        if let b = playlistBlocker { note("Staged. \(b)") } else { note("Staged: Staged changes → Write to stick when you're ready") }
    }
    /// one issue's fix
    func fix(_ i: ScanIssue, batch: Bool = false) {
        switch i.fix {
        case .recoverWrite?:
            guard let root else { return }
            for r in USBSafeWrite.recover(root: root) { if case .restored(let m) = r { note(m) } else if case .cleanedUp(let m) = r { note(m) } else if case .needsAttention(let m) = r { note(m) } }
            reload(); skipped.insert(i.id)
        case .restoreBackup?:
            restoreBackup(i.id.contains("ol") ? "PIONEER/rekordbox/exportLibrary.db" : "PIONEER/rekordbox/export.pdb")
        case .removeFromPlaylists?:
            if let k = i.trackKey { removeEverywhere(k) }
            skipped.insert(i.id)
            if !batch { stagedPlaylistsNote() }
        case .syncPlaylists?:
            // the tree being edited is already one tree for both libraries: writing it makes them agree
            markAllForSync()
            skipped.insert(i.id)
            if !batch { stagedPlaylistsNote() }
        case .exportFixList?:
            if let k = i.trackKey, !fixList.contains(k) { fixList.append(k) }
            skipped.insert(i.id)
            if !batch { note("Added to the fix list") }
        case .skip?:
            skipped.insert(i.id)
        case .reexport?, nil:
            note("Only rekordbox can fix this: \(i.detail)")
        }
    }
    func skip(_ i: ScanIssue) { skipped.insert(i.id) }
    func unskipAll() { skipped = [] }

    @Published private var syncPending = false { didSet { saveStagedPlaylists() } }
    func markAllForSync() { syncPending = true; log("Make both libraries' playlists the same") }

    // ---- playlist editing (staged) ----
    func log(_ s: String) { changeLog.append(s) }
    func children(_ parent: String?) -> [USBNode] { nodes.filter { $0.parent == parent } }
    func node(_ id: String) -> USBNode? { nodes.first { $0.id == id } }
    func newNode(_ name: String, folder: Bool, parent: String? = nil) {
        let id = "new-\(UUID().uuidString.prefix(8))"
        let at = nodes.lastIndex { $0.parent == parent }.map { $0 + 1 } ?? nodes.count
        nodes.insert(USBNode(id: id, name: name, folder: folder, parent: parent, tracks: []), at: at)
        log("New \(folder ? "folder" : "playlist") \"\(name)\"")
    }
    func rename(_ id: String, _ name: String) {
        guard let k = nodes.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        log("Rename \"\(nodes[k].name)\" → \"\(name)\""); nodes[k].name = name
    }
    func delete(_ id: String) {
        var kill: Set<String> = [id], grew = true
        while grew { grew = false; for n in nodes where n.parent != nil && kill.contains(n.parent!) && !kill.contains(n.id) { kill.insert(n.id); grew = true } }
        log("Delete \"\(node(id)?.name ?? "")\"\(kill.count > 1 ? " and what's in it" : "")")
        nodes.removeAll { kill.contains($0.id) }
        if let s = setPlaylist, kill.contains(s) { setPlaylist = nil }
    }
    func moveTracks(in id: String, from: IndexSet, to: Int) {
        guard let k = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[k].tracks.move(fromOffsets: from, toOffset: to); log("Reorder \"\(nodes[k].name)\"")
    }
    func removeTracks(in id: String, at: IndexSet) {
        guard let k = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[k].tracks.remove(atOffsets: at); log("Remove \(at.count) from \"\(nodes[k].name)\"")
    }
    func add(_ keys: [String], to id: String) {
        guard let k = nodes.firstIndex(where: { $0.id == id }), !nodes[k].folder else { return }
        nodes[k].tracks += keys; log("Add \(keys.count) to \"\(nodes[k].name)\"")
    }
    /// siblings in a new order
    func moveNodes(parent: String?, from: IndexSet, to: Int) {
        var sib = children(parent)
        sib.move(fromOffsets: from, toOffset: to)
        let others = nodes.filter { $0.parent != parent }
        // keep each sibling group together, in the order the tree walks it
        nodes = others + sib
        nodes = USBSession.treeOrder(nodes)
        log("Reorder playlists")
    }
    func removeEverywhere(_ key: String) {
        var n = 0
        for k in nodes.indices where nodes[k].tracks.contains(key) { nodes[k].tracks.removeAll { $0 == key }; n += 1 }
        if n > 0 { log("Take \(library?.track(key)?.fileName ?? key) out of \(n) playlist\(n == 1 ? "" : "s")") }
    }
    static func treeOrder(_ ns: [USBNode]) -> [USBNode] {
        var out = [USBNode]()
        func walk(_ p: String?) { for n in ns where n.parent == p { out.append(n); if n.folder { walk(n.id) } } }
        walk(nil)
        return out
    }
    func discardPlaylistChanges() { nodes = originalNodes; syncPending = false; changeLog.removeAll { !$0.hasPrefix("Edit ") }; note("Playlist changes discarded") }

    // ---- track edits (cues, grid, info) ----
    func edit(_ key: String, _ change: (inout USBTrackEdit) -> Void) {
        var e = edits[key] ?? USBTrackEdit()
        change(&e)
        edits[key] = e.isEmpty ? nil : e
    }
    func revert(_ key: String) { edits[key] = nil; log("Revert \(library?.track(key)?.fileName ?? key)") }
    /// rekordbox's own memory cues per track (read when a track is loaded)
    @Published var rbMemory: [String: [USBMemoryCue]] = [:]
    func memoryCues(_ key: String) -> [USBMemoryCue] { edits[key]?.memory ?? rbMemory[key] ?? [] }
    func addMemory(_ key: String, time: Double, loopEnd: Double? = nil) {
        var m = memoryCues(key)
        m.append(USBMemoryCue(time: time, loopEnd: loopEnd))
        m.sort { $0.time < $1.time }
        edit(key) { $0.memory = m }
        log("Edit \(library?.track(key)?.fileName ?? key): \(loopEnd == nil ? "memory cue" : "saved loop") at \(String(format: "%.2f", time)) s")
    }
    func deleteMemory(_ key: String, _ id: UUID) {
        let m = memoryCues(key).filter { $0.id != id }
        edit(key) { $0.memory = m }
    }
    private var editsURL: URL? {
        guard !stickId.isEmpty else { return nil }
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cratebox/usb", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(stickId.replacingOccurrences(of: "/", with: "_") + ".edits.json")
    }
    private var loadingEdits = false

    // staged playlist changes outlive an eject or a restart, for the export they were made on
    private struct StagedPlaylists: Codable { var pdbHash: String?, olHash: String?, nodes: [USBNode], sync: Bool }
    private var stagedURL: URL? { editsURL.map { $0.deletingPathExtension().deletingPathExtension().appendingPathExtension("playlists.json") } }
    private var restoringPlaylists = false
    private func saveStagedPlaylists() {
        guard !restoringPlaylists, library != nil, let u = stagedURL else { return }
        if nodes == originalNodes && !syncPending { try? FileManager.default.removeItem(at: u); return }
        let st = StagedPlaylists(pdbHash: pdbBytes.map(USBSafeWrite.hash), olHash: olBytes.map(USBSafeWrite.hash), nodes: nodes, sync: syncPending)
        try? JSONEncoder().encode(st).write(to: u)
    }
    private func clearStagedPlaylists() { if let u = stagedURL { try? FileManager.default.removeItem(at: u) } }
    private func restoreStagedPlaylists() {
        guard let u = stagedURL, let d = try? Data(contentsOf: u), let st = try? JSONDecoder().decode(StagedPlaylists.self, from: d) else { return }
        if st.pdbHash != pdbBytes.map(USBSafeWrite.hash) || st.olHash != olBytes.map(USBSafeWrite.hash) {
            try? FileManager.default.removeItem(at: u)
            note("Staged playlist changes from last time were dropped: the stick's libraries changed since they were made"); return
        }
        restoringPlaylists = true
        nodes = st.nodes; syncPending = st.sync
        restoringPlaylists = false
        if playlistsChanged { note("Staged playlist changes from last time are back (Staged changes)") }
    }
    private func saveEdits() { if !loadingEdits, let u = editsURL { try? JSONEncoder().encode(edits).write(to: u) } }
    private func loadEdits() {
        loadingEdits = true
        edits = editsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: USBTrackEdit].self, from: $0) } ?? [:]
        loadingEdits = false
    }

    // ---- where edits can go ----
    /// cues and grids into Cratebox's own library, so Performance Mode plays the stick with them
    func applyToPerformance() {
        guard let lib = library else { return }
        var cues = 0, grids = 0
        for (key, e) in edits where !e.isEmpty {
            guard let t = lib.track(key) else { continue }
            let id = "\(stickId)|\(t.path)"
            if e.hasCues {
                let cur = UserCueStore().load(id)
                UserCueStore().save(id, cue: e.cue ?? e.memory?.first?.time ?? cur?.cue, hot: e.hot ?? cur?.hot ?? [Double?](repeating: nil, count: 8))
                cues += 1
            }
            if e.hasGrid, let lt = app?.library.track(id) {
                if let b = e.bpm { lt.info.bpm = b }
                if let f = e.firstBeat { lt.info.firstBeat = f }
                lt.info.gridManual = true
                app?.library.changed(lt); grids += 1
            }
        }
        note("Performance Mode now uses your cues for \(cues) track\(cues == 1 ? "" : "s")\(grids > 0 ? " and your grids for \(grids)" : "")\(edits.values.contains { $0.hasGrid } && grids == 0 ? " (grids apply once the stick is open in Performance Mode: + USB)" : "")")
    }

    /// rekordbox XML with your edits (cues, grid, info) and the playlists as they are now: rekordbox can show it
    /// beside its collection (Preferences → Advanced → rekordbox xml)
    func exportXML(base: String) -> URL? {
        guard let lib = library else { return nil }
        let used = Set(nodes.flatMap { $0.tracks }).union(edits.keys)
        let ts = lib.tracks.filter { used.contains($0.key) }.map { t -> RekordboxXML.ExportTrack in
            let e = edits[t.key] ?? USBTrackEdit()
            return RekordboxXML.ExportTrack(id: t.key, title: e.title ?? t.title, artist: e.artist ?? t.artist, file: t.fileName,
                                            rel: String(t.path.drop { $0 == "/" }), size: Int(t.fileSize), duration: t.duration, bpm: e.bpm ?? t.bpm,
                                            firstBeat: e.firstBeat, key: RekordboxANLZ.keyIndex(t.keyName), cue: e.cue, hot: e.hot ?? [])
        }
        var order = [String: Int]()
        let ls = nodes.map { n -> RekordboxXML.ExportList in
            let o = order[n.parent ?? "", default: 0]; order[n.parent ?? ""] = o + 1
            return RekordboxXML.ExportList(id: n.id, name: n.name, folder: n.folder, parent: n.parent, order: o, items: n.tracks)
        }
        let s = RekordboxXML.export(ts, ls, root: base)
        let u = Recorder.folder.appendingPathComponent("\(name) (Cratebox USB).xml")
        do { try s.write(to: u, atomically: true, encoding: .utf8); return u } catch { note("Couldn't write the XML: \(error.localizedDescription)"); return nil }
    }
    func exportFixListFile() -> URL? {
        guard let lib = library else { return nil }
        var lines = ["# Cratebox USB fix list for \(name): sort these out in rekordbox, then export again", "path,title,artist,why"]
        for k in fixList {
            guard let t = lib.track(k) else { continue }
            let why = report?.issues.filter { $0.trackKey == k }.map { $0.title.components(separatedBy: ":").first ?? $0.title }.joined(separator: "; ") ?? ""
            lines.append([t.path, t.title, t.artist, why].map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        let u = Recorder.folder.appendingPathComponent("\(name) fix list.csv")
        do { try lines.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8); return u } catch { note("\(error.localizedDescription)"); return nil }
    }

    // ---- writing to the stick ----
    /// the playlist tree as Device Library rows (nil + why, if a track isn't in that library)
    func pdbNodes() -> (nodes: [PDBPlaylist]?, why: String?) {
        guard let lib = library, let p = lib.pdb else { return (nil, "no Device Library") }
        var nextId = (p.playlists.map { $0.id }.max() ?? 0) + 1
        var idOf = [String: UInt32]()
        for n in nodes { if let i = n.pdbId { idOf[n.id] = i } else { idOf[n.id] = nextId; nextId += 1 } }
        var out = [PDBPlaylist]()
        for n in USBSession.treeOrder(nodes) {
            var tr = [UInt32]()
            for k in n.tracks { guard let t = lib.track(k)?.pdbId else { return (nil, "\(lib.track(k)?.fileName ?? k) isn't in the Device Library") }; tr.append(t) }
            let unk = p.playlists.first { $0.id == n.pdbId }?.unk ?? 0
            out.append(PDBPlaylist(id: idOf[n.id]!, parent: n.parent.flatMap { idOf[$0] } ?? 0, unk: unk, folder: n.folder, name: n.name, tracks: n.folder ? [] : tr))
        }
        return (out, nil)
    }
    func olNodes() -> (nodes: [OLPlaylist]?, why: String?) {
        guard let lib = library, let o = lib.one else { return (nil, "no OneLibrary") }
        var nextId = (o.playlists.map { $0.id }.max() ?? 0) + 1
        var idOf = [String: Int64]()
        for n in nodes { if let i = n.olId { idOf[n.id] = i } else { idOf[n.id] = nextId; nextId += 1 } }
        var out = [OLPlaylist]()
        for n in USBSession.treeOrder(nodes) {
            var tr = [Int64]()
            for k in n.tracks { guard let t = lib.track(k)?.olId else { return (nil, "\(lib.track(k)?.fileName ?? k) isn't in OneLibrary") }; tr.append(t) }
            let attr = o.playlists.first { $0.id == n.olId }?.attribute ?? (n.folder ? 1 : 0)
            out.append(OLPlaylist(id: idOf[n.id]!, parent: n.parent.flatMap { idOf[$0] } ?? 0, seq: 0, folder: n.folder, name: n.name, tracks: n.folder ? [] : tr, attribute: attr))
        }
        return (out, nil)
    }

    /// Writes the playlist tree to every library on the stick: Device Library first, then OneLibrary; if the
    /// second fails, the first is put back. Each file has its own journal, so if the app is stopped between the
    /// two, recovery puts each file right on its own (not as a pair): the libraries can then differ until the
    /// next write.
    func writePlaylists() {
        guard let root, let lib = library, !writing else { return }
        if let b = playlistBlocker { note(b); return }
        let pn = lib.hasDeviceLibrary ? pdbNodes() : (nodes: nil, why: nil)
        let on = lib.hasOneLibrary ? olNodes() : (nodes: nil, why: nil)
        if let w = pn.why ?? on.why { note("Can't write: \(w). Remove it from the playlists, or re-export from rekordbox."); return }
        let pdb = pdbBytes, ol = olBytes
        writing = true
        let appBackups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cratebox/usb-backups/\(stickId)")
        DispatchQueue.global(qos: .userInitiated).async {
            var msg = ""
            var wrotePdb = false
            do {
                if let nodes = pn.nodes, let cur = pdb {
                    let out = try PDB.writePlaylists(cur, nodes)
                    try USBSafeWrite.write(out, root: root, rel: "PIONEER/rekordbox/export.pdb", expectedHash: USBSafeWrite.hash(cur), appBackupDir: appBackups) { b in
                        let back = PDB.parse(b)
                        if back.playlists.count != nodes.count { throw PDBError.readBack("playlists didn't read back") }
                        if !PDB.problems(b).isEmpty { throw PDBError.readBack(PDB.problems(b)[0]) }
                    }
                    wrotePdb = true
                }
                if let nodes = on.nodes, let cur = ol {
                    let out = try OneLibrary.writePlaylists(cur, nodes)
                    try USBSafeWrite.write(out, root: root, rel: "PIONEER/rekordbox/exportLibrary.db", expectedHash: USBSafeWrite.hash(cur), appBackupDir: appBackups) { b in
                        let back = try OneLibrary.read(b)
                        if back.integrity != ["ok"] { throw OneLibraryError.readBack("integrity") }
                    }
                }
                msg = "Saved the playlists to \(lib.hasDeviceLibrary && lib.hasOneLibrary ? "both libraries" : lib.hasOneLibrary ? "OneLibrary" : "the Device Library") on the stick. Backups are in PIONEER/rekordbox/.cratebox."
            } catch {
                msg = "Not saved: \(error)"
                // all or nothing: the Device Library goes back if OneLibrary couldn't follow
                if wrotePdb, let cur = pdb, let now = try? [UInt8](Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/export.pdb"))) {
                    do { try USBSafeWrite.write(cur, root: root, rel: "PIONEER/rekordbox/export.pdb", expectedHash: USBSafeWrite.hash(now), appBackupDir: appBackups) { _ in }; msg += " The Device Library was put back as it was." }
                    catch { msg += " Putting the Device Library back failed too (\(error)): restore it from the backup in Cratebox USB." }
                }
            }
            DispatchQueue.main.async {
                self.writing = false
                self.note(msg)
                if msg.hasPrefix("Saved") { self.changeLog.removeAll { !$0.hasPrefix("Edit ") }; self.syncPending = false; self.clearStagedPlaylists(); self.reload() }
            }
        }
    }

    // ---- cues, grid and track info ----
    /// the edits as the Kit's writer takes them
    func trackChanges() -> [String: USBTrackChanges] {
        var out = [String: USBTrackChanges]()
        for (k, e) in edits where !e.isEmpty {
            out[k] = USBTrackChanges(cue: e.cue, hot: e.hot.map { slots in slots.map { t in t.map { USBCue(time: $0) } } },
                                     memory: e.memory?.map { USBCue(time: $0.time, loopEnd: $0.loopEnd, comment: $0.comment) },
                                     bpm: e.bpm, firstBeat: e.firstBeat, title: e.title, artist: e.artist, album: e.album, genre: e.genre, comment: e.comment, rating: e.rating)
        }
        return out
    }
    /// nil when the edits can be written; otherwise why not
    var trackEditBlocker: String? {
        guard library != nil else { return "No stick open" }
        let needs = trackChanges().values.reduce(Set<USBWriteKind>()) { $0.union($1.kinds) }
        let locked = USBWriteKind.allCases.filter { needs.contains($0) && !gate.allowed($0) }
        if locked.isEmpty { return nil }
        let names: [USBWriteKind: String] = [.cues: "cues", .beatgrid: "beat grids", .metadata: "track info"]
        let what = locked.compactMap { names[$0] }.joined(separator: ", ")
        return "Writing \(what) isn't proven on hardware yet, so it's locked (Proving Ground in settings). Your edits are kept as staged changes."
    }
    /// Writes every track edit to the stick through USBTrackWriter: all the files, or none.
    func writeTrackEdits() {
        guard let root, let lib = library, !writing else { return }
        if let b = trackEditBlocker { note(b); return }
        let changes = trackChanges(), gate = self.gate, pdb = pdbBytes, ol = olBytes
        if changes.isEmpty { return }
        writing = true
        let appBackups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cratebox/usb-backups/\(stickId)")
        DispatchQueue.global(qos: .userInitiated).async {
            var msg = "", written = [String]()
            do {
                let plan = try USBTrackWriter.plan(lib, root: root, changes: changes, gate: gate, pdbBytes: pdb, olBytes: ol)
                try USBTrackWriter.apply(plan, root: root, appBackupDir: appBackups)
                written = plan.tracks
                msg = "Saved edits to \(plan.tracks.count) track\(plan.tracks.count == 1 ? "" : "s") (\(plan.files.count) files) on the stick. Backups are in PIONEER/rekordbox/.cratebox."
            } catch { msg = "Not saved: \(error)" }
            DispatchQueue.main.async {
                self.writing = false
                self.note(msg)
                if !written.isEmpty {
                    for k in written { self.edits[k] = nil }
                    self.changeLog.removeAll { $0.hasPrefix("Edit ") }
                    self.reload(keepNodes: true)
                }
            }
        }
    }

    func restoreBackup(_ rel: String) {
        guard let root, let b = USBSafeWrite.latestBackup(root: root, rel: rel), let bytes = try? [UInt8](Data(contentsOf: b)) else { note("No Cratebox backup of \(rel) on this stick"); return }
        let cur = (try? [UInt8](Data(contentsOf: root.appendingPathComponent(rel)))) ?? []
        writing = true
        DispatchQueue.global(qos: .userInitiated).async {
            var msg = ""
            do {
                try USBSafeWrite.write(bytes, root: root, rel: rel, expectedHash: USBSafeWrite.hash(cur), appBackupDir: nil) { _ in }
                msg = "Restored \((rel as NSString).lastPathComponent) from \(b.lastPathComponent)"
            } catch { msg = "Couldn't restore: \(error)" }
            DispatchQueue.main.async { self.writing = false; self.note(msg); self.reload() }
        }
    }

    // ---- eject ----
    func eject() {
        guard let root else { return }
        if writing { note("Still writing to \(name): one moment"); return }
        if scanning { stopScan() }
        preview.unload()
        // Performance Mode may have the same stick open
        if let d = Devices.shared.list.first(where: { $0.root.standardizedFileURL == root.standardizedFileURL }) {
            Devices.shared.eject(d)
            if Devices.shared.list.contains(where: { $0 === d }) { note("Performance Mode is still using \(name) (a deck is playing from it). Not ejected."); return }
        }
        for rel in ["PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportLibrary.db"] {
            let u = root.appendingPathComponent(rel)
            if let h = try? FileHandle(forUpdating: u) { _ = fcntl(h.fileDescriptor, F_FULLFSYNC); try? h.synchronize(); try? h.close() }
        }
        root.stopAccessingSecurityScopedResource()
        let n = name
        self.root = nil; library = nil; report = nil; pdbBytes = nil; olBytes = nil; nodes = []; originalNodes = []; syncPending = false
        UserDefaults.standard.removeObject(forKey: "cb.usb.bookmark")
        ejected = true
        note("\(n) ejected: safe to unplug")
    }

    // ---- simulator screenshots ----
    private func demo() {
        // CI copies the test stick (tests/fixtures/rekordbox_usb, no audio) into Documents/DemoUSB first
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoUSB")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("PIONEER").path) else { note("Demo: no DemoUSB in Documents"); return }
        players = ["cdj3000", "cdj2000nxs2"]
        mode = .standard
        open(dir, remember: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let first = self.library?.playlists.first(where: { !$0.folder }) { self.setPlaylist = first.id }
            self.scan(.standard)
        }
    }
}
