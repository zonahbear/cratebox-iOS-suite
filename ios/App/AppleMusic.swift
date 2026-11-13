// AI mode (Settings → AI mode) and Apple's Music Understanding analysis.
//
// AI mode is one switch for every AI feature in the app, off by default: Ask the library (SmartSearch.swift,
// Apple Intelligence, iOS 26+) and Apple's Music Understanding (this file, iOS 27+). Both run on the device only;
// nothing is sent anywhere.
//
// Music Understanding (Apple, iOS 27): beats, bars, BPM, key over time, sections/segments/phrases, pace, where the
// vocals / drums / bass are, and loudness in LUFS. Here it runs in the background, one track at a time and only
// while nothing is playing, and its results are kept beside Cratebox's own analysis. Its grid is used at load in the
// order Settings → Library & USB → Beat grids says (by default: a grid you set, then Apple's, then rekordbox's, then
// Cratebox's); key, phrases and cues are never changed. Settings → Library & USB → Beat grids →
// Compare shows how Apple's beats and bars sit against those grids, and exports it as a CSV, so the two can be
// judged on real tracks before Apple's results are used for anything.
//
// The framework is only in the iOS 27 SDK (Xcode 27). Built with an older Xcode, `canImport(MusicUnderstanding)`
// is false, this part compiles to "not in this build" and Settings says so.
import AVFoundation
import Combine
import CryptoKit
import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import BackgroundTasks
import CrateboxKit
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

