// Cratebox USB's preflight scan: will this stick play on the players at the gig?
//
//  Emergency  seconds: only the set you're about to play (or every track, if none is picked): files there,
//             formats the players read, analysis present, the libraries the players need. No decoding.
//  Standard   the whole stick, the set first: also each file's own header (codec, sample rate, bit depth),
//             export.pdb's structure, OneLibrary's quick check, the two libraries against each other, file
//             names a FAT32 stick can't hold.
//  Deep       everything: decodes each file, parses each analysis file, SQLite's full integrity check,
//             hot cues the older players can't show.
//
// Issues come with one-tap fixes where there is one. Fixes that would write to the stick say which write
// (USBWriteKind) so the app can keep them locked until that write is proven.
import Foundation

public enum ScanMode: String, CaseIterable, Codable, Identifiable {
    case emergency, standard, deep
    public var id: String { rawValue }
    public var title: String { ["emergency": "Emergency", "standard": "Standard", "deep": "Deep Scan"][rawValue]! }
    public var blurb: String {
        switch self {
        case .emergency: return "Quick: the set's files, formats and libraries (the whole stick if no set is picked)."
        case .standard: return "The whole stick, set first: headers, databases, sync."
        case .deep: return "Everything, and a test decode of every file (its start, middle and end). Takes a while."
        }
    }
}
public enum IssueSeverity: Int, Comparable, Codable {
    case info = 0, warning = 1, critical = 2
    public static func < (a: IssueSeverity, b: IssueSeverity) -> Bool { a.rawValue < b.rawValue }
}
public enum IssueCategory: String, Codable, CaseIterable {
    case recovery = "Recovery", library = "Library", sync = "Sync", hardware = "Players", missingFile = "Missing files"
    case audio = "Audio", analysis = "Analysis", fileSystem = "File system"
}
public enum QuickFix: String, Codable {
    case recoverWrite          // finish / undo a cut-off save (journal)
    case restoreBackup         // put Cratebox's last backup of a database back
    case removeFromPlaylists   // take missing / unplayable tracks out of the playlists (writes playlists)
    case syncPlaylists         // make both libraries' playlists the same (writes playlists)
    case skip                  // leave it out of this check
    case exportFixList         // a list of tracks to fix in rekordbox, saved to Files
    case reexport              // needs rekordbox: only it can do this
    public var title: String {
        switch self {
        case .recoverWrite: return "Recover"
        case .restoreBackup: return "Restore backup"
        case .removeFromPlaylists: return "Remove from playlists"
        case .syncPlaylists: return "Sync playlists"
        case .skip: return "Skip"
        case .exportFixList: return "Add to fix list"
        case .reexport: return "Re-export in rekordbox"
        }
    }
}

public struct ScanIssue: Identifiable, Equatable {
    public let id: String
    public let severity: IssueSeverity
    public let category: IssueCategory
    public let title: String
    public let detail: String
    public var trackKey: String? = nil
    public var playlistId: String? = nil
    public var inSet = false               // touches the set picked for the gig
    public var conflict = false            // a decision: Fix, Review or Skip
    public var fix: QuickFix? = nil
    public var fixWrites: USBWriteKind? = nil
}

public enum Readiness: Equatable {
    case unknown, ready, warnings(Int), notReady(Int)
    public var label: String {
        switch self {
        case .unknown: return "Not checked"
        case .ready: return "Ready"
        case .warnings(let n): return "Ready · \(n) warning\(n == 1 ? "" : "s")"
        case .notReady(let n): return "Not ready · \(n) problem\(n == 1 ? "" : "s")"
        }
    }
}

public struct ScanOptions {
    public var mode: ScanMode
    public var players: [String]
    public var setPlaylist: String?            // USBPlaylist.id of the set
    public var fileSystem: String?             // "FAT32", "exFAT", "HFS+", … as the app found it
    public init(mode: ScanMode, players: [String], setPlaylist: String? = nil, fileSystem: String? = nil) {
        self.mode = mode; self.players = players; self.setPlaylist = setPlaylist; self.fileSystem = fileSystem
    }
}

public struct ScanReport {
    public var options: ScanOptions
    public var requirement: PlayerProfiles.Requirement
    public var issues: [ScanIssue] = []
    public var tracksChecked = 0, setTracks = 0
    public var started = Date(), finished = Date()
    public var cancelled = false
    /// what the stick's databases were when scanned (a rescan is due when they change)
    public var pdbHash: String?, olHash: String?

    public func readiness(skipped: Set<String>) -> Readiness {
        // an Emergency scan with no set (or an empty one) checked the whole stick: every track it found counts then
        let open = issues.filter { !skipped.contains($0.id) && (options.mode != .emergency || setTracks == 0 || $0.inSet || $0.trackKey == nil) }
        let crit = open.filter { $0.severity == .critical }.count, warn = open.filter { $0.severity == .warning }.count
        if cancelled { return .unknown }
        return crit > 0 ? .notReady(crit) : warn > 0 ? .warnings(warn) : .ready
    }
}

