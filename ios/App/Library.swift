// The library: music folders picked in the Files app (kept as security-scoped bookmarks, so they come back
// after a restart), their audio files with tags, and each track's analysis, cached on the device. Like the web
// app, Cratebox reads the files in place: nothing is copied.
import AVFoundation
import Foundation
import CrateboxKit

struct TrackRecord: Codable {
    var id: String
    var folder: String          // the folder's bookmark key (or a stick's id)
    var rel: String             // path inside the folder
    var title: String, artist: String
    var size: Int64, mtime: Double
    var bpm: Double?, firstBeat: Double?, key: Int, duration: Double
    var phrases: [Phrase]
    var gridManual: Bool, autoBpm: Double?, autoFirst: Double?
    var ver: Int
}

final class LibTrack: Identifiable {
    var rec: TrackRecord
    let info: TrackInfo
    var id: String { rec.id }
    /// rekordbox stick tracks: the stick and the track's row in its export.pdb
    var device: String?
    var rb: PDBTrack?
    init(_ r: TrackRecord) {
        rec = r
        info = TrackInfo(id: r.id, title: r.title, artist: r.artist, bpm: r.bpm, firstBeat: r.firstBeat, key: r.key, duration: r.duration, phrases: r.phrases)
        info.gridManual = r.gridManual; info.autoBpm = r.autoBpm; info.autoFirst = r.autoFirst
    }
    func sync() {
        rec.bpm = info.bpm; rec.firstBeat = info.firstBeat; rec.key = info.key; rec.duration = info.duration; rec.phrases = info.phrases
        rec.gridManual = info.gridManual; rec.autoBpm = info.autoBpm; rec.autoFirst = info.autoFirst
    }
    var analysed: Bool { rec.ver == Library.ANALYSIS_VER && (rec.bpm ?? 0) > 0 }
}

struct MusicFolder: Codable, Identifiable { var id: String; var name: String; var bookmark: Data; var device: Bool }

