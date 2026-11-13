// USB → this iPhone/iPad: copies tracks from a rekordbox stick into the app's own storage, so they play without the
// stick. All of a stick (also "Sync"), one playlist (or a folder of them), or the tracks you pick. Never deletes, never
// writes to the stick, never copies a track twice: a track whose file name and size are already in the library is
// skipped (the Linux app's usbcopy.rs uses the same twin rule). Copies keep rekordbox's title, artist, grid and key,
// and the stick's whole PIONEER folder comes along (Jonah, 2026-11-13: "as if the app thinks it's reading a rekordbox
// usb when there isn't one"): From USB/<stick>/ is laid out like the stick (Contents/… + PIONEER/rekordbox/export.pdb,
// USBANLZ, Artwork), so each copy's title, artist, key, grid, phrases and cues come from rekordbox's own files with
// the stick unplugged (rehydrate), and it can all be seen and copied in Files.
// The copying runs on a background queue at utility priority; the decks hold their tracks in memory, so it never
// touches playback. Main thread for everything else.
import Foundation
import UIKit
import CrateboxKit

final class UsbCopy: ObservableObject {
    static let shared = UsbCopy()
    /// the stick being copied from (eject waits for it), nil when idle
    @Published private(set) var busy: String?
    @Published private(set) var progress = ""
    /// what the last copy / sync / re-sync said, kept for Settings (the top bar's message is hidden behind the sheet)
    @Published private(set) var result = ""
    private func say(_ app: AppModel, _ s: String, _ secs: Double) { result = s; app.status(s, secs) }
    private var cancelled = false

