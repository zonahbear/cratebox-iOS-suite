// Cratebox USB: one view of a rekordbox stick that may carry two libraries at once, the Device Library
// (export.pdb, read by most players) and OneLibrary (exportLibrary.db, read by the newer ones). Tracks are
// matched between the two by their path on the stick; playlists by their place in the tree (folder names
// down to the playlist's own name). Where the two disagree, that's a sync conflict: a player reading the
// other library would see something different from what you prepared.
import Foundation

public struct USBTrack: Identifiable, Equatable {
    public var id: String { key }
    public let key: String                         // the path on the stick, lower-cased, leading "/" kept
    public var path: String                        // as stored ("/Contents/Artist/Album/file.mp3")
    public var title: String, artist: String, album: String, genre: String, label: String, keyName: String, comment: String
    public var bpm: Double, duration: Double       // seconds
    public var fileSize: Int64, sampleRate: Int, bitrate: Int, bitDepth: Int
    public var anlzPath: String
    public var rating: Int, color: Int
    public var pdbId: UInt32?, olId: Int64?
    public var fileName: String { (path as NSString).lastPathComponent }
    public var ext: String { (path as NSString).pathExtension.lowercased() }
    public static func key(_ path: String) -> String { (path.hasPrefix("/") ? path : "/" + path).lowercased() }
}

public struct USBPlaylist: Identifiable, Equatable {
    public var id: String { treePath.joined(separator: "\u{1f}") }
    public var name: String
    public var folder: Bool
    public var treePath: [String]                  // names from the top level down, this one last
    public var depth: Int { treePath.count - 1 }
    public var tracks: [String]                    // track keys, in order
    public var pdbId: UInt32?, olId: Int64?
}

public enum USBLibraryKind: String, Codable { case deviceLibrary = "Device Library", oneLibrary = "OneLibrary" }

public struct USBSyncDifference: Identifiable, Equatable {
    public enum Kind: String { case trackOnlyInDeviceLibrary, trackOnlyInOneLibrary, metadataDiffers, playlistOnlyInDeviceLibrary, playlistOnlyInOneLibrary, playlistContentDiffers }
    public var id: String { kind.rawValue + "|" + subject }
    public let kind: Kind
    public let subject: String                     // track key or playlist id
    public let detail: String
}

public struct USBLibrary {
    public var hasDeviceLibrary: Bool { pdb != nil }
    public var hasOneLibrary: Bool { one != nil }
    public private(set) var pdb: PDBDatabase?
    public private(set) var one: OneLibraryDatabase?
    public var oneError: String?                   // OneLibrary present but unreadable
    public private(set) var tracks: [USBTrack] = []
    public private(set) var playlists: [USBPlaylist] = []      // tree order (folders before their contents)
    public private(set) var byKey: [String: Int] = [:]
    public private(set) var differences: [USBSyncDifference] = []

    public init(pdb: PDBDatabase?, one: OneLibraryDatabase?, oneError: String? = nil) {
        self.pdb = pdb; self.one = one; self.oneError = oneError
        merge()
    }
    public func track(_ key: String) -> USBTrack? { byKey[key].map { tracks[$0] } }