final class Library: ObservableObject {
    static let ANALYSIS_VER = 7
    static let audioExt: Set<String> = ["mp3", "wav", "wave", "flac", "m4a", "aac", "aif", "aiff", "caf", "mp4", "alac"]
    @Published private(set) var tracks: [LibTrack] = []
    @Published private(set) var folders: [MusicFolder] = []
    @Published var progress = ""
    var status: (String) -> Void = { _ in }
    var isPlaying: () -> Bool = { false }
    private var byId = [String: LibTrack]()
    private var open = [String: URL]()           // resolved, security-scoped folder URLs
    private let dir: URL
    private var saveWork: DispatchWorkItem?
    private var queue = [LibTrack]()
    private var analysing = false

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cratebox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: dir.appendingPathComponent("folders.json")), let f = try? JSONDecoder().decode([MusicFolder].self, from: d) { folders = f }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("library.json")), let r = try? JSONDecoder().decode([TrackRecord].self, from: d) {
            tracks = r.map(LibTrack.init); for t in tracks { byId[t.id] = t }
        }
    }
    func track(_ id: String) -> LibTrack? { byId[id] }
    /// the simulator screenshots only
    func setDemoTracks(_ ts: [LibTrack]) { for t in ts { t.rec.ver = Library.ANALYSIS_VER; tracks.append(t); byId[t.id] = t } }

    // ---- folders ----
    func url(of folder: MusicFolder) -> URL? {
        if let u = open[folder.id] { return u }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = u.startAccessingSecurityScopedResource()
        open[folder.id] = u
        return u
    }
    static func isRekordboxExport(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.appendingPathComponent("PIONEER/rekordbox/export.pdb").path) }
    func addFolder(_ u: URL, device: Bool = false) -> MusicFolder? {
        _ = u.startAccessingSecurityScopedResource()
        // a rekordbox USB/SD picked as a music folder: open it as the device it is (playlists, grids, keys, cues)
        if !device && Library.isRekordboxExport(u) { Devices.shared.open(u); return nil }
        guard let bm = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { status("Couldn't keep access to \(u.lastPathComponent)"); return nil }
        let id = (device ? "usb-" : "dir-") + u.lastPathComponent
        let f = MusicFolder(id: id, name: u.lastPathComponent, bookmark: bm, device: device)
        folders.removeAll { $0.id == id }
        folders.append(f)
        open[id] = u
        saveFolders()
        if !device { scan(f) }
        return f
    }
    func removeFolder(_ f: MusicFolder) {
        folders.removeAll { $0.id == f.id }
        open[f.id]?.stopAccessingSecurityScopedResource(); open[f.id] = nil
        tracks.removeAll { $0.rec.folder == f.id }
        byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        saveFolders(); save()
    }
    private func saveFolders() { if let d = try? JSONEncoder().encode(folders) { try? d.write(to: dir.appendingPathComponent("folders.json")) } }

    func scan(_ f: MusicFolder) {
        guard let root = url(of: f) else { status("\(f.name): open it again in Files (Cratebox lost access)"); return }
        progress = "Scanning \(f.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            var found = [(String, Int64, Double)]()
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let u as URL in en where Library.audioExt.contains(u.pathExtension.lowercased()) {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true else { continue }
                    let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
                    found.append((rel, Int64(v?.fileSize ?? 0), v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
                }
            }
            DispatchQueue.main.async { self.merge(f, found) }
        }
    }
    private func merge(_ f: MusicFolder, _ found: [(String, Int64, Double)]) {
        var keep = [LibTrack]()
        var fresh = [LibTrack]()
        for (rel, size, mtime) in found {
            let id = "\(f.id)|\(rel)|\(size)"
            if let t = byId[id] { keep.append(t); continue }
            let name = (rel as NSString).lastPathComponent, stem = (name as NSString).deletingPathExtension
            let parts = stem.components(separatedBy: " - ")
            let r = TrackRecord(id: id, folder: f.id, rel: rel, title: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : stem, artist: parts.count > 1 ? parts[0] : "",
                                size: size, mtime: mtime, bpm: nil, firstBeat: nil, key: -1, duration: 0, phrases: [], gridManual: false, autoBpm: nil, autoFirst: nil, ver: 0)
            let t = LibTrack(r); keep.append(t); fresh.append(t)
        }
        tracks = tracks.filter { $0.rec.folder != f.id } + keep
        byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        progress = ""
        status("\(f.name): \(keep.count) tracks\(fresh.isEmpty ? "" : ", \(fresh.count) new")")
        save()
        readTags(fresh)
        for t in keep where !t.analysed { queue.append(t) }
        runQueue()
    }
    private func readTags(_ list: [LibTrack]) {
        for t in list {
            guard let u = fileURL(t) else { continue }
            Task {
                let a = AVURLAsset(url: u)
                guard let md = try? await a.load(.commonMetadata) else { return }
                var title: String?, artist: String?
                for item in md {
                    if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
                    if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
                }
                await MainActor.run {
                    if let title, !title.isEmpty { t.rec.title = title; t.info.title = title }
                    if let artist, !artist.isEmpty { t.rec.artist = artist; t.info.artist = artist }
                    self.objectWillChange.send(); self.save()
                }
            }
        }
    }
    func fileURL(_ t: LibTrack) -> URL? {
        guard let f = folders.first(where: { $0.id == t.rec.folder }), let root = url(of: f) else { return nil }
        return root.appendingPathComponent(t.rec.rel)
    }
    /// tracks on a rekordbox stick join the library while it's open
    func setDeviceTracks(_ dev: String, _ list: [LibTrack]) {
        tracks = tracks.filter { $0.device != dev } + list
        byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func changed(_ t: LibTrack) { t.sync(); save() }
    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let recs = self.tracks.filter { $0.device == nil }.map { $0.rec }
            if let d = try? JSONEncoder().encode(recs) { try? d.write(to: self.dir.appendingPathComponent("library.json"), options: .atomic) }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // ---- analysis in the background (one at a time, paused while the decks play on small devices) ----
    func enqueue(_ t: LibTrack) { if !queue.contains(where: { $0 === t }) { queue.append(t) }; runQueue() }
    func runQueue() {
        guard !analysing else { return }
        guard let t = queue.first else { if !progress.hasPrefix("Scanning") { progress = "" }; return }
        if ProcessInfo.processInfo.activeProcessorCount <= 4 && isPlaying() {
            progress = "Analysis paused while playing"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.runQueue() }
            return
        }
        queue.removeFirst()
        if t.analysed { runQueue(); return }
        // rekordbox USB tracks: rekordbox already analysed them; use that (Cratebox analyses only if it's missing)
        if t.device != nil {
            Devices.shared.readAnalysis(t)
            if (t.info.bpm ?? 0) > 0 && t.info.firstBeat != nil { t.rec.ver = Library.ANALYSIS_VER; changed(t); DispatchQueue.main.async { self.runQueue() }; return }
        }
        analysing = true
        progress = "Analysing \(queue.count + 1) track\(queue.isEmpty ? "" : "s")…"
        let url = fileURL(t), grid = t.rec.gridManual ? (t.rec.bpm ?? 0, t.rec.firstBeat ?? 0) : nil
        DispatchQueue.global(qos: .utility).async {
            var res: (AnalysisResult, Double)?
            if let url, let pcm = try? AudioDecoder.decode(url) {
                let m = AudioDecoder.mono(pcm, 11025)
                let r = Analysis.analyze(m.x, fs: m.fs, noWave: true, grid: grid.map { (bpm: $0.0, firstBeat: $0.1) })
                res = (r, Double(pcm.count) / pcm.sampleRate)
            }
            DispatchQueue.main.async {
                self.analysing = false
                if let (r, dur) = res {
                    t.info.bpm = r.bpm; t.info.firstBeat = r.firstBeat; t.info.phrases = r.phrases; t.info.duration = dur
                    if !t.info.keyFromRekordbox { t.info.key = r.key }
                    t.rec.ver = Library.ANALYSIS_VER
                    if !t.info.gridManual { t.info.autoBpm = r.bpm; t.info.autoFirst = r.firstBeat }
                    self.changed(t)
                } else { t.rec.ver = Library.ANALYSIS_VER; t.info.bpm = 0; self.changed(t) }
                self.objectWillChange.send()
                self.runQueue()
            }
        }
    }
}