    /// where copies go: Documents/From USB/<stick name>/<the path on the stick>. One library folder holds every stick's copies.
    static let folderId = "dir-From USB"
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("From USB", isDirectory: true)
    }

    /// what one stick track becomes on the device (gathered on the main thread: the device list lives there)
    private struct Job { let src: URL; let anlz: URL?; let anlzRel: String?; let rel: String; let name: String; let size: Int64; let base: TrackRecord }

    /// a stick track's ANLZ file, where its copy goes inside From USB (nil without one)
    static func anlzRel(_ t: LibTrack, stick: String) -> String? {
        guard let r = t.rb, !r.anlzPath.isEmpty else { return nil }
        return stick + "/" + String(r.anlzPath.drop { $0 == "/" })
    }
    /// copies the .DAT and its .EXT / .2EX beside it (skips ones already there at the same size); true when the .DAT is there
    @discardableResult static func copyANLZ(_ dat: URL, to local: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        for ext in ["DAT", "EXT", "2EX"] {
            let s = dat.deletingPathExtension().appendingPathExtension(ext), d = local.deletingPathExtension().appendingPathExtension(ext)
            guard let ss = (try? fm.attributesOfItem(atPath: s.path))?[.size] as? Int64 else { continue }
            if let ds = (try? fm.attributesOfItem(atPath: d.path))?[.size] as? Int64, ds == ss { continue }
            try? fm.removeItem(at: d)
            try? fm.copyItem(at: s, to: d)
        }
        return fm.fileExists(atPath: local.path)
    }
    /// the stick's whole PIONEER folder (export.pdb, exportLibrary.db, every ANLZ file, artwork) to
    /// From USB/<stick>/PIONEER, file by file, skipping files already there at the same size (any thread)
    static func copyPioneer(_ stickRoot: URL, stick: String) {
        let fm = FileManager.default
        let from = stickRoot.appendingPathComponent("PIONEER", isDirectory: true), base = Library.plainPath(from)
        let to = root.appendingPathComponent(stick + "/PIONEER", isDirectory: true)
        guard let en = fm.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            let p = Library.plainPath(u)
            guard p.hasPrefix(base + "/") else { continue }
            let d = to.appendingPathComponent(String(p.dropFirst(base.count + 1)))
            let size = Int64(v?.fileSize ?? -1)
            if let ds = (try? fm.attributesOfItem(atPath: d.path))?[.size] as? Int64, ds == size, !u.lastPathComponent.hasPrefix("export") { continue }
            try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: d)
            try? fm.copyItem(at: u, to: d)
        }
    }

    /// Copies on this device that lack rekordbox's data (copied before PIONEER came along, or a rescan gave them new
    /// entries) get it from the stick image beside them: title, artist, key and length from From USB/<stick>/PIONEER/
    /// rekordbox/export.pdb, grid, phrases and cues from its ANLZ file. A grid you set stays. `all`: every copy again.
    private var rehydrating = false
    func rehydrate(_ lib: Library, all: Bool = false, done: ((Int) -> Void)? = nil) {
        let todo = lib.tracks.filter { $0.device == nil && $0.rec.folder == Self.folderId && (all || $0.rec.anlz == nil || $0.rec.rbTags != true) }
        if todo.isEmpty || rehydrating { done?(0); return }
        rehydrating = true
        let recs = todo.map { ($0, $0.rec.rel) }, root = Self.root
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var dbs = [String: [String: PDBTrack]]()
            var out = [(LibTrack, PDBTrack, String?, Devices.RBRead?)]()
            for (t, rel) in recs {
                let stick = String(rel.prefix { $0 != "/" })
                if dbs[stick] == nil {
                    var m = [String: PDBTrack]()
                    if let d = try? Data(contentsOf: root.appendingPathComponent(stick + "/PIONEER/rekordbox/export.pdb")) {
                        for x in PDB.parse([UInt8](d)).tracks { m[stick + "/" + String(x.path.drop { $0 == "/" })] = x }
                    }
                    dbs[stick] = m
                }
                guard let x = dbs[stick]?[rel] else { continue }
                var a: String?, read: Devices.RBRead?
                if !x.anlzPath.isEmpty {
                    let ar = stick + "/" + String(x.anlzPath.drop { $0 == "/" })
                    let u = root.appendingPathComponent(ar)
                    if fm.fileExists(atPath: u.path) { a = ar; read = Devices.readAnalysis(at: u) }
                }
                out.append((t, x, a, read))
            }
            DispatchQueue.main.async {
                var n = 0
                for (t, x, a, read) in out {
                    if !x.title.isEmpty { t.rec.title = x.title; t.info.title = x.title }
                    if !x.artist.isEmpty || !x.title.isEmpty { t.rec.artist = x.artist; t.info.artist = x.artist }
                    let k = RekordboxANLZ.keyIndex(x.key)
                    if k >= 0 { t.info.key = k; t.info.keyFromRekordbox = true }
                    if t.info.duration <= 0, x.duration > 0 { t.info.duration = Double(x.duration) }
                    t.rec.rbTags = true
                    if let a { t.rec.anlz = a }
                    if let read, read.bpm > 0 {
                        var r = t.rec
                        r.bpm = read.bpm; r.firstBeat = read.firstBeat; r.key = t.info.key
                        if let ph = read.phrases { r.phrases = ph }
                        Library.applyRekordbox(r, to: t)
                        if !t.rec.gridManual { t.info.rbBeats = read.beats; t.info.rbBeat0 = read.beat0 }
                        t.info.rbCues = read.cues
                    } else { t.sync() }
                    n += 1
                }
                self.rehydrating = false
                if n > 0 { lib.objectWillChange.send(); lib.save() }
                done?(n)
            }
        }
    }

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
    func copy(_ tracks: [LibTrack], from d: Device, app: AppModel, playlist: String? = nil, mirror: Bool = false) {
        if let b = busy { self.say(app, b == d.id ? "Already copying from \(d.name)" : "Copying from another USB; one at a time", 5); return }
        let lib = app.library
        let folder = localFolder(lib)
        guard let folder, let dest = lib.url(of: folder) else { self.say(app, "Couldn't make the From USB folder on this device", 7); return }
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
            base.title = t.info.title; base.artist = t.info.artist; base.rbTags = true
            jobs.append(Job(src: src, anlz: Devices.shared.anlzURL(t), anlzRel: Self.anlzRel(t, stick: stick), rel: rel, name: file, size: Int64(r.size), base: base))
        }
        if jobs.isEmpty {
            if let playlist { makePlaylist(playlist, order, already, [:], app) }
            self.say(app, tracks.isEmpty ? "Nothing to copy" : "Already on this device: \(already.count) track\(already.count == 1 ? "" : "s"), nothing copied", 6)
            return
        }
        // not room for all of it: copy what fits (keeping 200 MB spare) rather than nothing, and say so
        let need = jobs.reduce(Int64(0)) { $0 + $1.size }
        var skipped = 0
        if let free = (try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, free < need + 200_000_000 {
            var room = free - 200_000_000, fit = [Job]()
            for j in jobs where j.size <= room { fit.append(j); room -= j.size }
            skipped = jobs.count - fit.count
            if fit.isEmpty {
                self.say(app, "Not enough space on this device: \(Self.mb(need)) to copy, \(Self.mb(max(0, free))) free. Files you deleted stay in Files → Recently Deleted (and keep using space) until you empty it", 12)
                return
            }
            jobs = fit
        }
        busy = d.id; cancelled = false
        let n = jobs.count, name = d.name
        progress = "Copying 0 of \(n) from \(name)…"
        // leaving the app (a text, the lock button): iOS gives a little time to finish; whatever's copied by then is
        // already in the library (every 10 tracks), and Sync later copies the rest
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "Copy from USB") { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        let stickRoot = d.root
        DispatchQueue.global(qos: .utility).async {
            var done = [TrackRecord](), failed = 0, batch = [TrackRecord]()
            let fm = FileManager.default
            Self.copyPioneer(stickRoot, stick: stick)
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
                    // rekordbox's analysis files came along with PIONEER (grid, cues, phrases at load, without the stick)
                    if let a = j.anlz, let ar = j.anlzRel, Self.copyANLZ(a, to: dest.appendingPathComponent(ar)) { r.anlz = ar }
                    // rekordbox's grid and phrases from the stick's analysis file, so the copy plays with the same grid
                    if let a = j.anlz, let x = Devices.readAnalysis(at: a), x.bpm > 0 {
                        r.bpm = x.bpm; r.firstBeat = x.firstBeat; r.autoBpm = x.bpm; r.autoFirst = x.firstBeat
                        if let ph = x.phrases { r.phrases = ph }
                        r.ver = Library.ANALYSIS_VER; r.rbGrid = true
                    } else { r.rbGrid = false; if (r.bpm ?? 0) <= 0 || r.firstBeat == nil { r.ver = 0 } }
                    done.append(r); batch.append(r)
                    if batch.count >= 10 { let b = batch; batch = []; DispatchQueue.main.async { _ = lib.addCopied(b) } }
                } catch { failed += 1 }
                DispatchQueue.main.async { self.progress = "Copying \(i + 1) of \(n) from \(name)…" }
            }
            let stopped = self.cancelled
            DispatchQueue.main.async {
                let added = lib.addCopied(done)
                var copied = [String: LibTrack]()
                for t in added { copied[Library.twinKey((t.rec.rel as NSString).lastPathComponent, t.rec.size)] = t }
                if let playlist { self.makePlaylist(playlist, order, already, copied, app) }
                if mirror { self.mirrorPlaylists(d, app: app) }
                self.busy = nil; self.progress = ""
                // copies made before PIONEER came along get rekordbox's data from it now
                self.rehydrate(lib)
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
                var msg = "\(stopped ? "Stopped: copied" : "Copied") \(added.count) track\(added.count == 1 ? "" : "s") from \(name) to this device"
                if !already.isEmpty { msg += ", \(already.count) already here" }
                if failed > 0 { msg += ", \(failed) couldn't be copied (stick unplugged?)" }
                if skipped > 0 { msg += ". \(skipped) didn't fit: free up space (Files → Recently Deleted counts) and Sync again" }
                self.say(app, msg, 8)
            }
        }
    }

    /// Sync: copy everything on the stick that isn't on the device yet
    func sync(_ d: Device, app: AppModel) {
        let m = missing(d, in: app.library)
        if m.isEmpty {
            if busy != nil { self.say(app, "Wait for the copy to finish", 5); return }
            // nothing to copy: still bring the stick's PIONEER folder over (database, grids, cues, artwork) and give
            // every copy rekordbox's data from it
            busy = d.id; progress = "Copying \(d.name)'s rekordbox files…"
            let stickRoot = d.root, stick = Self.safe(d.name), lib = app.library
            DispatchQueue.global(qos: .utility).async {
                Self.copyPioneer(stickRoot, stick: stick)
                DispatchQueue.main.async {
                    self.busy = nil; self.progress = ""
                    let n = self.mirrorPlaylists(d, app: app)
                    self.rehydrate(lib, all: true) { k in
                        self.say(app, "\(d.name): every track's already on this device; rekordbox's files copied, \(k) track\(k == 1 ? "" : "s") use them; \(n) playlist\(n == 1 ? "" : "s") brought up to date", 8)
                    }
                }
            }
            return
        }
        copy(m, from: d, app: app, mirror: true)
    }

    /// The stick's rekordbox playlists (and their folders) in your playlists, under a folder named after the stick,
    /// made of the copies on this device. Run again, it adds what's new to each and never removes anything.
    @discardableResult func mirrorPlaylists(_ d: Device, app: AppModel) -> Int {
        let have = Self.liveTwins(app.library), pl = app.playlists
        let top = pl.lists.first { $0.folder && $0.parent == nil && $0.name == d.name } ?? pl.new(d.name, folder: true)
        var made = 0, visited = Set<UInt32>()
        func walk(_ parent: UInt32, _ into: String) {
            for n in d.tree.filter({ $0.parent == parent && $0.id != parent }).sorted(by: { $0.sort < $1.sort }) where visited.insert(n.id).inserted {
                let mine = pl.lists.first { $0.parent == into && $0.name == n.name && $0.folder == n.folder }
                    ?? pl.new(n.name, folder: n.folder, parent: into)
                if n.folder { walk(n.id, mine.id); continue }
                let tracks = Devices.shared.tracks(of: n, in: d).compactMap { t -> LibTrack? in
                    guard let r = t.rb else { return nil }
                    return have[Library.twinKey(r.filename.isEmpty ? (r.path as NSString).lastPathComponent : r.filename, Int64(r.size))]
                }
                let cur = Set(pl.get(mine.id)?.items ?? [])
                var seen = Set<String>()
                let add = tracks.filter { !cur.contains($0.id) && seen.insert($0.id).inserted }
                if !add.isEmpty { pl.add(add, to: mine.id) }
                made += 1
            }
        }
        walk(0, top.id)
        return made
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
        if busy != nil { self.say(app, "Wait for the copy to finish", 5); return }
        let lib = app.library, have = Self.liveTwins(lib)
        var jobs = [(LibTrack, URL, TrackRecord)]()
        for t in d.byRbId.values {
            guard let r = t.rb, let a = Devices.shared.anlzURL(t) else { continue }
            let key = Library.twinKey(r.filename.isEmpty ? (r.path as NSString).lastPathComponent : r.filename, Int64(r.size))
            guard let local = have[key], !local.rec.gridManual else { continue }
            jobs.append((local, a, t.rec))
        }
        if jobs.isEmpty { self.say(app, "No tracks on this device match \(d.name)", 6); return }
        busy = d.id; progress = "Reading \(d.name)'s grids…"
        let stickRoot = d.root, stick = Self.safe(d.name)
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
            // and the stick's PIONEER folder, so copies keep it all without the stick
            Self.copyPioneer(stickRoot, stick: stick)
            DispatchQueue.main.async {
                for (t, r) in done { Library.applyRekordbox(r, to: t) }
                lib.objectWillChange.send(); lib.save()
                self.busy = nil; self.progress = ""
                self.rehydrate(lib, all: true)
                self.say(app, "\(done.count) of \(jobs.count) tracks on this device now use \(d.name)'s rekordbox grids", 8)
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
