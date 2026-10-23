// Cratebox USB: your edits to tracks (cues, beat grid, track info) as writes to a stick. `plan` works out
// every file that changes and builds each new version in memory with the writers (which check themselves);
// nothing touches the stick until `apply`, which writes them one by one through USBSafeWrite and puts back
// the ones already written if a later one fails. Only the kinds USBWriteGate allows are planned.
//
//  cues  → the track's ANLZ .DAT and .EXT (PCOB / PCO2), and OneLibrary's cue table when rekordbox put the
//          track's cues there (exports that leave the table empty keep it empty)
//  grid  → the .DAT and .EXT (PQTZ; PQT2 dropped), and the BPM in both libraries' track rows
//  info  → export.pdb's track rows and OneLibrary's content table
import Foundation

public struct USBCue: Equatable, Codable {
    public var time: Double
    public var loopEnd: Double?
    public var comment: String
    public init(time: Double, loopEnd: Double? = nil, comment: String = "") { self.time = time; self.loopEnd = loopEnd; self.comment = comment }
}

/// what to change on one track; nil = leave it as it is on the stick
public struct USBTrackChanges: Equatable {
    /// the main cue: the earliest memory cue moves here (or one is added)
    public var cue: Double?
    public var hot: [USBCue?]?                 // A-H
    public var memory: [USBCue]?
    public var bpm: Double?, firstBeat: Double?
    public var title: String?, artist: String?, album: String?, genre: String?, comment: String?, rating: Int?
    public init(cue: Double? = nil, hot: [USBCue?]? = nil, memory: [USBCue]? = nil, bpm: Double? = nil, firstBeat: Double? = nil,
                title: String? = nil, artist: String? = nil, album: String? = nil, genre: String? = nil, comment: String? = nil, rating: Int? = nil) {
        self.cue = cue; self.hot = hot; self.memory = memory; self.bpm = bpm; self.firstBeat = firstBeat
        self.title = title; self.artist = artist; self.album = album; self.genre = genre; self.comment = comment; self.rating = rating
    }
    public var hasCues: Bool { cue != nil || hot != nil || memory != nil }
    public var hasGrid: Bool { bpm != nil || firstBeat != nil }
    public var hasInfo: Bool { title != nil || artist != nil || album != nil || genre != nil || comment != nil || rating != nil }
    /// the write kinds this change needs
    public var kinds: Set<USBWriteKind> {
        var k = Set<USBWriteKind>()
        if hasCues { k.insert(.cues) }
        if hasGrid { k.insert(.beatgrid) }
        if hasInfo { k.insert(.metadata) }
        return k
    }
}

public struct USBWritePlan {
    public struct File: Equatable {
        public var rel: String                 // relative to the stick's root
        public var old: [UInt8], new: [UInt8]
    }
    public var files: [File] = []
    public var tracks: [String] = []           // track keys this plan writes
    public var summary: [String] = []
    public var isEmpty: Bool { files.isEmpty }
}

public enum USBTrackWriter {
    static let pdbRel = "PIONEER/rekordbox/export.pdb", olRel = "PIONEER/rekordbox/exportLibrary.db"
    static func ms(_ t: Double) throws -> UInt32 {
        guard t.isFinite, t >= 0, t * 1000 < Double(UInt32.max - 1) else { throw ANLZWriteError.badCue("time \(t) s") }
        return UInt32((t * 1000).rounded())
    }
    static func rel(_ path: String) -> String { String(path.drop { $0 == "/" }) }