enum AIMode {
    static let key = "cb.ai"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Settings → Library & USB → Beat grids: whose grid a track gets when it's loaded. Jonah's order (2026-11-12): a grid
/// you set here always wins (gridManual), then Apple's (AI mode on a device that has it), then rekordbox's, then
/// Cratebox's own analysis. `cb.grid.order`: 0 = that order (default), 1 = rekordbox before Apple, 2 = no Apple grids.
/// Replaces `cb.ai.grid` (off by default), so the order holds without anyone changing a setting.
enum AppleGridMode: Int {
    case off        // rekordbox's, or Cratebox's own analysis
    case prefer     // Apple's instead of Cratebox's own; rekordbox's grids stay
    case only       // Apple's instead of rekordbox's too
    static let key = "cb.grid.order"
    static var now: AppleGridMode {
        guard AIMode.on && AppleMusic.usable else { return .off }
        switch UserDefaults.standard.integer(forKey: key) {
        case 1: return .prefer
        case 2: return .off
        default: return .only
        }
    }
}

/// The library's MATCH sort: how well each track would follow what's playing, onto the deck that's free
enum Suggest {
    struct Context { let now: NextTrack.Item, opts: NextTrack.Options, target: Int }
    static weak var app: AppModel?
    private static var memo: (at: Double, ctx: Context?)?
    /// what's heard now (the playing deck started last, else any loaded deck) and the deck a track would go on.
    /// Kept for half a second: every row of the list asks
    static func context() -> Context? {
        let t = ProcessInfo.processInfo.systemUptime
        if let m = memo, t - m.at < 0.5 { return m.ctx }
        let ctx = build()
        memo = (t, ctx)
        return ctx
    }
    private static func build() -> Context? {
        guard let app else { return nil }
        let decks = app.core.activeDecks.map { app.core.decks[$0] }
        let ready = decks.filter { $0.loaded && $0.bpm > 0 }
        guard let on = ready.filter({ $0.playing }).max(by: { $0.startedAt < $1.startedAt }) ?? ready.first else { return nil }
        let target = decks.first { $0 !== on && !$0.playing } ?? decks.first { $0 !== on } ?? on
        var now = NextTrack.Item(id: on.track?.id ?? "", bpm: on.effBpm(), key: on.keyNow())
        if let l = AppleMusic.shared.lite(now.id) { now.energy = l.lufs.map { NextTrack.energy(lufs: $0) }; now.shares = l.shares }
        return Context(now: now, opts: NextTrack.Options(range: target.range, keylock: target.mt), target: target.i)
    }
    static func score(_ t: LibTrack, _ c: Context) -> NextTrack.Result? {
        guard let b = t.info.bpm, b > 0 else { return nil }
        var it = NextTrack.Item(id: t.id, bpm: b, key: t.info.key)
        if let l = AppleMusic.shared.lite(t.id) { it.energy = l.lufs.map { NextTrack.energy(lufs: $0) }; it.shares = l.shares }
        return NextTrack.score(now: c.now, cand: it, c.opts)
    }
    /// "87" for a row, "" when there's nothing playing to match or the track can't follow on that deck
    static func label(_ t: LibTrack?) -> String {
        guard AIMode.on, let t, let c = context(), let r = score(t, c) else { return "" }
        return String(Int(r.score.rounded()))
    }
}

/// When the screen was last touched, so the background analysis stays out of the way while the app is in use.
/// A recogniser on the window that only looks: it fails at once, so no touch is delayed or taken.
final class TouchWatch: UIGestureRecognizer {
    static var last = ProcessInfo.processInfo.systemUptime
    private static var installed = false
    static func install() {
        guard !installed else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard !windows.isEmpty else { return }
        for w in windows {
            let g = TouchWatch(target: nil, action: nil)
            g.cancelsTouchesInView = false; g.delaysTouchesBegan = false; g.delaysTouchesEnded = false
            w.addGestureRecognizer(g)
        }
        installed = true
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        TouchWatch.last = ProcessInfo.processInfo.systemUptime
        state = .failed
    }
}

final class AppleMusic: ObservableObject {
    static let shared = AppleMusic()
    /// this build has the framework (made with the iOS 27 SDK)
    static var builtIn: Bool {
        #if canImport(MusicUnderstanding)
        return true
        #else
        return false
        #endif
    }
    static var osSupports: Bool { if #available(iOS 27, *) { return true } else { return false } }
    static var usable: Bool { builtIn && osSupports }
    /// why it can't run here, for Settings (nil when it can)
    static var unavailableReason: String? {
        if !builtIn { return "Not in this build: it was made with an Xcode older than 27, which doesn't have Apple's Music Understanding." }
        if !osSupports { return "Needs iOS 27 or later." }
        return nil
    }

    @Published private(set) var progress = ""
    @Published private(set) var analysed = 0
    /// the tracks you asked Apple to analyse (Settings → AI, or long-press → Analyse). Nothing is analysed unless
    /// it's asked for (Jonah, 2026-11-13): it used to start on every track by itself
    @Published private(set) var wanted: [String] = UserDefaults.standard.stringArray(forKey: "cb.apple.wanted") ?? [] {
        didSet { UserDefaults.standard.set(wanted, forKey: "cb.apple.wanted") }
    }
    /// how many of the asked-for tracks still need doing
    var waiting: Int {
        guard let app else { return 0 }
        let want = Set(wanted)
        // a stick track and its copy here are one song: counted (and analysed) once, as the copy
        return app.library.preferLocal(app.library.tracks.filter { want.contains($0.id) }).filter { needs($0) }.count
    }
    private func needs(_ t: LibTrack) -> Bool { source(t) == nil && (index[t.id].map { !current($0, t) } ?? true) }
    /// ask for these tracks (already analysed ones, and ones sharing a twin's results, are skipped)
    func request(_ tracks: [LibTrack]) {
        let todo = (app?.library.preferLocal(tracks) ?? tracks).filter { needs($0) }.map(\.id)
        let have = Set(wanted)
        let add = todo.filter { !have.contains($0) }
        wanted += add
        if !add.isEmpty { startBackground(add.count) }
        app?.status(todo.isEmpty ? "Already analysed" : "Apple will analyse \(todo.count) track\(todo.count == 1 ? "" : "s") while nothing plays")
        kick()
    }
    /// forget what's asked for and stop the track being done
    func cancelRequests() { wanted = []; job?.cancel(); progress = ""; backgroundStep(finishedRun: true) }
    weak var app: AppModel?
    /// what's been analysed (or failed): the file's size and date, and the format version
    struct Stamp: Codable {
        var size: Int64, mtime: Double, ver: Int, failed: String?
        /// the little the library's MATCH sort needs, kept here so sorting doesn't open every track's results
        var lufs: Double? = nil, shares: [Double]? = nil, lite: Bool? = nil
        /// the track's artist + title (AppleMusic.metaKey) and length in seconds when it was analysed: another copy of
        /// the same song (re-copied, renamed, re-encoded size) finds these results by them
        var meta: String? = nil, dur: Double? = nil
    }
    private var index = [String: Stamp]()
    private var cache = [String: AppleFeatures]()
    private var job: Task<Void, Never>?
    private var jobId: String?
    private var watch: Timer?
    private var retry: DispatchWorkItem?
    /// the app is in the background (Cratebox stays alive there while its audio runs): Apple's analysis doesn't
    /// work there unless iOS gave us a continued-processing task, so it pauses instead of failing every track
    private var inBackground = false
    /// a track stopped by leaving the app (or by iOS ending the background task): put back, never counted as failed
    private var interrupted = false
    /// failures that may be passing (internal error, busy): tried 3 times, with a pause, before they count
    private var tries = [String: Int]()
    /// iOS 26+: the continued-processing task that lets a run carry on after you leave the app (Any: it's iOS 26 only)
    private var bgTask: AnyObject?
    private var bgTotal = 0, bgDone = 0
    /// asked-for tracks whose file isn't there right now (a stick not plugged in, copies deleted): skipped, not
    /// failed, and looked for again when the library changes
    private var missingNow = Set<String>()
    private var subs = Set<AnyCancellable>()
    private var deadFolder = [String: Double]()   // music folders found unreachable, and when
    private var saveWork: DispatchWorkItem?
    private var mixCache = [String: (bpm: Double, first: Double, r: MixPoints.Result)]()
    /// twin key (file name + size, Library.twinKey) → a track analysed under that key, so a USB track and its copy on
    /// this device share one analysis (Jonah, 2026-11-12). Rebuilt lazily when the library or the results change
    private var twinOf = [String: String]()
    /// artist + title (metaKey) → analysed tracks under it and their lengths: the second way a copy finds its results
    private var metaOf = [String: [(id: String, dur: Double?)]]()
    private var twinStale = true
    private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cratebox/apple", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")), let i = try? JSONDecoder().decode([String: Stamp].self, from: d) { index = i }
        analysed = index.values.filter { $0.failed == nil && $0.ver == AppleFeatures.VER }.count
    }
    func attach(_ app: AppModel) {
        self.app = app
        Suggest.app = app
        // new folders, a stick plugged in: look for tracks to analyse a few seconds after the list settles
        app.library.$tracks.sink { [weak self] _ in self?.twinStale = true }.store(in: &subs)
        app.library.$tracks.debounce(for: .seconds(4), scheduler: RunLoop.main).sink { [weak self] _ in self?.missingNow = []; self?.kick(); self?.adoptGrids() }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in self?.wentBackground() }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).sink { [weak self] _ in self?.cameBack() }.store(in: &subs)
        registerBackground()
        kick()
        backfill()
        adoptGrids()
    }

    // ---- leaving the app (Jonah, 2026-11-13: a text came in mid-run and every track left showed as failed) ----
    private func wentBackground() {
        inBackground = true
        guard bgTask == nil, job != nil else { return }
        interrupted = true; job?.cancel()
    }
    private func cameBack() {
        inBackground = false; tries = [:]
        kick()
    }
    static var bgId: String { (Bundle.main.bundleIdentifier ?? "com.zonahbear.cratebox.suite") + ".analysis" }
    private func registerBackground() {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: AppleMusic.bgId, using: nil) { [weak self] task in
                DispatchQueue.main.async {
                    guard let self, let t = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    self.bgTask = t
                    t.progress.totalUnitCount = Int64(max(self.bgTotal, 1))
                    t.progress.completedUnitCount = Int64(self.bgDone)
                    t.expirationHandler = { [weak self] in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.bgTask = nil
                            if self.inBackground, self.job != nil { self.interrupted = true; self.job?.cancel() }
                        }
                    }
                    self.kick()
                }
            }
        }
    }
    /// asked for in the app: ask iOS to let the run carry on in the background, with its progress on the lock screen
    private func startBackground(_ n: Int) {
        guard #available(iOS 26.0, *), !inBackground else { return }
        bgTotal = n + bgTotal - bgDone; bgDone = 0
        if let t = bgTask as? BGContinuedProcessingTask { t.progress.totalUnitCount = Int64(bgTotal); return }
        func submit(gpu: Bool) throws {
            let r = BGContinuedProcessingTaskRequest(identifier: AppleMusic.bgId, title: "Analysing tracks", subtitle: "Apple music analysis in Cratebox")
            r.strategy = .queue
            if gpu { r.requiredResources = .gpu }
            try BGTaskScheduler.shared.submit(r)
        }
        do { try submit(gpu: BGTaskScheduler.supportedResources.contains(.gpu)) }
        catch { try? submit(gpu: false) }
    }
    /// one more track done (or the run is over): the lock-screen progress follows
    private func backgroundStep(finishedRun: Bool) {
        guard #available(iOS 26.0, *), let t = bgTask as? BGContinuedProcessingTask else { return }
        if !finishedRun {
            bgDone += 1
            t.progress.completedUnitCount = Int64(bgDone)
            t.updateTitle("Analysing tracks", subtitle: "\(bgDone) of \(bgTotal)")
        } else {
            t.setTaskCompleted(success: true); bgTask = nil; bgTotal = 0; bgDone = 0
        }
    }
    /// background, no task (or iOS ended it), and a track failed or stopped: end the task, carry on when you're back
    private func backgroundPaused() {
        if #available(iOS 26.0, *), let t = bgTask as? BGContinuedProcessingTask { t.setTaskCompleted(success: false) }
        bgTask = nil
        progress = "Paused while Cratebox is in the background: carries on when you come back"
    }

    // ---- results ----
    private func file(_ id: String) -> URL { dir.appendingPathComponent(Self.fileName(id)) }
    static func fileName(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    // ---- a backup on the stick (Jonah, 2026-11-13): <stick>/Cratebox/Apple analysis/, the same files as here, in
    // plain sight so it's easy to find and copy (index.json + one .json per track) ----
    static let stickBackupKey = "cb.apple.stickBackup"
    /// on unless turned off in Settings → AI
    static var stickBackup: Bool { UserDefaults.standard.object(forKey: stickBackupKey) == nil || UserDefaults.standard.bool(forKey: stickBackupKey) }
    static func backupDir(_ d: Device) -> URL { d.root.appendingPathComponent("Cratebox/Apple analysis", isDirectory: true) }
    private var backupWork: DispatchWorkItem?
    /// after analyses finish: back up to every open stick half a minute later (one write for a run of tracks)
    private func backupSoon() {
        guard AppleMusic.stickBackup else { return }
        backupWork?.cancel()
        let w = DispatchWorkItem { [weak self] in for d in Devices.shared.list { self?.backup(to: d) } }
        backupWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
    }
    /// copies results the stick doesn't have yet, then the index (the stick's entries kept, this device's win)
    func backup(to d: Device, done: ((String) -> Void)? = nil) {
        saveIndex()
        let src = dir, dst = Self.backupDir(d), mine = index, name = d.name
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var n = 0, msg: String
            do {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for (id, s) in mine where s.failed == nil {
                    let f = AppleMusic.fileName(id), to = dst.appendingPathComponent(f)
                    if fm.fileExists(atPath: to.path) { continue }
                    guard let data = try? Data(contentsOf: src.appendingPathComponent(f)) else { continue }
                    try data.write(to: to, options: .atomic); n += 1
                }
                var theirs = (try? JSONDecoder().decode([String: Stamp].self, from: Data(contentsOf: dst.appendingPathComponent("index.json")))) ?? [:]
                for (id, s) in mine where s.failed == nil { theirs[id] = s }
                try JSONEncoder().encode(theirs).write(to: dst.appendingPathComponent("index.json"), options: .atomic)
                msg = "Apple's analysis backed up to \(name): \(theirs.count) tracks (\(n) new)"
            } catch {
                msg = "Couldn't back up Apple's analysis to \(name): \(error.localizedDescription)"
            }
            DispatchQueue.main.async { AppLog.add(msg); done?(msg) }
        }
    }
    /// brings back what the stick's backup has and this device doesn't (or only has as failed); nothing here is lost
    func restore(from d: Device, done: @escaping (String) -> Void) {
        let src = Self.backupDir(d), dst = dir, name = d.name
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let theirs = try? JSONDecoder().decode([String: Stamp].self, from: Data(contentsOf: src.appendingPathComponent("index.json"))) else {
                DispatchQueue.main.async { done("No backup of Apple's analysis on \(name) yet") }; return
            }
            var got = [String: Stamp]()
            for (id, s) in theirs where s.failed == nil && s.ver == AppleFeatures.VER {
                let f = AppleMusic.fileName(id), to = dst.appendingPathComponent(f)
                if !fm.fileExists(atPath: to.path) {
                    guard let data = try? Data(contentsOf: src.appendingPathComponent(f)), (try? data.write(to: to, options: .atomic)) != nil else { continue }
                }
                got[id] = s
            }
            DispatchQueue.main.async {
                var n = 0
                for (id, s) in got {
                    if let o = self.index[id], o.failed == nil, o.ver == AppleFeatures.VER { continue }
                    self.index[id] = s; self.cache[id] = nil; n += 1
                }
                self.saveIndex()
                self.analysed = self.index.values.filter { $0.failed == nil && $0.ver == AppleFeatures.VER }.count
                self.twinStale = true
                self.adoptGrids()
                let msg = "Restored \(n) track\(n == 1 ? "" : "s")' analysis from \(name) (\(theirs.count) in its backup)"
                AppLog.add(msg); done(msg)
            }
        }
    }
    /// Apple's results for a track, if they're for the file as it is now (its own, else its twin's)
    func features(_ t: LibTrack) -> AppleFeatures? {
        guard let id = source(t) else { return nil }
        if let f = cache[id] { return f }
        guard let d = try? Data(contentsOf: file(id)), let f = try? JSONDecoder().decode(AppleFeatures.self, from: d) else { return nil }
        if cache.count > 200 { cache.removeAll() }      // a few hundred kB each: keep the memory bounded
        cache[id] = f
        return f
    }
    /// a track's file name + size, the same twin rule as USB copy (a stick track by rekordbox's file name and size)
    static func twinKey(_ t: LibTrack) -> String {
        if let r = t.rb { return Library.twinKey(r.filename.isEmpty ? (r.path as NSString).lastPathComponent : r.filename, Int64(r.size)) }
        return Library.twinKey((t.rec.rel as NSString).lastPathComponent, t.rec.size)
    }
    /// library tracks Cratebox hasn't analysed yet but Apple has (themselves or their USB twin): they take Apple's
    /// grid, key and length straight away (grid order: Apple's comes before Cratebox's own), so the library, MATCH
    /// and AI DJ can use them without a second analysis. Read off the main thread, a batch at a time
    private var adopting = false
    func adoptGrids() {
        guard !adopting, AppleGridMode.now != .off, let app else { return }
        let todo = app.library.tracks.filter { !$0.analysed && !$0.rec.gridManual }.compactMap { t in source(t).map { (t, file($0)) } }
        guard !todo.isEmpty else { return }
        adopting = true
        let range = Settings.bpmRange
        DispatchQueue.global(qos: .utility).async {
            var got = [(LibTrack, Double, Double, Double, Int)]()
            for (t, u) in todo {
                guard let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(AppleFeatures.self, from: d),
                      let g = f.grid(near: nil, range: range) else { continue }
                let dur = max(f.beats.last ?? 0, f.sections.last?.end ?? 0, f.phrases.last?.end ?? 0)
                got.append((t, g.bpm, g.firstBeat, dur, f.key))
            }
            DispatchQueue.main.async {
                for (t, bpm, first, dur, key) in got where !t.analysed && !t.rec.gridManual {
                    t.info.bpm = bpm; t.info.firstBeat = first; t.info.appleGrid = true
                    if t.info.duration <= 0 { t.info.duration = dur }
                    if t.info.key < 0 && key >= 0 { t.info.key = key }
                    t.rec.ver = Library.ANALYSIS_VER
                    app.library.changed(t)
                }
                if !got.isEmpty { app.library.objectWillChange.send() }
                self.adopting = false
            }
        }
    }
    /// the twin key of a stored result, from its track id and the size it was analysed at
    static func twinKey(id: String, size: Int64) -> String? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, size > 0 else { return nil }
        return Library.twinKey((String(parts[1]) as NSString).lastPathComponent, size)
    }
    /// artist + title, lower case, spaces squeezed: nil without both (a title made from the file name isn't enough)
    static func metaKey(_ t: LibTrack) -> String? {
        func n(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        let artist = n(t.rb?.artist ?? t.rec.artist), title = n(t.rb?.title ?? t.rec.title)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return artist + "|" + title
    }
    /// the track's length in seconds when known (rekordbox's, else the library's)
    static func length(_ t: LibTrack) -> Double? {
        if let r = t.rb, r.duration > 0 { return Double(r.duration) }
        return t.rec.duration > 0 ? t.rec.duration : nil
    }
    /// whose results stand for a track: its own when they're current, else an analysed twin's (the same file on the
    /// stick and on this device: same name and size, so the same audio; dates differ after a copy, so they aren't
    /// compared). nil: neither is analysed
    private func source(_ t: LibTrack) -> String? {
        if let s = index[t.id], s.failed == nil, current(s, t) { return t.id }
        if twinStale, let app {
            twinOf = [:]
            // every analysed file, from the stored results alone, so a stick that's unplugged still counts (its
            // tracks aren't in the library then): ids are "<stick>|<path>" or "<folder>|<path>|<size>"
            for (id, s) in index where s.failed == nil && s.ver == AppleFeatures.VER {
                if let k = AppleMusic.twinKey(id: id, size: s.size) { twinOf[k] = id }
            }
            // and the tracks that are here, by rekordbox's file name too (it can differ from the path's)
            var stamped = false
            for o in app.library.tracks {
                guard var s = index[o.id], s.failed == nil, current(s, o) else { continue }
                twinOf[AppleMusic.twinKey(o)] = o.id
                // results from before stamps kept artist + title: add them now, while the track is here to ask
                if s.meta == nil, let m = AppleMusic.metaKey(o) { s.meta = m; s.dur = s.dur ?? AppleMusic.length(o); index[o.id] = s; stamped = true }
            }
            if stamped { saveIndex() }
            metaOf = [:]
            for (id, s) in index where s.failed == nil && s.ver == AppleFeatures.VER { if let m = s.meta { metaOf[m, default: []].append((id, s.dur)) } }
            twinStale = false
        }
        func usable(_ id: String) -> Bool { id != t.id && index[id].map { $0.failed == nil && $0.ver == AppleFeatures.VER } == true }
        // the same file (name + size), else the same song by artist + title, the same length to within 2 s when
        // both lengths are known (an extended mix and a radio edit share a title but not a length)
        if let id = twinOf[AppleMusic.twinKey(t)], usable(id) { return id }
        guard let m = AppleMusic.metaKey(t), let cands = metaOf[m] else { return nil }
        let len = AppleMusic.length(t)
        return cands.first { c in usable(c.id) && (len == nil || c.dur == nil || abs(len! - c.dur!) <= 2) }?.id
    }
    /// a stamp still describes the track's file (same size, same date when the library knows it, same format)
    private func current(_ s: Stamp, _ t: LibTrack) -> Bool {
        s.ver == AppleFeatures.VER && s.size == t.rec.size && (t.rec.mtime == 0 || s.mtime == 0 || abs(s.mtime - t.rec.mtime) < 1)
    }
    private func saveIndex() { if let d = try? JSONEncoder().encode(index) { try? d.write(to: dir.appendingPathComponent("index.json"), options: .atomic) } }

    // ---- for the decks and the library: Apple's grid, mix points, and what MATCH needs ----
    /// Apple's results for a track when Settings → Library & USB → Beat grids asks for Apple's grid (nil: off, or not
    /// analysed yet). The grid itself is made at load (AppModel.load), once rekordbox's tempo is known for the octave
    func gridSource(_ t: LibTrack) -> AppleFeatures? { AppleGridMode.now == .off ? nil : features(t) }
    /// loudness and vocal / drum / bass shares for a track, if Apple has analysed it
    func lite(_ id: String) -> (lufs: Double?, shares: [Double]?)? {
        guard AIMode.on else { return nil }
        let src = app?.library.track(id).flatMap { source($0) } ?? id
        guard let s = index[src], s.failed == nil, s.ver == AppleFeatures.VER else { return nil }
        return (s.lufs, s.shares)
    }
    /// where to mix a loaded track in and out, on the deck's grid (nil without Apple's results). Asked for by the
    /// waveforms many times a second, so the answer is kept until the grid changes
    func mixPoints(_ info: TrackInfo?, bpm: Double, first: Double, duration: Double) -> MixPoints.Result? {
        guard AIMode.on, let info, bpm > 0 else { return nil }
        if let c = mixCache[info.id], c.bpm == bpm, c.first == first { return c.r }
        guard let t = app?.library.track(info.id), let f = features(t) else { return nil }
        let r = MixPoints.suggest(f, bpm: bpm, firstBeat: first, duration: duration)
        if mixCache.count > 64 { mixCache.removeAll() }
        mixCache[info.id] = (bpm, first, r)
        return r
    }
    /// tracks analysed before the stamps kept loudness and shares: read their results once, off the main thread
    private func backfill() {
        let todo = index.filter { $0.value.failed == nil && $0.value.ver == AppleFeatures.VER && $0.value.lite != true }.map { ($0.key, file($0.key)) }
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var found = [String: (Double?, [Double]?)]()
            for (id, u) in todo {
                guard let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(AppleFeatures.self, from: d) else { continue }
                found[id] = (f.lufs, f.shares)
            }
            DispatchQueue.main.async {
                for (id, v) in found where self.index[id] != nil { self.index[id]!.lufs = v.0; self.index[id]!.shares = v.1; self.index[id]!.lite = true }
                self.saveIndex()
                self.objectWillChange.send()
            }
        }
    }

    // ---- the background queue ----
    private var playing: Bool { app?.core.decks.contains { $0.playing } ?? false }
    /// start the next track if AI mode is on, it's supported, nothing plays and nothing's running
    func kick() {
        retry?.cancel(); retry = nil
        guard AIMode.on, AppleMusic.usable, let app else { if !AIMode.on { stop() }; return }
        guard job == nil else { return }
        if inBackground && bgTask == nil { if !wanted.isEmpty { backgroundPaused() }; return }
        if playing && !AppleMusic.whilePlaying {
            progress = "Waits while a deck plays"
            later(5); return
        }
        // Apple's analysis keeps the phone's processors busy for the whole track: it only starts when the app has
        // been left alone for a while, the phone isn't hot, and Low Power Mode is off
        TouchWatch.install()
        if !inBackground && !AppleMusic.whilePlaying && ProcessInfo.processInfo.systemUptime - TouchWatch.last < AppleMusic.idleSecs {
            if !wanted.isEmpty { progress = "Waits until the app is left alone for \(Int(AppleMusic.idleSecs)) seconds" }
            later(5); return
        }
        let heat = ProcessInfo.processInfo.thermalState
        if heat == .serious || heat == .critical { progress = "Waits for the phone to cool down"; later(30); return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { progress = "Waits while Low Power Mode is on"; later(30); return }
        // only what was asked for; a track whose twin (USB ↔ this device) is already analysed shares those results
        guard !wanted.isEmpty else { progress = ""; return }
        let want = Set(wanted)
        let todo = app.library.preferLocal(app.library.tracks.filter { want.contains($0.id) }).filter { needs($0) }
        if todo.isEmpty && want.allSatisfy({ id in app.library.track(id) != nil }) { wanted = []; progress = ""; backgroundStep(finishedRun: true); return }
        // a folder whose drive isn't there is asked once a minute, not once per track (resolving a bookmark to a
        // missing drive can take seconds, and this runs on the main thread)
        let now = Date().timeIntervalSince1970
        var found: (LibTrack, URL)?
        var rescan = false
        for t in todo {
            if missingNow.contains(t.id) { continue }
            if t.device == nil, let since = deadFolder[t.rec.folder], now - since < 60 { continue }
            if let u = url(of: t) {
                if FileManager.default.fileExists(atPath: u.path) { found = (t, u); break }
                missingNow.insert(t.id)
                if t.rec.folder == UsbCopy.folderId { rescan = true }
                continue
            }
            if t.device == nil { deadFolder[t.rec.folder] = now }
        }
        // copies deleted in Files: look at the folder again, so they leave the library (Sync copies them back)
        if rescan, let f = app.library.folders.first(where: { $0.id == UsbCopy.folderId }) { app.library.scan(f) }
        guard let next = found else {
            if bgTask != nil { backgroundStep(finishedRun: true) }
            progress = todo.isEmpty ? "" : "\(todo.count) waiting for their files (plug the USB in, or Sync to copy them back)"
            if !todo.isEmpty { later(60) }
            return
        }
        let (t, u) = next
        progress = "Analysing \(todo.count) track\(todo.count == 1 ? "" : "s") (Apple)…"
        let id = t.id, size = t.rec.size, mtime = t.rec.mtime
        jobId = id
        job = Task.detached(priority: .utility) { [weak self] in
            let r = await AppleMusic.run(u)
            await MainActor.run { self?.finished(id, size: size, mtime: mtime, r, url: u) }
        }
        // a deck starts playing: stop this track (it's done again later), so analysis never competes with the audio
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if let self, self.playing, !AppleMusic.whilePlaying { self.job?.cancel() }
        }
    }
    /// how long the screen must go untouched before a track is analysed
    static let idleSecs = 20.0
    /// Settings → AI → Analyse while tracks play (Jonah, 2026-11-13; off by default): keeps going while decks play
    /// and you're touching the screen. Heat and Low Power Mode still pause it
    static let whilePlayingKey = "cb.apple.whilePlaying"
    static var whilePlaying: Bool { UserDefaults.standard.bool(forKey: whilePlayingKey) }
    /// a track is being loaded (or something else needs the phone now): the track being analysed is put back
    func yield() {
        TouchWatch.last = ProcessInfo.processInfo.systemUptime
        job?.cancel()
    }
    private func later(_ s: Double) {
        let w = DispatchWorkItem { [weak self] in self?.kick() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
    func stop() {
        job?.cancel()
        progress = ""
    }
    private func finished(_ id: String, size: Int64, mtime: Double, _ r: Result<AppleFeatures, Error>, url: URL? = nil) {
        let cancelled = job?.isCancelled ?? false
        watch?.invalidate(); watch = nil
        job = nil; jobId = nil
        switch r {
        case .success(var f):
            if f.size == 0 { f.size = size }
            if f.mtime == 0 { f.mtime = mtime }
            // the library's size and date win for the stamp (that's what `current` compares against)
            let t = app?.library.track(id)
            let applen = max(f.beats.last ?? 0, f.sections.last?.end ?? 0, f.phrases.last?.end ?? 0)
            index[id] = Stamp(size: size, mtime: mtime, ver: AppleFeatures.VER, failed: nil, lufs: f.lufs, shares: f.shares, lite: true,
                              meta: t.flatMap { AppleMusic.metaKey($0) }, dur: t.flatMap { AppleMusic.length($0) } ?? (applen > 0 ? applen : nil))
            mixCache[id] = nil
            if let d = try? JSONEncoder().encode(f) { try? d.write(to: file(id), options: .atomic) }
            cache[id] = f
            twinStale = true
            DispatchQueue.main.async { [weak self] in self?.adoptGrids() }
            analysed += 1
            tries[id] = nil
            backupSoon()
            AppLog.add("Apple analysed \(t?.info.title ?? id)")
            backgroundStep(finishedRun: false)
        case .failure(let e):
            // stopped by leaving the app, by iOS, by a deck or a load: put back, not a failure
            if e is CancellationError || cancelled || interrupted || inBackground {
                interrupted = false
                if inBackground { backgroundPaused(); return }
                progress = AIMode.on ? "Paused (a deck started or a track was loaded)" : ""; later(5); return
            }
            // an error that may pass (Apple's internal error, still busy with the last track): try again a bit later
            let n = (tries[id] ?? 0) + 1
            if !AppleMusic.permanent(e) && n < 3 {
                tries[id] = n; progress = "Apple's analysis stumbled; trying that track again in \(n * 10) s"
                later(Double(n * 10)); return
            }
            tries[id] = nil
            AppLog.add("Apple failed \(app?.library.track(id)?.info.title ?? id): \(e)")
            index[id] = Stamp(size: size, mtime: mtime, ver: AppleFeatures.VER, failed: url.map { FileManager.default.fileExists(atPath: $0.path) } == false
                ? "The file isn't there any more (moved or deleted). If it came from a USB stick, Sync copies it again" : AppleMusic.reason(e))
            backgroundStep(finishedRun: false)
        }
        // the index is written a couple of seconds after the last change, not after every track
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveIndex() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        objectWillChange.send()
        // a short breather between tracks (longer after a failure, or when the phone is getting warm), so a run of
        // quick failures can't keep the main thread busy and a long run doesn't heat the phone up
        if case .failure = r { later(1) } else { later(ProcessInfo.processInfo.thermalState == .nominal ? 0.3 : 5) }
    }
    private func url(of t: LibTrack) -> URL? { Devices.shared.url(for: t) ?? app?.library.fileURL(t) }
    /// forget everything (Settings), so it's all analysed again
    func clear() {
        job?.cancel()
        index = [:]; cache = [:]; analysed = 0; deadFolder = [:]; twinOf = [:]; twinStale = true
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        objectWillChange.send()
        if let app { request(app.library.tracks.filter { $0.device == nil }) }
    }
    var failedCount: Int { index.values.filter { $0.failed != nil }.count }
    /// tracks Apple's analysis gave up on, with why (Settings → AI)
    var failures: [(title: String, why: String)] {
        let byId = Dictionary((app?.library.tracks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return index.compactMap { id, s in
            guard let why = s.failed else { return nil }
            let t = byId[id]
            let name = t.map { $0.rec.artist.isEmpty ? $0.rec.title : "\($0.rec.artist) - \($0.rec.title)" }
                ?? ((id.split(separator: "|").dropFirst().first).map { (String($0) as NSString).lastPathComponent } ?? id)
            return (name, why)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    /// forget the failures, so those tracks are tried again
    func retryFailed() {
        let ids = index.filter { $0.value.failed != nil }.map(\.key)
        for id in ids { index[id] = nil }
        tries = [:]
        // back on the to-do list (it may have emptied when the run "finished" on failures)
        let have = Set(wanted)
        let add = ids.filter { !have.contains($0) }
        wanted += add
        saveIndex(); objectWillChange.send()
        startBackground(ids.count)
        kick()
    }
    /// failures that trying again won't fix
    static func permanent(_ e: Error) -> Bool {
        let d = String(describing: e).lowercased()
        return d.contains("protected") || d.contains("drm") || d.contains("invalidasset") || d.contains("unsupported")
            || d.contains("nosuchfile") || d.contains("not found")
    }
    /// Apple's error in words: what went wrong and whether trying again can help
    static func reason(_ e: Error) -> String {
        let d = String(describing: e).lowercased(), l = e.localizedDescription
        if d.contains("protected") || d.contains("drm") { return "The file is copy-protected (DRM), so it can't be analysed" }
        if d.contains("invalidasset") || d.contains("unsupported") || d.contains("cannotopen") || d.contains("format") {
            return "Apple couldn't read this file (damaged, or a format it doesn't support): \(l)"
        }
        if d.contains("nosuchfile") || d.contains("not found") || d.contains("couldn’t be opened") || d.contains("permission") {
            return "The file wasn't reachable (drive unplugged or folder permission lost). Try again once it's back"
        }
        if d.contains("timeout") || d.contains("timed out") { return "Took too long and was stopped. Try again when the phone is idle" }
        if d.contains("sessioninprogress") || d.contains("busy") || d.contains("internal") {
            return "Apple's analysis hit an internal error (\(l)). Trying again usually works"
        }
        return l
    }

    // ---- the framework ----
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { AppleMusic.unavailableReason ?? "Not available" }
    }
    static func run(_ url: URL) async -> Result<AppleFeatures, Error> {
        #if canImport(MusicUnderstanding)
        if #available(iOS 27, *) {
            do { return .success(try await analyse(url)) } catch { return .failure(error) }
        }
        #endif
        return .failure(Failure.unsupported)
    }

    #if canImport(MusicUnderstanding)
    @available(iOS 27, *)
    static func analyse(_ url: URL) async throws -> AppleFeatures {
        var f = AppleFeatures()
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        f.size = Int64(v?.fileSize ?? 0); f.mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
        f.analysedAt = Date().timeIntervalSince1970
        f.os = ProcessInfo.processInfo.operatingSystemVersionString
        let t0 = Date()
        // Apple: precise timing, or the results can be slightly off on compressed files
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let session = try await MusicUnderstandingSession(asset: asset)
        let r = try await withTaskCancellationHandler {
            try await session.analyze(for: [.rhythm, .key, .structure, .pace, .instrumentActivity, .loudness])
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        func sec(_ t: CMTime) -> Double { t.isNumeric ? t.seconds : 0 }
        func span(_ r: CMTimeRange, _ x: Double = 0) -> AppleFeatures.Span { .init(sec(r.start), sec(r.end), x) }
        if let rh = r.rhythm {
            f.bpm = rh.beatsPerMinute.map { Double($0) }
            f.beats = rh.beats.map(sec); f.bars = rh.bars.map(sec)
        }
        if let k = r.key { f.keys = k.ranges.map { span($0.range, Double(keyNumber($0.value))) } }
        if let st = r.structure {
            f.sections = st.sections.map { span($0) }; f.segments = st.segments.map { span($0) }; f.phrases = st.phrases.map { span($0) }
        }
        if let p = r.pace { f.pace = p.ranges.map { span($0.range, $0.value) } }
        let dur = duration > 0 ? duration : max(f.beats.last ?? 0, f.sections.last?.end ?? 0)
        if let ia = r.instrumentActivity {
            for (inst, rs) in ia.ranges { f.present[name(inst)] = rs.map { span($0) } }
            for (inst, vs) in ia.activity {
                f.activity[name(inst)] = AppleFeatures.bin(vs.map { (sec($0.time), $0.value) }, step: f.activityStep, duration: dur)
            }
        }
        if let l = r.loudness {
            f.lufs = Double(l.integrated.value); f.peakDb = Double(l.peak.value)
            f.shortTerm = AppleFeatures.bin(l.shortTerm.map { (sec($0.time), $0.value) }, step: 1, duration: dur)
        }
        f.seconds = Date().timeIntervalSince(t0)
        return f
    }
    @available(iOS 27, *)
    static func name(_ i: InstrumentActivityResult.Instrument) -> String {
        if i == .vocal { return "vocal" }
        if i == .drum { return "drum" }
        if i == .bass { return "bass" }
        if i == .other { return "other" }
        return i.rawValue
    }
    /// Apple's key → Cratebox's key number (0-11 major C...B, 12-23 minor)
    @available(iOS 27, *)
    static func keyNumber(_ k: KeyResult.KeySignature) -> Int {
        let pc: Int
        switch k.tonic {
        case .c: pc = 0
        case .cSharp, .dFlat: pc = 1
        case .d: pc = 2
        case .dSharp, .eFlat: pc = 3
        case .e: pc = 4
        case .f: pc = 5
        case .fSharp, .gFlat: pc = 6
        case .g: pc = 7
        case .gSharp, .aFlat: pc = 8
        case .a: pc = 9
        case .aSharp, .bFlat: pc = 10
        case .b: pc = 11
        @unknown default: return -1
        }
        return pc + (k.mode == .minor ? 12 : 0)
    }
    #endif

    // ---- comparing with the grids we trust ----
    struct Row: Identifiable {
        let id: String, title: String, artist: String
        let source: String                 // whose grid it's compared with: Cratebox, rekordbox or "hand-fixed"
        let bpm: Double?, appleBpm: Double?
        let key: Int, appleKey: Int
        let cmp: GridCompare.Result
        let vocals: Double?, lufs: Double?, seconds: Double
    }
    func rows() -> [Row] {
        guard let app else { return [] }
        return app.library.tracks.compactMap { t in
            guard let f = features(t) else { return nil }
            // a stick's track has rekordbox's BPM from the start but its grid only once the analysis file is read
            // (normally at load): read it now, or there's no first beat to compare with
            if t.info.firstBeat == nil, t.device != nil { Devices.shared.readAnalysis(t) }
            let i = t.info
            var src = i.gridManual ? "hand-fixed" : i.rbGrid ? "rekordbox" : "Cratebox"
            var cmp = GridCompare.Result()
            // a track whose grid in use is Apple's own: compare with what it had before (rekordbox's, or Cratebox's)
            var refBpm = i.bpm, refFirst = i.firstBeat, refBeats = i.gridManual ? nil : i.rbBeats, refBeat0 = i.rbBeat0
            if i.appleGrid {
                if let u = Devices.shared.anlzURL(t), let x = Devices.readAnalysis(at: u) { refBpm = x.bpm; refFirst = x.firstBeat; refBeats = x.beats; refBeat0 = x.beat0 }
                else { refBpm = i.autoBpm; refFirst = i.autoFirst; refBeats = nil; src = "Cratebox" }
            }
            if let b = refBpm, b > 0, let fb = refFirst {
                cmp = GridCompare.compare(.init(bpm: b, firstBeat: fb, beats: refBeats, beat0: refBeat0), apple: f)
            } else if let b = i.bpm, b > 0, let tempo = f.tempo {
                // a BPM but no grid (a stick that isn't plugged in, or a tag's BPM): only the tempos can be compared
                src = "BPM only"
                cmp.tempoRatio = tempo / b
                cmp.tempoMult = [1.0, 0.5, 2.0].first { abs(tempo / b / $0 - 1) < 0.02 }
            }
            return Row(id: t.id, title: i.title, artist: i.artist, source: src, bpm: refBpm ?? i.bpm, appleBpm: f.tempo, key: i.key, appleKey: f.key, cmp: cmp,
                       vocals: f.share("vocal", duration: i.duration), lufs: f.lufs, seconds: f.seconds)
        }
    }
    /// the comparison as a CSV in Files → On My iPhone → Cratebox Suite
    func exportCSV() -> URL? {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func n(_ x: Double?, _ d: Int = 2) -> String { x.map { String(format: "%.\(d)f", $0) } ?? "" }
        var out = "title,artist,grid,bpm,apple_bpm,tempo_ratio,tempo_mult,beat_offset_beats,beat_offset_ms,beats_on_grid,bar1_shift_beats,bar1_share,key,apple_key,vocals_share,lufs,apple_seconds\n"
        for r in rows() {
            out += [q(r.title), q(r.artist), r.source, n(r.bpm), n(r.appleBpm), n(r.cmp.tempoRatio, 3), n(r.cmp.tempoMult, 1), n(r.cmp.beatOffset, 3), n(r.cmp.beatOffsetMs, 0),
                    n(r.cmp.beatsOnGrid, 2), r.cmp.barShift.map(String.init) ?? "", n(r.cmp.barShare, 2),
                    Keys.camelot(r.key)?.label ?? "", Keys.camelot(r.appleKey)?.label ?? "", n(r.vocals, 2), n(r.lufs, 1), n(r.seconds, 1)].joined(separator: ",") + "\n"
        }
        let u = Recorder.folder.appendingPathComponent("Apple analysis vs grids.csv")
        do { try out.write(to: u, atomically: true, encoding: .utf8); return u } catch { return nil }
    }
}
