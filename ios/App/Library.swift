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
    /// the stored grid is Apple's (AI mode's grid setting), not Cratebox's own: nil in older libraries
    var appleGrid: Bool? = nil
    /// why Cratebox's own analysis of this file failed last time (nil: it didn't), shown in Settings → Library & USB
    var fail: String? = nil
    /// the grid came from rekordbox's analysis on the stick (USB copies): a BPM range change leaves it alone
    var rbGrid: Bool? = nil
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
        info.appleGrid = r.appleGrid ?? false
        info.rbGrid = r.rbGrid ?? false
    }
    func sync() {
        rec.bpm = info.bpm; rec.firstBeat = info.firstBeat; rec.key = info.key; rec.duration = info.duration; rec.phrases = info.phrases
        rec.gridManual = info.gridManual; rec.autoBpm = info.autoBpm; rec.autoFirst = info.autoFirst
        rec.appleGrid = info.appleGrid ? true : nil
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
    /// folders on a drive that's ejected or unplugged: no access until it's back (true = it's been seen gone,
    /// so it's opened again when it answers; false = ejected but maybe still plugged in, so it waits)
    private(set) var offline = [String: Bool]()
    private var current: LibTrack?               // the track being analysed
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
        if offline[folder.id] != nil { return nil }
        if let u = open[folder.id] { return u }
        // the copies from USB sticks live in the app's own Documents, whose path can change with an app update
        if folder.id == UsbCopy.folderId { let u = UsbCopy.root; open[folder.id] = u; return u }
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
        if !device && Library.isRekordboxExport(u) { Devices.shared.open(u); u.stopAccessingSecurityScopedResource(); return nil }
        guard let bm = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { status("Couldn't keep access to \(u.lastPathComponent)"); return nil }
        let id = (device ? "usb-" : "dir-") + u.lastPathComponent
        let f = MusicFolder(id: id, name: u.lastPathComponent, bookmark: bm, device: device)
        folders.removeAll { $0.id == id }
        folders.append(f)
        if let old = open[id], old != u { old.stopAccessingSecurityScopedResource() }
        open[id] = u; offline[id] = nil
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
    /// let go of a folder's drive (eject, or it was unplugged): its tracks stay listed, its queued analysis is
    /// dropped and the security-scoped access ends, so nothing in Cratebox holds the drive open
    func release(_ f: MusicFolder, unplugged: Bool) {
        open[f.id]?.stopAccessingSecurityScopedResource(); open[f.id] = nil
        offline[f.id] = unplugged
        queue.removeAll { $0.rec.folder == f.id }
    }
    func seenGone(_ f: MusicFolder) { if offline[f.id] == false { offline[f.id] = true } }
    /// the drive is back: open it again (and look for new files on a music folder)
    func reconnect(_ f: MusicFolder) {
        offline[f.id] = nil
        if !f.device { scan(f) }
    }
    /// the drive's file is being read for analysis right now
    func analysing(in folderId: String) -> Bool { current?.rec.folder == folderId }
    private func saveFolders() { if let d = try? JSONEncoder().encode(folders) { try? d.write(to: dir.appendingPathComponent("folders.json")) } }

    func scan(_ f: MusicFolder) {
        guard let root = url(of: f) else { status("\(f.name): open it again in Files (Cratebox lost access)"); return }
        // a drive that isn't plugged in: keep its tracks (an empty scan would drop them) and wait for it
        guard (try? root.checkResourceIsReachable()) == true else { release(f, unplugged: true); return }
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
    /// every track on this device (not on a stick) by "file name|size": a stick track with the same name and size is
    /// already here, so a USB copy skips it (and a copied playlist uses the one that's here)
    func twins() -> [String: LibTrack] {
        Dictionary(tracks.filter { $0.device == nil }.map { (Library.twinKey(($0.rec.rel as NSString).lastPathComponent, $0.rec.size), $0) }, uniquingKeysWith: { a, _ in a })
    }
    static func twinKey(_ name: String, _ size: Int64) -> String { "\(name.lowercased())|\(size)" }
    /// tracks UsbCopy just copied into one of the library's folders: they join straight away with rekordbox's title,
    /// artist, grid and key (no rescan, no second analysis); ones without rekordbox's grid go to the analysis queue
    func addCopied(_ recs: [TrackRecord]) -> [LibTrack] {
        var out = [LibTrack]()
        for r in recs {
            if let t = byId[r.id] { out.append(t); continue }
            let t = LibTrack(r)
            tracks.append(t); byId[r.id] = t; out.append(t)
            if !t.analysed { queue.append(t) }
        }
        save(); runQueue()
        return out
    }
    /// tracks on a rekordbox stick join the library while it's open
    func setDeviceTracks(_ dev: String, _ list: [LibTrack]) {
        tracks = tracks.filter { $0.device != dev } + list
        byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func changed(_ t: LibTrack) { let f = t.rec.fail; t.sync(); t.rec.fail = f; save() }
    /// tracks Cratebox's own analysis couldn't do, with why (Settings → Library & USB)
    var failed: [LibTrack] { tracks.filter { $0.device == nil && $0.rec.fail != nil } }
    /// try the failed ones again (after plugging the drive back in, adding the folder again, …)
    func retryFailed() {
        for t in failed { t.rec.fail = nil; t.rec.ver = 0; t.info.bpm = nil; if !queue.contains(where: { $0 === t }) { queue.append(t) } }
        objectWillChange.send(); save(); runQueue()
    }
    /// a decoding error in words
    static func reason(_ e: Error, _ url: URL) -> String {
        if !FileManager.default.fileExists(atPath: url.path) { return "The file isn't there any more (moved, renamed or deleted)" }
        let ext = url.pathExtension.lowercased()
        if ext == "m4p" { return "Protected (DRM) file: iOS won't let apps read it" }
        if e is AudioDecoder.Failure { return "The file opened but no audio came out (empty or damaged)" }
        let ns = e as NSError
        if ns.domain == NSOSStatusErrorDomain || ns.domain == "com.apple.coreaudio.avfaudio" {
            return ["ogg", "opus", "wma", "ape", "dsf", "dff"].contains(ext) ? "iOS can't play .\(ext) files" : "iOS can't read this file (unsupported format or damaged; code \(ns.code))"
        }
        return ns.localizedDescription
    }
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
    /// Settings → Decks → BPM range changed (checked when Settings closes, so the steppers don't start a run per
    /// tap): the tracks Cratebox analysed itself go round again. A grid you set and rekordbox's analysis stay.
    func bpmRangeChanged() {
        let now = "\(Settings.bpmRange)", k = "cb.bpmRangeAnalysed"
        let was = UserDefaults.standard.string(forKey: k)
        UserDefaults.standard.set(now, forKey: k)
        guard let was, was != now else { return }          // first run: the library was analysed with this range
        // rekordbox's grids on USB copies stay (copies from before rbGrid existed count as rekordbox's too)
        let again = tracks.filter { $0.device == nil && !$0.rec.gridManual && $0.analysed
            && !($0.rec.rbGrid ?? ($0.rec.folder == UsbCopy.folderId)) }
        for t in again { t.rec.ver = 0; if !queue.contains(where: { $0 === t }) { queue.append(t) } }
        if !again.isEmpty { status("BPM range changed: analysing \(again.count) track\(again.count == 1 ? "" : "s") again") }
        save(); runQueue()
    }
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
        analysing = true; current = t
        progress = "Analysing \(queue.count + 1) track\(queue.isEmpty ? "" : "s")…"
        let url = fileURL(t), grid = t.rec.gridManual ? (t.rec.bpm ?? 0, t.rec.firstBeat ?? 0) : nil
        let range = Settings.bpmRange           // Settings → Decks → BPM range, as for a track analysed at load
        DispatchQueue.global(qos: .utility).async {
            var res: (AnalysisResult, Double)?, why: String?
            // only the 11 kHz mono is kept while decoding (~20 MB for 8 minutes, not the ~180 MB stereo track)
            if let url {
                let open = url.startAccessingSecurityScopedResource()
                defer { if open { url.stopAccessingSecurityScopedResource() } }
                do {
                    let m = try AudioDecoder.analysisMono(url)
                    let r = Analysis.analyze(m.x, fs: m.fs, range: range, noWave: true, grid: grid.map { (bpm: $0.0, firstBeat: $0.1) })
                    res = (r, m.duration)
                    if r.bpm <= 0 { why = "No steady beat found (beatless, very short, or mostly silence)" }
                } catch { why = Library.reason(error, url) }
            } else { why = "Its folder isn't reachable: the drive is unplugged, or Cratebox lost permission (add the folder again in the library)" }
            DispatchQueue.main.async {
                self.analysing = false; self.current = nil
                t.rec.fail = why
                if let why { self.status("Couldn't analyse \(t.rec.title): \(why)") }
                if case let (r, dur)? = res, r.bpm > 0 {
                    t.info.bpm = r.bpm; t.info.firstBeat = r.firstBeat; t.info.phrases = r.phrases; t.info.duration = dur
                    t.info.appleGrid = false
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

/// Decoding for the decks and the analysis: 32-bit float stereo at the engine's rate, read and resampled in blocks
/// of about a second. A deck's track is written straight into its own buffers (one copy of the song in memory,
/// not two plus the file's); the library's analysis keeps only the 11 kHz mono it needs (`analysisMono`).
enum AudioDecoder {
    enum Failure: Error { case cantRead }
    static let block: AVAudioFrameCount = 48000
    static func decode(_ url: URL, rate: Double = AudioHost.sampleRate) throws -> PCMTrack {
        let f = try AVAudioFile(forReading: url)
        // room for the whole song at `rate`, plus the resampler's slack; grown if a file runs longer than it says
        var cap = Int((Double(f.length) * rate / f.processingFormat.sampleRate).rounded(.up)) + 4096
        var l = UnsafeMutablePointer<Float>.allocate(capacity: cap), r = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        var n = 0
        do {
            try stream(f, rate: rate) { a, b, c in
                if n + c > cap {
                    let nc = max(cap * 5 / 4, n + c)
                    let l2 = UnsafeMutablePointer<Float>.allocate(capacity: nc), r2 = UnsafeMutablePointer<Float>.allocate(capacity: nc)
                    l2.update(from: l, count: n); r2.update(from: r, count: n); l.deallocate(); r.deallocate()
                    l = l2; r = r2; cap = nc
                }
                (l + n).update(from: a, count: c); (r + n).update(from: b, count: c); n += c
            }
        } catch { l.deallocate(); r.deallocate(); throw error }
        if n == 0 { l.deallocate(); r.deallocate(); throw Failure.cantRead }
        return PCMTrack(adopting: l, r, count: n, sampleRate: rate)
    }
    /// The library's analysis input: the same samples as `mono(decode(url), target)`, without the stereo copy.
    static func analysisMono(_ url: URL, rate: Double = AudioHost.sampleRate, target: Double = 11025) throws -> (x: [Float], fs: Double, duration: Double) {
        let f = try AVAudioFile(forReading: url)
        var acc = Analysis.MonoAccumulator(sampleRate: rate, target: target)
        acc.reserve(frames: Int(Double(f.length) * rate / f.processingFormat.sampleRate) + 4096)
        try stream(f, rate: rate) { a, b, c in acc.add(a, b, count: c) }
        if acc.frames == 0 { throw Failure.cantRead }
        return (acc.out, acc.fs, Double(acc.frames) / rate)
    }
    /// Reads `f` in blocks, resampled to `rate` if it's at another one, and hands each block over as left and right
    /// (left twice for a mono file, the first two channels of anything wider; as before).
    private static func stream(_ f: AVAudioFile, rate: Double, _ out: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) throws {
        let fmt = f.processingFormat, nc = Int(fmt.channelCount)
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: block) else { throw Failure.cantRead }
        func send(_ buf: AVAudioPCMBuffer) {
            guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
            out(UnsafePointer(ch[0]), UnsafePointer(ch[nc > 1 ? 1 : 0]), Int(buf.frameLength))
        }
        // reads the next block; false at the end of the file (AVAudioFile throws or reads nothing there)
        func next() throws -> Bool {
            if f.framePosition >= f.length { return false }
            try f.read(into: src, frameCount: block)
            return src.frameLength > 0
        }
        if fmt.sampleRate == rate {
            while try next() { send(src) }
            return
        }
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: fmt.channelCount, interleaved: false)!
        guard let conv = AVAudioConverter(from: fmt, to: outFmt),
              let dst = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(block) * rate / fmt.sampleRate) + 1024) else { throw Failure.cantRead }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var ended = false, readErr: Error?
        while true {
            dst.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: dst, error: &err) { _, status in
                if ended { status.pointee = .endOfStream; return nil }
                do { if try next() { status.pointee = .haveData; return src } } catch { readErr = error }
                ended = true; status.pointee = .endOfStream; return nil
            }
            if let err { throw err }
            if let readErr { throw readErr }
            send(dst)
            if st == .endOfStream || st == .error { break }
        }
    }
    static func mono(_ t: PCMTrack, _ target: Double) -> (x: [Float], fs: Double) {
        let m = Analysis.monoFor([UnsafePointer(t.left), UnsafePointer(t.right)], length: t.count, sampleRate: t.sampleRate, target: target)
        return (m.mono, m.fs)
    }
}