    mutating func merge() {
        var list = [USBTrack](), idx = [String: Int]()
        func add(_ t: USBTrack) { if let i = idx[t.key] { if list[i].olId == nil { list[i].olId = t.olId } } else { idx[t.key] = list.count; list.append(t) } }
        var pdbKeyOf = [UInt32: String](), olKeyOf = [Int64: String]()
        if let p = pdb {
            for r in p.tracks {
                let k = USBTrack.key(r.path)
                pdbKeyOf[r.id] = k
                add(USBTrack(key: k, path: r.path, title: r.title.isEmpty ? r.filename : r.title, artist: r.artist, album: r.album, genre: r.genre, label: r.label,
                             keyName: r.key, comment: r.comment, bpm: r.bpm, duration: Double(r.duration), fileSize: Int64(r.size), sampleRate: Int(r.sampleRate),
                             bitrate: 0, bitDepth: 0, anlzPath: r.anlzPath, rating: r.rating, color: r.color, pdbId: r.id, olId: nil))
            }
        }
        if let o = one {
            for r in o.tracks {
                let k = USBTrack.key(r.path)
                olKeyOf[r.id] = k
                if let i = idx[k] {
                    list[i].olId = r.id
                    if list[i].bitDepth == 0 { list[i].bitDepth = Int(r.bitDepth) }
                    if list[i].bitrate == 0 { list[i].bitrate = Int(r.bitrate) }
                } else {
                    add(USBTrack(key: k, path: r.path, title: r.title.isEmpty ? r.fileName : r.title, artist: r.artist, album: r.album, genre: r.genre, label: r.label,
                                 keyName: r.key, comment: r.comment, bpm: r.bpm, duration: Double(r.durationMs) / 1000, fileSize: r.fileSize, sampleRate: Int(r.sampleRate),
                                 bitrate: Int(r.bitrate), bitDepth: Int(r.bitDepth), anlzPath: r.anlzPath, rating: Int(r.rating), color: Int(r.color), pdbId: nil, olId: r.id))
                }
            }
        }
        tracks = list; byKey = idx
        // playlists: Device Library's tree first, OneLibrary's merged in by tree path
        var pls = [USBPlaylist](), pidx = [String: Int]()
        func walkPDB(_ p: PDBDatabase) {
            let byParent = Dictionary(grouping: p.playlists, by: { $0.parent })
            func go(_ parent: UInt32, _ path: [String]) {
                for n in (byParent[parent] ?? []).sorted(by: { $0.sort < $1.sort }) {
                    let tp = path + [n.name]
                    var u = USBPlaylist(name: n.name, folder: n.folder, treePath: tp, tracks: n.tracks.compactMap { pdbKeyOf[$0] }, pdbId: n.id, olId: nil)
                    if pidx[u.id] != nil { u.treePath[u.treePath.count - 1] += " (\(n.id))" }
                    pidx[u.id] = pls.count; pls.append(u)
                    if n.folder { go(n.id, u.treePath) }
                }
            }
            go(0, [])
        }
        func walkOL(_ o: OneLibraryDatabase) {
            let byParent = Dictionary(grouping: o.playlists, by: { $0.parent })
            func go(_ parent: Int64, _ path: [String]) {
                for n in (byParent[parent] ?? []).sorted(by: { $0.seq < $1.seq }) {
                    let tp = path + [n.name]
                    let id = tp.joined(separator: "\u{1f}")
                    if let i = pidx[id], pls[i].olId == nil, pls[i].folder == n.folder { pls[i].olId = n.id }
                    else {
                        pidx[id] = pls.count
                        pls.append(USBPlaylist(name: n.name, folder: n.folder, treePath: tp, tracks: n.tracks.compactMap { olKeyOf[$0] }, pdbId: nil, olId: n.id))
                    }
                    if n.folder { go(n.id, tp) }
                }
            }
            go(0, [])
        }
        if let p = pdb { walkPDB(p) }
        if let o = one { walkOL(o) }
        playlists = pls
        // differences, only when both libraries are there
        var diffs = [USBSyncDifference]()
        if let p = pdb, let o = one {
            let pk = Set(p.tracks.map { USBTrack.key($0.path) }), ok = Set(o.tracks.map { USBTrack.key($0.path) })
            for k in pk.subtracting(ok).sorted() { diffs.append(.init(kind: .trackOnlyInDeviceLibrary, subject: k, detail: "Only in the Device Library: players reading OneLibrary won't list it")) }
            for k in ok.subtracting(pk).sorted() { diffs.append(.init(kind: .trackOnlyInOneLibrary, subject: k, detail: "Only in OneLibrary: players reading the Device Library won't list it")) }
            let olByKey = Dictionary(o.tracks.map { (USBTrack.key($0.path), $0) }, uniquingKeysWith: { a, _ in a })
            for r in p.tracks {
                guard let q = olByKey[USBTrack.key(r.path)] else { continue }
                var what = [String]()
                if !r.title.isEmpty && !q.title.isEmpty && r.title != q.title { what.append("title") }
                if r.artist != q.artist && !(r.artist.isEmpty || q.artist.isEmpty) { what.append("artist") }
                if r.bpm > 0 && q.bpm > 0 && abs(r.bpm - q.bpm) > 0.011 { what.append(String(format: "BPM %.2f vs %.2f", r.bpm, q.bpm)) }
                if !r.key.isEmpty && !q.key.isEmpty && RekordboxANLZ.keyIndex(r.key) != RekordboxANLZ.keyIndex(q.key) { what.append("key \(r.key) vs \(q.key)") }
                if !what.isEmpty { diffs.append(.init(kind: .metadataDiffers, subject: USBTrack.key(r.path), detail: "The two libraries disagree on " + what.joined(separator: ", "))) }
            }
            for u in pls {
                if u.pdbId != nil && u.olId == nil { diffs.append(.init(kind: .playlistOnlyInDeviceLibrary, subject: u.id, detail: "\"\(u.name)\" is only in the Device Library")) }
                else if u.olId != nil && u.pdbId == nil { diffs.append(.init(kind: .playlistOnlyInOneLibrary, subject: u.id, detail: "\"\(u.name)\" is only in OneLibrary")) }
                else if let pi = u.pdbId, let oi = u.olId, !u.folder {
                    let a = p.playlists.first { $0.id == pi }?.tracks.compactMap { pdbKeyOf[$0] } ?? []
                    let b = o.playlists.first { $0.id == oi }?.tracks.compactMap { olKeyOf[$0] } ?? []
                    if a != b {
                        let why = Set(a) == Set(b) ? "same tracks in a different order" : "\(a.count) tracks vs \(b.count), \(Set(a).symmetricDifference(Set(b)).count) differ"
                        diffs.append(.init(kind: .playlistContentDiffers, subject: u.id, detail: "\"\(u.name)\": \(why)"))
                    }
                }
            }
        }
        differences = diffs
    }

    /// bit rate / bit depth from export.pdb's track rows (PDB.trackFormats), where the merge left them unknown
    public mutating func setFormats(_ f: [UInt32: PDBTrackFormat]) {
        for i in tracks.indices {
            guard let id = tracks[i].pdbId, let x = f[id] else { continue }
            if tracks[i].bitDepth == 0 { tracks[i].bitDepth = x.bitDepth }
            if tracks[i].bitrate == 0 { tracks[i].bitrate = x.bitrate }
            if tracks[i].sampleRate == 0 { tracks[i].sampleRate = x.sampleRate }
        }
    }

    public var inSync: Bool { differences.isEmpty }
    public func playlist(_ id: String) -> USBPlaylist? { playlists.first { $0.id == id } }
    /// tracks of a playlist, or of a folder and everything under it
    public func trackKeys(of id: String) -> [String] {
        guard let p = playlist(id) else { return [] }
        if !p.folder { return p.tracks }
        var seen = Set<String>(), out = [String]()
        for q in playlists where !q.folder && q.treePath.count > p.treePath.count && Array(q.treePath.prefix(p.treePath.count)) == p.treePath {
            for k in q.tracks where seen.insert(k).inserted { out.append(k) }
        }
        return out
    }
}