    /// Every file `changes` (by track key) needs written, built and checked in memory. Throws
    /// USBWriteError.locked if a change needs a write the gate doesn't allow, and the writers' own errors
    /// if a file can't be written as asked. `pdbBytes` / `olBytes`: the libraries as `lib` was read from them.
    public static func plan(_ lib: USBLibrary, root: URL, changes: [String: USBTrackChanges], gate: USBWriteGate,
                            pdbBytes: [UInt8]?, olBytes: [UInt8]?) throws -> USBWritePlan {
        let wanted = changes.filter { !$0.value.kinds.isEmpty }
        let needs = wanted.values.reduce(Set<USBWriteKind>()) { $0.union($1.kinds) }
        let locked = USBWriteKind.allCases.filter { needs.contains($0) && !gate.allowed($0) }
        if !locked.isEmpty {
            throw USBWriteError.locked("Not proven on hardware yet, so locked: \(locked.map { $0.title }.joined(separator: "; ")). Your edits are kept in Cratebox.")
        }
        var plan = USBWritePlan()
        var pdbEdits = [UInt32: PDBTrackEdit](), olEdits = [Int64: OLTrackEdit](), olCues = [Int64: [ANLZCuePoint]]()
        var files = [String: (old: [UInt8], new: [UInt8])](), order = [String]()
        func load(_ rel: String) throws -> [UInt8] {
            if let f = files[rel] { return f.new }
            guard let b = try? [UInt8](Data(contentsOf: root.appendingPathComponent(rel))) else { throw USBWriteError.changedSinceRead(rel + " (can't be read)") }
            files[rel] = (b, b); order.append(rel)
            return b
        }
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
        var olCueTracks: Set<Int64>?
        func olHasCues(_ id: Int64) -> Bool {
            if olCueTracks == nil { olCueTracks = Set(((olBytes.flatMap { try? OneLibrary.read($0) })?.cues ?? []).map { $0.track }) }
            return olCueTracks!.contains(id)
        }

        for (key, c) in wanted.sorted(by: { $0.key < $1.key }) {
            guard let t = lib.track(key) else { throw USBWriteError.verifyFailed("\(key) isn't on this stick") }
            plan.tracks.append(key)
            var what = [String]()
            let dat = rel(t.anlzPath), ext = (dat as NSString).deletingPathExtension + ".EXT"
            let anlz = [dat] + (exists(ext) ? [ext] : [])
            if c.hasCues || c.hasGrid {
                guard !t.anlzPath.isEmpty, exists(dat) else { throw USBWriteError.verifyFailed("\(t.fileName) has no analysis file on the stick: analyse it in rekordbox and export again") }
            }
            if c.hasGrid {
                let beats = RekordboxANLZ.parse(try load(dat)).beats
                let old = RekordboxANLZ.grid(beats)
                guard let bpm = c.bpm ?? old?.bpm, let first = c.firstBeat ?? old?.firstBeat else { throw ANLZWriteError.badGrid("\(t.fileName) has no grid to start from: give it a BPM and first beat") }
                let duration = t.duration > 0 ? t.duration : Double(beats.last?.ms ?? 0) / 1000 + 60 / bpm
                let grid = try RekordboxANLZ.constantGrid(bpm: bpm, firstBeat: first, duration: duration)
                for f in anlz { let b = try RekordboxANLZ.writeGrid(try load(f), grid); files[f]!.new = b }
                let rounded = grid[0].bpm
                if let id = t.pdbId { pdbEdits[id, default: PDBTrackEdit()].bpm = rounded }
                if let id = t.olId, lib.hasOneLibrary { olEdits[id, default: OLTrackEdit()].bpm = rounded }
                what.append(String(format: "grid %.2f BPM from %.3f s", rounded, first))
            }
            if c.hasCues {
                // start from what's on the stick (the .EXT has the comments and colours), then apply the edit
                let src = anlz.count > 1 ? try load(ext) : try load(dat)
                let existing = RekordboxANLZ.cuePoints(src)
                var hot = existing.filter { $0.hot > 0 }, memory = existing.filter { $0.hot == 0 }.sorted { $0.ms < $1.ms }
                if let h = c.hot {
                    var list = [ANLZCuePoint]()
                    for (i, q) in h.prefix(8).enumerated() {
                        guard let q else { continue }
                        var p = ANLZCuePoint(hot: i + 1, ms: try ms(q.time), loopMs: try q.loopEnd.map(ms), comment: q.comment)
                        let was = hot.first { $0.hot == i + 1 }
                        p.color = was?.color
                        if let w = was, w.ms == p.ms, w.loopMs == p.loopMs { p.pad = w.pad; p.tail = w.tail }
                        list.append(p)
                    }
                    hot = list
                }
                if let m = c.memory {
                    memory = try m.map { q in
                        var p = ANLZCuePoint(hot: 0, ms: try ms(q.time), loopMs: try q.loopEnd.map(ms), comment: q.comment)
                        let was = memory.first { $0.ms == p.ms && $0.loopMs == p.loopMs }
                        p.colorId = was?.colorId ?? memory.first { $0.ms == p.ms }?.colorId
                        p.pad = was?.pad; p.tail = was?.tail
                        return p
                    }
                }
                if let cue = c.cue {
                    let at = try ms(cue)
                    if !memory.contains(where: { $0.loopMs == nil && $0.ms == at }) {
                        if c.memory == nil, let i = memory.indices.filter({ memory[$0].loopMs == nil }).min(by: { memory[$0].ms < memory[$1].ms }) { memory[i].ms = at }
                        else { memory.append(ANLZCuePoint(hot: 0, ms: at)) }
                    }
                }
                // one memory cue per position (rekordbox doesn't keep two at the same spot)
                var spots = Set<String>()
                memory = memory.filter { spots.insert("\($0.ms)|\($0.loopMs.map(String.init) ?? "-")").inserted }
                let all = hot + memory
                for f in anlz { let b = try RekordboxANLZ.writeCues(try load(f), all); files[f]!.new = b }
                if let id = t.olId, lib.hasOneLibrary, olHasCues(id) { olCues[id] = all }
                what.append("\(hot.count) hot cues, \(memory.count) memory cues")
            }
            if c.hasInfo {
                if let id = t.pdbId {
                    var e = pdbEdits[id, default: PDBTrackEdit()]
                    e.title = c.title; e.artist = c.artist; e.album = c.album; e.genre = c.genre; e.comment = c.comment; e.rating = c.rating
                    pdbEdits[id] = e
                }
                if let id = t.olId, lib.hasOneLibrary {
                    var e = olEdits[id, default: OLTrackEdit()]
                    e.title = c.title; e.artist = c.artist; e.album = c.album; e.genre = c.genre; e.comment = c.comment; e.rating = c.rating
                    olEdits[id] = e
                }
                what.append("track info")
            }
            plan.summary.append("\(t.title): " + what.joined(separator: ", "))
        }
        if !pdbEdits.isEmpty {
            guard let cur = pdbBytes else { throw USBWriteError.verifyFailed("the Device Library wasn't read") }
            files[pdbRel] = (cur, try PDB.writeTracks(cur, pdbEdits)); order.append(pdbRel)
        }
        if !olEdits.isEmpty || !olCues.isEmpty {
            guard let cur = olBytes else { throw USBWriteError.verifyFailed("OneLibrary wasn't read") }
            var b = cur
            if !olEdits.isEmpty { b = try OneLibrary.writeTracks(b, olEdits) }
            if !olCues.isEmpty { b = try OneLibrary.writeCues(b, olCues) }
            files[olRel] = (cur, b); order.append(olRel)
        }
        plan.files = order.compactMap { r in files[r].flatMap { $0.old == $0.new ? nil : USBWritePlan.File(rel: r, old: $0.old, new: $0.new) } }
        return plan
    }