/// Decoding for the decks and the analysis: the whole file, as 32-bit float stereo at the engine's rate.
enum AudioDecoder {
    enum Failure: Error { case cantRead }
    static func decode(_ url: URL, rate: Double = AudioHost.sampleRate) throws -> PCMTrack {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { throw Failure.cantRead }
        try f.read(into: src)
        var buf = src
        if fmt.sampleRate != rate {
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: fmt.channelCount, interleaved: false)!
            guard let conv = AVAudioConverter(from: fmt, to: outFmt),
                  let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * rate / fmt.sampleRate) + 1024) else { throw Failure.cantRead }
            conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return src
            }
            if let err { throw err }
            buf = out
        }
        guard let ch = buf.floatChannelData else { throw Failure.cantRead }
        let n = Int(buf.frameLength), nc = Int(buf.format.channelCount)
        let t = PCMTrack(count: n, sampleRate: rate)
        t.left.update(from: ch[0], count: n)
        t.right.update(from: ch[nc > 1 ? 1 : 0], count: n)
        return t
    }
    static func mono(_ t: PCMTrack, _ target: Double) -> (x: [Float], fs: Double) {
        let m = Analysis.monoFor([UnsafePointer(t.left), UnsafePointer(t.right)], length: t.count, sampleRate: t.sampleRate, target: target)
        return (m.mono, m.fs)
    }
}
