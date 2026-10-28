// Every change Cratebox USB makes to a stick goes through here: staged, backed up, checked, and recoverable.
//
//  1. read the file as it is now, and refuse if it isn't the version the change was made against
//  2. back it up (on the stick, under PIONEER/rekordbox/.cratebox/backups, and a copy in the app) and read
//     the backup back
//  3. write a journal saying what's about to happen
//  4. write the new version next to it (…cratebox-stage), flush it to the stick, read it back
//  5. let the caller check the staged bytes (parse them like a player would)
//  6. swap it in with one rename, flush, read the result back
//  7. clear the journal
// If the app, the phone or the stick goes away in the middle, the journal is still there the next time the
// stick is opened, and `recover` puts the right version back.
// A change that spans files (both libraries, or a library and analysis files) is one group: a group journal
// lists every file with its before and after, and if it's still there, recovery puts all of them back as they
// were, so the stick never keeps half a change.
//
// Which writes are allowed at all is USBWriteGate's job (below): nothing that hasn't been proven on hardware.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum USBWriteError: Error, CustomStringConvertible, Equatable {
    case changedSinceRead(String), backupFailed(String), stageFailed(String), verifyFailed(String), swapFailed(String), locked(String)
    public var description: String {
        switch self {
        case .changedSinceRead(let f): return "\(f) changed on the stick since Cratebox read it (rekordbox exported to it?). Nothing was written. Open the stick again."
        case .backupFailed(let s): return "Couldn't back up first, so nothing was written: \(s)"
        case .stageFailed(let s): return "Couldn't stage the new version, nothing was changed: \(s)"
        case .verifyFailed(let s): return "The new version didn't pass its checks, nothing was changed: \(s)"
        case .swapFailed(let s): return "Swapping the new version in failed: \(s). The backup is on the stick."
        case .locked(let s): return s
        }
    }
}

public struct USBJournal: Codable, Equatable {
    public var target: String          // path relative to the stick's root
    public var backup: String          // relative to the stick's root
    public var oldHash: String, newHash: String
    public var oldSize: Int, newSize: Int
    public var state: String           // "staged" → "swapped"
    public var when: Date
}

/// one change made of several files' writes: all or none of them
public struct USBGroupJournal: Codable, Equatable {
    public struct Member: Codable, Equatable { public var target: String, oldHash: String, newHash: String }
    public var id: String
    public var members: [Member]
    public var when: Date
}

public enum USBSafeWrite {
    public static let dirName = "PIONEER/rekordbox/.cratebox"

