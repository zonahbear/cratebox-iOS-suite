// USB → this iPhone/iPad: copies tracks from a rekordbox stick into the app's own storage, so they play without the
// stick. All of a stick (also "Sync"), one playlist (or a folder of them), or the tracks you pick. Never deletes, never
// writes to the stick, never copies a track twice: a track whose file name and size are already in the library is
// skipped (the Linux app's usbcopy.rs uses the same twin rule). Copies keep rekordbox's title, artist, grid and key.
// The copying runs on a background queue at utility priority; the decks hold their tracks in memory, so it never
// touches playback. Main thread for everything else.
import Foundation
import CrateboxKit

final class UsbCopy: ObservableObject {
    static let shared = UsbCopy()
    /// the stick being copied from (eject waits for it), nil when idle
    @Published private(set) var busy: String?
    @Published private(set) var progress = ""
    private var cancelled = false

    /// where copies go: Documents/From USB/<stick name>/<the path on the stick>. One library folder holds every stick's copies.
    static let folderId = "dir-From USB"
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("From USB", isDirectory: true)
    }

    /// what one stick track becomes on the device (gathered on the main thread: the device list lives there)
    private struct Job { let src: URL; let anlz: URL?; let rel: String; let name: String; let size: Int64; let base: TrackRecord }

    /// the stick tracks that aren't on the device yet (by file name and size)
    func missing(_ d: Device, in lib: Library) -> [LibTrack] {
        let have = Self.liveTwins(lib)
        return d.byRbId.values.filter { t in
            guard let r = t.rb else { return false }
            return have[Library.twinKey(r.filename.isEmpty ? (r.path as NSString).lastPathComponent : r.filename, Int64(r.size))] == nil
        }
    }

    func cancel() { cancelled = true }

    /// Copies `tracks` (all from stick `d`) to the device. `playlist`: also make a playlist of that name in your own
    /// playlists, in the stick's order, from the copies (or the copy that was already here).
    func copy(_ tracks: [LibTrack], from d: Device, app: AppModel, playlist: String? = nil) {
        if let b = busy { app.status(b == d.id ? "Already copying from \(d.name)" : "Copying from another USB; one at a time", 5); return }
        let lib = app.library
        let folder = localFolder(lib)
        guard let folder, let dest = lib.url(of: folder) else { app.status("Couldn't make the From USB folder on this device", 7); return }
        let have = Self.liveTwins(lib)
        let stick = Self.safe(d.name)
        var jobs = [Job](), already = [String: LibTrack](), order = [String]()
        for t in tracks {
            guard t.device == d.id, let r = t.rb, let src = Devices.shared.url(for: t) else { continue }
            let file = r.filename.isEmpty ? (r.path as NSString).lastPathComponent : r.filename
            let key = Library.twinKey(file, Int64(r.size))
            order.append(key)
            if let x = have[key] { already[key] = x; continue }
            if jobs.contains(where: { Library.twinKey($0.name, $0.size) == key }) { continue }
            let rel = stick + "/" + String(r.path.drop { $0 == "/" })
            var base = t.rec
            base.id = "\(folder.id)|\(rel)|\(r.size)"; base.folder = folder.id; base.rel = rel; base.size = Int64(r.size); base.mtime = Date().timeIntervalSince1970
            base.title = t.info.title; base.artist = t.info.artist
            jobs.append(Job(src: src, anlz: Devices.shared.anlzURL(t), rel: rel, name: file, size: Int64(r.size), base: base))
        }
        if jobs.isEmpty {
            if let playlist { makePlaylist(playlist, order, already, [:], app) }
            app.status(tracks.isEmpty ? "Nothing to copy" : "Already on this device: \(already.count) track\(already.count == 1 ? "" : "s"), nothing copied", 6)
            return
        }
        let need = jobs.reduce(Int64(0)) { $0 + $1.size }
        if let free = (try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, free < need + 200_000_000 {
            app.status("Not enough space: \(Self.mb(need)) to copy, \(Self.mb(max(0, free))) free on this device", 9)
            return
        }
        busy = d.id; cancelled = false
        let n = jobs.count, name = d.name
        progress = "Copying 0 of \(n) from \(name)…"
        DispatchQueue.global(qos: .utility).async {
            var done = [TrackRecord](), failed = 0
            let fm = FileManager.default
            for (i, j) in jobs.enumerated() {
                if self.cancelled { break }
                let to = dest.appendingPathComponent(j.rel)
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let size = (try? fm.attributesOfItem(atPath: to.path))?[.size] as? Int64
                    if size != j.size {
                        // copy beside it, then move into place: an unplugged stick never leaves half a file under the real name
                        let part = to.appendingPathExtension("part")
                        try? fm.removeItem(at: part)
                        try fm.copyItem(at: j.src, to: part)
                        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }      // a different-size leftover of our own
                        try fm.moveItem(at: part, to: to)
                    }
                    var r = j.base
                    // rekordbox's grid and phrases from the stick's analysis file, so the copy plays with the same grid
                    if let a = j.anlz, let x = Devices.readAnalysis(at: a), x.bpm > 0 {
                        r.bpm = x.bpm; r.firstBeat = x.firstBeat; r.autoBpm = x.bpm; r.autoFirst = x.firstBeat
                        if let ph = x.phrases { r.phrases = ph }
                        r.ver = Library.ANALYSIS_VER; r.rbGrid = true
                    } else { r.rbGrid = false; if (r.bpm ?? 0) <= 0 || r.firstBeat == nil { r.ver = 0 } }
                    done.append(r)
                } catch { failed += 1 }
                DispatchQueue.main.async { self.progress = "Copying \(i + 1) of \(n) from \(name)…" }
            }
            let stopped = self.cancelled
            DispatchQueue.main.async {
                let added = lib.addCopied(done)
                var copied = [String: LibTrack]()
                for t in added { copied[Library.twinKey((t.rec.rel as NSString).lastPathComponent, t.rec.size)] = t }
                if let playlist { self.makePlaylist(playlist, order, already, copied, app) }
                self.busy = nil; self.progress = ""
                var msg = "\(stopped ? "Stopped: copied" : "Copied") \(added.count) track\(added.count == 1 ? "" : "s") from \(name) to this device"
                if !already.isEmpty { msg += ", \(already.count) already here" }
                if failed > 0 { msg += ", \(failed) couldn't be copied (stick unplugged?)" }
                app.status(msg, 8)
            }
        }
    }

    /// Sync: copy everything on the stick that isn't on the device yet
    func sync(_ d: Device, app: AppModel) {
        let m = missing(d, in: app.library)
        if m.isEmpty { app.status("\(d.name): everything's already on this device", 5); return }
        copy(m, from: d, app: app)
    }

    /// a playlist (or every playlist under a folder): copy its tracks, then make it in your playlists from the copies
    func copyPlaylist(_ n: PDBPlaylist, from d: Device, app: AppModel) {
        let lists = n.folder ? Self.under(n, d) : [n]
        let all = lists.flatMap { Devices.shared.tracks(of: $0, in: d) }
        if n.folder {
            // a folder: its playlists' files, in one go (copy a playlist itself to also get it in your playlists)
            copy(all, from: d, app: app)
        } else {
            copy(Devices.shared.tracks(of: n, in: d), from: d, app: app, playlist: n.name)
        }
    }
    private static func under(_ n: PDBPlaylist, _ d: Device) -> [PDBPlaylist] {
        d.tree.filter { $0.parent == n.id }.flatMap { $0.folder ? under($0, d) : [$0] }
    }

    private func makePlaylist(_ name: String, _ order: [String], _ already: [String: LibTrack], _ copied: [String: LibTrack], _ app: AppModel) {
        let tracks = order.compactMap { copied[$0] ?? already[$0] }
        guard !tracks.isEmpty else { return }
        let pl = app.playlists
        let p = pl.lists.first { !$0.folder && $0.parent == nil && $0.name == name } ?? pl.new(name)
        // syncing the same playlist again adds only what isn't in it yet
        pl.add(tracks.filter { !p.items.contains($0.id) }, to: p.id)
    }

    /// the library folder that holds the copies, added the first time
    private func localFolder(_ lib: Library) -> MusicFolder? {
        let u = Self.root
        let gone = !FileManager.default.fileExists(atPath: u.path)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        if let f = lib.folders.first(where: { $0.id == Self.folderId }) {
            // the From USB folder was deleted (in Files): start it afresh, its old entries go and the copies come back
            // with the same ids, so playlists and Apple's analysis still match them
            if !gone, lib.url(of: f) != nil { return f }
            lib.removeFolder(f)
        }
        return lib.addFolder(u)
    }

    /// Re-sync from the stick: every track on this device that is also on stick `d` (same file name and size) gets
    /// rekordbox's grid, phrases and key again, unless you set its grid yourself. Nothing is copied or deleted; fixes
    /// copies that came in without rekordbox's grid (a rescan raced the copy) and stops them being analysed again
    func regrid(_ d: Device, app: AppModel) {
        if busy != nil { app.status("Wait for the copy to finish", 5); return }
        let lib = app.library, have = Self.liveTwins(lib)
        var jobs = [(LibTrack, URL, TrackRecord)]()
        for t in d.byRbId.values {
            guard let r = t.rb, let a = Devices.shared.anlzURL(t) else { continue }
            let key = Library.twinKey(r.filename.isEmpty ? (r.path as NSString).lastPathComponent : r.filename, Int64(r.size))
            guard let local = have[key], !local.rec.gridManual else { continue }
            jobs.append((local, a, t.rec))
        }
        if jobs.isEmpty { app.status("No tracks on this device match \(d.name)", 6); return }
        busy = d.id; progress = "Reading \(d.name)'s grids…"
        DispatchQueue.global(qos: .utility).async {
            var done = [(LibTrack, TrackRecord)]()
            for (local, a, base) in jobs {
                guard let x = Devices.readAnalysis(at: a), x.bpm > 0 else { continue }
                var r = base
                r.bpm = x.bpm; r.firstBeat = x.firstBeat
                if let ph = x.phrases { r.phrases = ph }
                r.rbGrid = true
                done.append((local, r))
            }
            DispatchQueue.main.async {
                for (t, r) in done { Library.applyRekordbox(r, to: t) }
                lib.objectWillChange.send(); lib.save()
                self.busy = nil; self.progress = ""
                app.status("\(done.count) of \(jobs.count) tracks on this device now use \(d.name)'s rekordbox grids", 8)
            }
        }
    }

    /// the library's tracks by file name + size, leaving out copies whose file was deleted from From USB (in Files),
    /// so Sync copies those again
    static func liveTwins(_ lib: Library) -> [String: LibTrack] {
        let fm = FileManager.default, root = Self.root
        let rootThere = fm.fileExists(atPath: root.path)
        return lib.twins().filter { _, t in
            t.rec.folder != Self.folderId || (rootThere && fm.fileExists(atPath: root.appendingPathComponent(t.rec.rel).path))
        }
    }

    /// a stick name that's safe as a folder name
    static func safe(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "[/\\\\:]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix(".") ? "USB" : t
    }
    static func mb(_ b: Int64) -> String { b >= 1_000_000_000 ? String(format: "%.1f GB", Double(b) / 1e9) : "\(b / 1_000_000) MB" }
}