public enum Preflight {
    /// decode: (file URL) → nil if it decodes fine, else why not (Deep only; the app does it with AVFoundation)
    public static func run(_ lib: USBLibrary, root: URL, options: ScanOptions, pdbBytes: [UInt8]?, olBytes: [UInt8]?,
                           progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false },
                           decode: ((URL) -> String?)? = nil) -> ScanReport {
        let req = PlayerProfiles.requirement(options.players)
        var r = ScanReport(options: options, requirement: req)
        r.pdbHash = pdbBytes.map(USBSafeWrite.hash); r.olHash = olBytes.map(USBSafeWrite.hash)
        var out = [ScanIssue]()
        let names = req.players.map { $0.name }.joined(separator: ", ")
        let fm = FileManager.default

        // ---- interrupted saves first: nothing else is trustworthy until they're dealt with ----
        let jdir = root.appendingPathComponent(USBSafeWrite.dirName)
        if let js = try? fm.contentsOfDirectory(atPath: jdir.path), js.contains(where: { $0.hasPrefix("journal-") }) {
            out.append(ScanIssue(id: "recovery|journal", severity: .critical, category: .recovery, title: "A save to this stick was cut off",
                                 detail: "Cratebox was writing to the stick when it was unplugged or the app stopped. Recover puts back whichever complete version is there.",
                                 conflict: false, fix: .recoverWrite))
        }

        // ---- the libraries the players need ----
        if !lib.hasDeviceLibrary && !lib.hasOneLibrary && lib.oneError == nil {
            out.append(ScanIssue(id: "lib|none", severity: .critical, category: .library, title: "No rekordbox library on this stick",
                                 detail: "There's no PIONEER/rekordbox/export.pdb or exportLibrary.db. Export to it from rekordbox.", fix: .reexport))
        }
        if req.deviceLibrary && !lib.hasDeviceLibrary {
            let who = req.players.filter { $0.readsDeviceLibrary && !$0.readsOneLibrary || $0.id == "unknown" }.map { $0.name }.joined(separator: ", ")
            out.append(ScanIssue(id: "lib|need-dl", severity: .critical, category: .hardware, title: "No Device Library for \(who)",
                                 detail: "These players read export.pdb, and this stick only has OneLibrary. They'll show the files in folder view, without playlists, grids or cues. In rekordbox, export the Device Library too.", fix: .reexport))
        }
        if req.oneLibrary && !lib.hasOneLibrary {
            let who = req.players.filter { $0.readsOneLibrary && !$0.readsDeviceLibrary || $0.id == "unknown" }.map { $0.name }.joined(separator: ", ")
            out.append(ScanIssue(id: "lib|need-ol", severity: .critical, category: .hardware, title: "No OneLibrary for \(who)",
                                 detail: "These players read OneLibrary, and this stick only has the Device Library. In rekordbox 7.2.13 or later: right-click OneLibrary on the device → Convert from Device Library, then export again.", fix: .reexport))
        }
        if let e = lib.oneError {
            out.append(ScanIssue(id: "lib|ol-unreadable", severity: req.oneLibrary ? .critical : .warning, category: .library, title: "OneLibrary can't be read",
                                 detail: e, fix: USBSafeWrite.latestBackup(root: root, rel: "PIONEER/rekordbox/exportLibrary.db") != nil ? .restoreBackup : .reexport))
        }
        if options.mode != .emergency, let pb = pdbBytes {
            for (i, p) in PDB.problems(pb).prefix(6).enumerated() {
                out.append(ScanIssue(id: "lib|pdb|\(i)", severity: .critical, category: .library, title: "export.pdb is damaged", detail: p,
                                     fix: USBSafeWrite.latestBackup(root: root, rel: "PIONEER/rekordbox/export.pdb") != nil ? .restoreBackup : .reexport))
            }
        }
        if let one = lib.one, !one.integrity.isEmpty, one.integrity != ["ok"] {
            out.append(ScanIssue(id: "lib|ol-integrity", severity: .critical, category: .library, title: "OneLibrary failed SQLite's integrity check",
                                 detail: one.integrity.prefix(3).joined(separator: "; "),
                                 fix: USBSafeWrite.latestBackup(root: root, rel: "PIONEER/rekordbox/exportLibrary.db") != nil ? .restoreBackup : .reexport))
        }
        // ---- file system ----
        if let fs = options.fileSystem, !fs.isEmpty {
            let ok = req.fileSystems.map { allowed in allowed.contains { fs.uppercased().contains($0.uppercased()) || ($0 == "FAT32" && fs.uppercased().contains("MSDOS")) } } ?? true
            if !ok {
                out.append(ScanIssue(id: "fs|\(fs)", severity: .critical, category: .fileSystem, title: "\(fs) isn't readable by every player",
                                     detail: "\(names) need \(req.fileSystems.map { $0.sorted().joined(separator: " or ") } ?? "FAT32"). FAT32 (MBR) works everywhere.", fix: nil))
            }
        }

        // ---- the set, and which tracks to look at ----
        let setKeys = options.setPlaylist.map { lib.trackKeys(of: $0) } ?? []
        let setSet = Set(setKeys)
        r.setTracks = setKeys.count
        let inAnyPlaylist = Set(lib.playlists.filter { !$0.folder }.flatMap { $0.tracks })
        var order = setKeys
        if options.mode == .emergency {
            if order.isEmpty { order = lib.tracks.map { $0.key } }
        } else {
            order += lib.tracks.map { $0.key }.filter { !setSet.contains($0) }
        }

        // ---- sync between the two libraries ----
        if options.mode != .emergency && lib.hasDeviceLibrary && lib.hasOneLibrary {
            let both = req.deviceLibrary && req.oneLibrary
            for d in lib.differences {
                let inSet: Bool
                switch d.kind {
                case .trackOnlyInDeviceLibrary, .trackOnlyInOneLibrary, .metadataDiffers: inSet = setSet.contains(d.subject)
                default: inSet = d.subject == options.setPlaylist
                }
                let playlist = ([.playlistOnlyInDeviceLibrary, .playlistOnlyInOneLibrary, .playlistContentDiffers] as [USBSyncDifference.Kind]).contains(d.kind)
                out.append(ScanIssue(id: "sync|" + d.id, severity: both || inSet ? .critical : .warning, category: .sync,
                                     title: playlist ? "Playlists differ between the libraries" : d.kind == .metadataDiffers ? "Track info differs between the libraries" : "Track in only one library",
                                     detail: d.detail + (playlist ? "" : " (\(lib.track(d.subject)?.fileName ?? d.subject))"),
                                     trackKey: playlist ? nil : d.subject, playlistId: playlist ? d.subject : nil, inSet: inSet, conflict: true,
                                     fix: playlist ? .syncPlaylists : .reexport, fixWrites: playlist ? .oneLibraryPlaylists : nil))
            }
        }

        // ---- every track in scope ----
        var seenCase = [String: String]()
        let total = max(1, order.count)
        for (i, key) in order.enumerated() {
            if cancelled() { r.cancelled = true; break }
            guard let t = lib.track(key) else { continue }
            if i % 8 == 0 { progress(Double(i) / Double(total), t.fileName) }
            r.tracksChecked += 1
            let inSet = setSet.contains(key)
            let played = inSet || inAnyPlaylist.contains(key)
            let sev: IssueSeverity = inSet || (options.mode == .emergency && setSet.isEmpty) ? .critical : played ? .warning : .info
            func add(_ code: String, _ s: IssueSeverity, _ c: IssueCategory, _ title: String, _ detail: String, fix: QuickFix? = nil, writes: USBWriteKind? = nil) {
                out.append(ScanIssue(id: "track|\(code)|\(key)", severity: s, category: c, title: title, detail: detail, trackKey: key, inSet: inSet, fix: fix, fixWrites: writes))
            }
            let url = root.appendingPathComponent(String(t.path.drop { $0 == "/" }))
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            guard let attrs else {
                add("missing", sev, .missingFile, "Missing: \(t.title)", "\(t.path) isn't on the stick. Players show it but can't load it.",
                    fix: played ? .removeFromPlaylists : .skip, writes: played ? .deviceLibraryPlaylists : nil)
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size == 0 { add("empty", sev, .missingFile, "Empty file: \(t.title)", "\(t.path) is 0 bytes.", fix: .reexport); continue }
            if t.fileSize > 0 && size != t.fileSize {
                add("size", .warning, .audio, "Changed since export: \(t.title)", "The file is \(size) bytes, the library says \(t.fileSize). Cues and the grid may be off; re-export it from rekordbox.", fix: .exportFixList)
            }
            // format: the extension (all modes), the header (standard, deep)
            var codec = PlayerProfiles.codec(ext: t.ext), rate = t.sampleRate, depth = t.bitDepth, isFloat = false
            if options.mode != .emergency, let h = try? FileHandle(forReadingFrom: url) {
                let head = [UInt8]((try? h.read(upToCount: 256 * 1024)) ?? Data())
                try? h.close()
                if let f = AudioSniffer.sniff(head) {
                    if f.codec != codec && !(codec == .aac && f.codec == .alac) {
                        add("ext", .warning, .audio, "Wrong file extension: \(t.fileName)", "It's really \(f.codec.rawValue.uppercased()). Some players go by the extension.", fix: .exportFixList)
                    }
                    codec = f.codec
                    if f.sampleRate > 0 { rate = f.sampleRate }
                    if f.bitDepth > 0 && f.codec != .mp3 && f.codec != .aac { depth = f.bitDepth }
                    isFloat = f.floatingPoint
                } else {
                    add("header", sev, .audio, "Unrecognised audio: \(t.fileName)", "The file's start doesn't look like any format the players read.", fix: .exportFixList)
                }
            }
            if !req.codecs.contains(codec) {
                add("codec", sev, .hardware, "\(codec.rawValue.uppercased()) won't play on \(names): \(t.title)",
                    "Convert it to \(req.codecs.contains(.aiff) ? "AIFF or WAV for lossless" : "MP3"), then re-export.", fix: .exportFixList)
            } else if isFloat {
                add("float", sev, .hardware, "32-bit float audio: \(t.title)", "Players read integer PCM only. Convert to 24-bit.", fix: .exportFixList)
            } else if rate > req.maxSampleRate {
                add("rate", sev, .hardware, "\(rate / 1000) kHz is too high for \(names): \(t.title)", "They read up to \(req.maxSampleRate / 1000) kHz.", fix: .exportFixList)
            } else if ([.wav, .aiff, .flac, .alac] as [AudioCodec]).contains(codec) && depth > req.maxBitDepth {
                add("depth", sev, .hardware, "\(depth)-bit audio won't play on \(names): \(t.title)", "They read up to \(req.maxBitDepth)-bit. Convert it, then re-export.", fix: .exportFixList)
            }
            // analysis
            if t.anlzPath.isEmpty {
                add("anlz-none", played ? .warning : .info, .analysis, "Not analysed: \(t.title)", "No beat grid, waveform or cues on the players. Analyse it in rekordbox and export again.", fix: .exportFixList)
            } else {
                let dat = root.appendingPathComponent(String(t.anlzPath.drop { $0 == "/" }))
                if !fm.fileExists(atPath: dat.path) {
                    add("anlz-missing", played ? .warning : .info, .analysis, "Analysis file missing: \(t.title)", "\(t.anlzPath) isn't on the stick: no grid or waveform on the players.", fix: .exportFixList)
                } else if options.mode == .deep {
                    let a = RekordboxANLZ.parse([UInt8]((try? Data(contentsOf: dat)) ?? Data()))
                    if a.beats.isEmpty { add("anlz-grid", .warning, .analysis, "No beat grid: \(t.title)", "Its analysis file has no beats: SYNC and quantize won't work.", fix: .exportFixList) }
                    let ext = RekordboxANLZ.parse([UInt8]((try? Data(contentsOf: dat.deletingPathExtension().appendingPathExtension("EXT"))) ?? Data()))
                    let hot = (ext.hot.isEmpty ? a.hot : ext.hot).filter { $0.hot > req.hotCues }
                    if !hot.isEmpty {
                        add("hot", .info, .hardware, "Hot cues past \(String(UnicodeScalar(64 + req.hotCues)!)) on \(t.title)", "\(names) show \(req.hotCues) hot cues; \(hot.count) won't be there.")
                    }
                }
            }
            // FAT32: names that differ only in case, characters it can't hold, very long paths
            let lower = t.path.lowercased()
            if let other = seenCase[lower], other != t.path {
                add("case", .warning, .fileSystem, "Two files differ only in capitals", "\(other) and \(t.path): FAT32 treats them as one file.", fix: .exportFixList)
            } else { seenCase[lower] = t.path }
            if options.mode != .emergency {
                if t.path.rangeOfCharacter(from: CharacterSet(charactersIn: "?*:\"<>|\\")) != nil {
                    add("chars", .warning, .fileSystem, "Unusual characters in \(t.fileName)", "Some players and FAT32 can't handle ? * : \" < > | \\ in names.", fix: .exportFixList)
                }
                if t.path.utf8.count > 255 { add("long", .warning, .fileSystem, "Very long path: \(t.fileName)", "Over 255 bytes; older players may not open it.", fix: .exportFixList) }
            }
            if options.mode == .deep, let decode, let err = decode(url) {
                add("decode", sev, .audio, "Doesn't decode: \(t.title)", err, fix: .exportFixList)
            }
        }
        progress(1, "")
        // worst first, the set before the rest
        r.issues = out.enumerated().sorted { a, b in
            (a.element.severity.rawValue, a.element.inSet ? 1 : 0, -a.offset) > (b.element.severity.rawValue, b.element.inSet ? 1 : 0, -b.offset)
        }.map { $0.element }
        r.finished = Date()
        return r
    }
}