    /// Writes a plan's files, each through USBSafeWrite (backed up, staged, checked, swapped). If one fails,
    /// the ones already written are put back and the error is thrown. Returns the backups made.
    @discardableResult
    public static func apply(_ plan: USBWritePlan, root: URL, appBackupDir: URL?) throws -> [URL] {
        var done = [USBWritePlan.File](), backups = [URL]()
        do {
            for f in plan.files {
                let b = try USBSafeWrite.write(f.new, root: root, rel: f.rel, expectedHash: USBSafeWrite.hash(f.old), appBackupDir: appBackupDir) { staged in
                    try check(f.rel, staged)
                }
                backups.append(b); done.append(f)
            }
        } catch {
            var undo = [String]()
            for f in done.reversed() {
                do { try USBSafeWrite.write(f.old, root: root, rel: f.rel, expectedHash: USBSafeWrite.hash(f.new), appBackupDir: nil) { _ in } }
                catch { undo.append("\((f.rel as NSString).lastPathComponent) (\(error))") }
            }
            if done.isEmpty { throw error }
            if undo.isEmpty { throw USBWriteError.verifyFailed("\(error). The files already written were put back as they were.") }
            throw USBWriteError.swapFailed("\(error). Putting back failed for \(undo.joined(separator: ", ")): restore from the backups in Cratebox USB")
        }
        return backups
    }

    /// the check each staged file gets, as read back from the stick: parsed the way a player would
    static func check(_ rel: String, _ b: [UInt8]) throws {
        if rel == pdbRel {
            let p = PDB.problems(b)
            if !p.isEmpty { throw PDBError.readBack(p[0]) }
        } else if rel == olRel {
            let o = try OneLibrary.read(b)
            if o.integrity != ["ok"] { throw OneLibraryError.readBack("integrity") }
        } else {
            _ = try RekordboxANLZ.split(b)
        }
    }
}