    /// Runs `body` (the group's writes, and any putting back after a failure) with a group journal on the stick:
    /// cleared when `body` returns or throws, so it's only left behind if the app stopped in the middle, or if
    /// putting the files back failed too (swapFailed).
    public static func group<T>(root: URL, _ files: [(rel: String, old: [UInt8], new: [UInt8])], _ body: () throws -> T) throws -> T {
        if files.count < 2 { return try body() }
        let dir = root.appendingPathComponent(dirName)
        let g = USBGroupJournal(id: UUID().uuidString, members: files.map { .init(target: $0.rel, oldHash: hash($0.old), newHash: hash($0.new)) }, when: Date())
        let gu = dir.appendingPathComponent("group-" + g.id + ".json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(g).write(to: gu); flush(gu)
        } catch { throw USBWriteError.stageFailed("group journal: \(error.localizedDescription)") }
        do { let r = try body(); try? FileManager.default.removeItem(at: gu); return r }
        catch USBWriteError.swapFailed(let why) {
            // putting back failed too: the journal stays, so opening the stick again has another go
            throw USBWriteError.swapFailed(why)
        } catch { try? FileManager.default.removeItem(at: gu); throw error }
    }
    public static func hash(_ b: [UInt8]) -> String {
        // FNV-1a 64 + size: enough to tell versions of one file apart (not a security hash)
        var h: UInt64 = 0xcbf29ce484222325
        for x in b { h ^= UInt64(x); h = h &* 0x100000001b3 }
        return String(format: "%016llx-%ld", h, b.count)
    }
    /// a backup's name: the file's whole path on the stick, flattened
    static func backupName(_ rel: String) -> String { rel.replacingOccurrences(of: "/", with: "_") }
    static func backupStamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
    /// a file's backups in `dir`, oldest first. New names carry a sequence number (n00000012), so the order never
    /// depends on the clock (two saves in one millisecond, or a clock set back); names from before that (a time
    /// stamp only, and for the databases the file name alone) count as older than any numbered one.
    static func backupList(in dir: URL, rel: String) -> [(seq: Int, name: String)] {
        let flat = backupName(rel) + ".", base = (rel as NSString).lastPathComponent + "."
        let dbDir = "PIONEER/rekordbox/", legacy = rel.hasPrefix(dbDir) && !rel.dropFirst(dbDir.count).contains("/")
        var out = [(seq: Int, key: String, name: String)]()
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasSuffix(".bak") {
            if n.hasPrefix(flat) {
                let rest = n.dropFirst(flat.count)
                if rest.first == "n", let dot = rest.firstIndex(of: "."), let k = Int(rest[rest.index(after: rest.startIndex)..<dot]) {
                    out.append((k, String(rest), n))
                } else { out.append((-1, String(rest), n)) }
            } else if legacy && n.hasPrefix(base) { out.append((-1, String(n.dropFirst(base.count)), n)) }
        }
        return out.sorted { ($0.seq, $0.key) < ($1.seq, $1.key) }.map { ($0.seq, $0.name) }
    }
    /// backups an unfinished write's journal still points at: never pruned, recovery may need them
    static func journalled(_ root: URL) -> Set<String> {
        let dir = root.appendingPathComponent(dirName)
        var out = Set<String>()
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasPrefix("journal-") && n.hasSuffix(".json") {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(n)), let j = try? JSONDecoder().decode(USBJournal.self, from: d) {
                out.insert((j.backup as NSString).lastPathComponent)
            }
        }
        return out
    }
    static func journalURL(_ root: URL, _ rel: String) -> URL {
        root.appendingPathComponent(dirName).appendingPathComponent("journal-" + rel.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    static func flush(_ u: URL) {
        guard let h = try? FileHandle(forUpdating: u) else { return }
        #if canImport(Darwin)
        _ = fcntl(h.fileDescriptor, F_FULLFSYNC)
        #endif
        try? h.synchronize(); try? h.close()
    }

    /// Writes `new` over root/rel. `expectedHash`: the version the change was based on (from `hash`), or nil to
    /// skip that check. `appBackupDir`: where the app keeps its own copy of the backup. `verify` gets the
    /// staged bytes as read back from the stick and throws if they're wrong.
    @discardableResult
    public static func write(_ new: [UInt8], root: URL, rel: String, expectedHash: String?, appBackupDir: URL?, keepBackups: Int = 5,
                             verify: ([UInt8]) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let target = root.appendingPathComponent(rel)
        // 1
        guard let cur = try? [UInt8](Data(contentsOf: target)) else { throw USBWriteError.changedSinceRead(rel + " (can't be read)") }
        let oldHash = hash(cur)
        if let e = expectedHash, e != oldHash { throw USBWriteError.changedSinceRead((rel as NSString).lastPathComponent) }
        // 2
        let dir = root.appendingPathComponent(dirName)
        let backups = dir.appendingPathComponent("backups")
        let base = (rel as NSString).lastPathComponent
        // named by the whole path (every track's analysis file is called ANLZ0000.DAT), then the next sequence number
        // for that file (the order), the time (for people) and a random tail (two apps, one stick): two saves never
        // share a backup, and one file's history never prunes another's
        let next = (backupList(in: backups, rel: rel).map { $0.seq }.max() ?? 0) + 1
        let name = backupName(rel) + ".n" + String(format: "%08d", max(1, next)) + "." + backupStamp() + "-" + String(UUID().uuidString.prefix(6)) + ".bak"
        let backupRel = dirName + "/backups/" + name
        do {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let bu = root.appendingPathComponent(backupRel)
            try Data(cur).write(to: bu)
            flush(bu)
            guard try [UInt8](Data(contentsOf: bu)) == cur else { throw USBWriteError.backupFailed("the backup didn't read back") }
            if let a = appBackupDir {
                try fm.createDirectory(at: a, withIntermediateDirectories: true)
                try Data(cur).write(to: a.appendingPathComponent(name))
            }
            // keep the newest few, and any an unfinished write still needs
            let keep = journalled(root)
            for old in backupList(in: backups, rel: rel).dropLast(keepBackups) where !keep.contains(old.name) {
                try? fm.removeItem(at: backups.appendingPathComponent(old.name))
            }
        } catch let e as USBWriteError { throw e } catch { throw USBWriteError.backupFailed(error.localizedDescription) }
        // 3
        var j = USBJournal(target: rel, backup: backupRel, oldHash: oldHash, newHash: hash(new), oldSize: cur.count, newSize: new.count, state: "staged", when: Date())
        let ju = journalURL(root, rel)
        do { try JSONEncoder().encode(j).write(to: ju); flush(ju) } catch { throw USBWriteError.stageFailed("journal: \(error.localizedDescription)") }
        // 4
        let stage = target.deletingLastPathComponent().appendingPathComponent(base + ".cratebox-stage")
        do {
            try Data(new).write(to: stage)
            flush(stage)
            let back = try [UInt8](Data(contentsOf: stage))
            guard back == new else { throw USBWriteError.stageFailed("the staged file didn't read back") }
            // 5
            do { try verify(back) } catch { throw USBWriteError.verifyFailed("\(error)") }
        } catch {
            try? fm.removeItem(at: stage); try? fm.removeItem(at: ju)
            if let e = error as? USBWriteError { throw e }
            throw USBWriteError.stageFailed(error.localizedDescription)
        }
        // 6: rename over the old file (one step on FAT32 / exFAT / HFS+)
        if rename(stage.path, target.path) != 0 {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: stage); try? fm.removeItem(at: ju)
            throw USBWriteError.swapFailed(why)
        }
        flush(target)
        let final = (try? [UInt8](Data(contentsOf: target))) ?? []
        if final != new {
            // put the old one back from the backup
            try? Data(cur).write(to: target); flush(target)
            try? fm.removeItem(at: ju)
            throw USBWriteError.swapFailed("the file on the stick isn't what was written; the old version was put back")
        }
        j.state = "swapped"
        try? JSONEncoder().encode(j).write(to: ju)
        // 7
        try? fm.removeItem(at: ju)
        return root.appendingPathComponent(backupRel)
    }

    public enum Recovery: Equatable { case nothing, cleanedUp(String), restored(String), needsAttention(String) }

    /// After a write that didn't finish (the journal is still there): keep whichever complete version is on
    /// the stick, or put the backup back if the file is neither.
    public static func recover(root: URL) -> [Recovery] {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(dirName)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out = [Recovery]()
        // a group cut off part way: every file it had already changed goes back, from its newest backup of the
        // old version (a file still mid-write is left to its own journal, below, which puts it back too)
        for n in names where n.hasPrefix("group-") && n.hasSuffix(".json") {
            let gu = dir.appendingPathComponent(n)
            guard let d = try? Data(contentsOf: gu), let g = try? JSONDecoder().decode(USBGroupJournal.self, from: d) else { out.append(.needsAttention("unreadable group journal \(n)")); continue }
            var back = [String](), failed = [String]()
            for m in g.members {
                let target = root.appendingPathComponent(m.target)
                guard (try? [UInt8](Data(contentsOf: target))).map(hash) == m.newHash else { continue }
                let bdir = dir.appendingPathComponent("backups")
                let old = backupList(in: bdir, rel: m.target).reversed().lazy
                    .compactMap { try? [UInt8](Data(contentsOf: bdir.appendingPathComponent($0.name))) }.first { hash($0) == m.oldHash }
                if let old, (try? Data(old).write(to: target)) != nil { flush(target); back.append(m.target) } else { failed.append(m.target) }
            }
            if failed.isEmpty {
                try? fm.removeItem(at: gu)
                if !back.isEmpty { out.append(.restored("a save of \(g.members.count) files was cut off part way; \(back.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) went back to the version from before it, so the files match again")) }
            } else {
                out.append(.needsAttention("a save of \(g.members.count) files was cut off and \(failed.joined(separator: ", ")) couldn't be put back (backup missing or damaged)"))
            }
        }
        for n in names where n.hasPrefix("journal-") && n.hasSuffix(".json") {
            let ju = dir.appendingPathComponent(n)
            guard let d = try? Data(contentsOf: ju), let j = try? JSONDecoder().decode(USBJournal.self, from: d) else { out.append(.needsAttention("unreadable journal \(n)")); continue }
            let target = root.appendingPathComponent(j.target)
            let stage = target.deletingLastPathComponent().appendingPathComponent((j.target as NSString).lastPathComponent + ".cratebox-stage")
            let cur = (try? [UInt8](Data(contentsOf: target))).map(hash)
            if cur == j.oldHash || cur == j.newHash {
                try? fm.removeItem(at: stage); try? fm.removeItem(at: ju)
                out.append(.cleanedUp(cur == j.newHash ? "\(j.target): the change had been saved completely" : "\(j.target): the change hadn't been saved; the stick is as it was"))
            } else if let b = try? [UInt8](Data(contentsOf: root.appendingPathComponent(j.backup))), hash(b) == j.oldHash {
                do {
                    try Data(b).write(to: target); flush(target)
                    try? fm.removeItem(at: stage); try? fm.removeItem(at: ju)
                    out.append(.restored("\(j.target): a save was cut off part way; the version from before it was put back"))
                } catch { out.append(.needsAttention("\(j.target): couldn't restore the backup (\(error.localizedDescription))")) }
            } else {
                out.append(.needsAttention("\(j.target): a save was cut off and its backup is missing or damaged"))
            }
        }
        return out
    }

    /// the newest backup of a file on the stick, if any
    public static func latestBackup(root: URL, rel: String) -> URL? {
        let dir = root.appendingPathComponent(dirName).appendingPathComponent("backups")
        return backupList(in: dir, rel: rel).last.map { dir.appendingPathComponent($0.name) }
    }
}

/// What Cratebox USB is allowed to write to a stick. A write is "proven" when it's been checked against a real
/// player: on by default only then. Until then it stays locked; the Proving Ground in Cratebox USB lets you
/// test one on a spare stick and mark it proven yourself.
public enum USBWriteKind: String, CaseIterable, Codable, Identifiable {
    case deviceLibraryPlaylists, oneLibraryPlaylists, cues, beatgrid, metadata
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .deviceLibraryPlaylists: return "Playlists → Device Library (export.pdb)"
        case .oneLibraryPlaylists: return "Playlists → OneLibrary (exportLibrary.db)"
        case .cues: return "Hot cues, memory cues and loops → analysis files"
        case .beatgrid: return "Beat grid → analysis files"
        case .metadata: return "Track info (title, artist…) → both libraries"
        }
    }
    public enum Status: String { case unproven, unsupported }
    /// where each write stands in this build
    public var status: Status {
        switch self {
        // writers exist and check themselves by reading back, but haven't been confirmed on a player
        case .deviceLibraryPlaylists, .oneLibraryPlaylists, .cues, .beatgrid, .metadata: return .unproven
        }
    }
    public var note: String {
        switch self {
        case .deviceLibraryPlaylists: return "Byte-for-byte the same as the web app's writer, read back after every save. Not yet confirmed on a CDJ/XDJ."
        case .oneLibraryPlaylists: return "Edits a decrypted copy in one transaction, checks it with SQLite and reads it back, then re-encrypts. Not yet confirmed on a OneLibrary player."
        case .cues: return "Rewrites the cue lists in the track's analysis files (.DAT and .EXT) and OneLibrary's cue table, read back after every save. Not yet confirmed on a CDJ/XDJ: check hot cues A-H, memory cues, loops and their comments on each player."
        case .beatgrid: return "Writes a constant-tempo grid to the analysis files and the BPM to both libraries. rekordbox's second grid (PQT2) can't be rebuilt, so it's removed. Not yet confirmed on a CDJ/XDJ: check the grid, beat sync and quantise."
        case .metadata: return "Writes title, artist, album, genre, comment and rating to the Device Library and OneLibrary, read back after every save. Not yet confirmed on a CDJ/XDJ: check the track lists and browsing by artist, album and genre."
        }
    }
}

public struct USBWriteGate {
    public var proven: Set<USBWriteKind>
    public init(proven: Set<USBWriteKind>) { self.proven = proven }
    public func allowed(_ k: USBWriteKind) -> Bool { k.status != .unsupported && proven.contains(k) }
    /// Playlist changes reach the stick only when every library on it can take them (a change in one library
    /// but not the other is a sync conflict waiting to happen). nil = allowed; otherwise why not.
    public func playlistWriteBlocker(deviceLibrary: Bool, oneLibrary: Bool) -> String? {
        var missing = [String]()
        if deviceLibrary && !allowed(.deviceLibraryPlaylists) { missing.append("Device Library") }
        if oneLibrary && !allowed(.oneLibraryPlaylists) { missing.append("OneLibrary") }
        if !deviceLibrary && !oneLibrary { return "No rekordbox library on this stick" }
        if missing.isEmpty { return nil }
        return "Playlist writing to \(missing.joined(separator: " and ")) isn't proven on hardware yet, so it's locked. Your changes are kept as staged changes."
    }
}
