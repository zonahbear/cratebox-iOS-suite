// Cratebox USB's player: a full Cratebox deck (CrateboxKit.Core on its own Engine, mixed into the output by
// AudioHost) so a stick's track plays, scratches and loops exactly like in Performance Mode, with rekordbox's
// grid, phrases, cues and colour waveform. The cue and grid tools are the deck's own; what they change is
// recorded as the track's staged edit instead of going into Performance Mode's library.
import AVFoundation
import Foundation
import QuartzCore
import CrateboxKit

/// the preview deck's cues go to the stick's staged edits
final class USBCueStore: CueStore {
    weak var session: USBSession?
    func load(_ id: String) -> (cue: Double?, hot: [Double?])? {
        guard let e = session?.edits[id], e.cue != nil || e.hot != nil else { return nil }
        return (e.cue, e.hot ?? [Double?](repeating: nil, count: 8))
    }
    func save(_ id: String, cue: Double?, hot: [Double?]) {
        DispatchQueue.main.async { self.session?.edit(id) { $0.cue = cue; $0.hot = hot } }
    }
}

final class USBPreview: ObservableObject {
    weak var session: USBSession? { didSet { cueStore.session = session } }
    let audio: AudioHost
    let core: Core
    private let cueStore = USBCueStore()
    private var link: CADisplayLink?
    private var frame = 0
    @Published private(set) var key: String?            // the track on the deck
    @Published private(set) var loadingKey: String?
    var deck: DeckModel { core.decks[0] }

    init(audio: AudioHost) {
        self.audio = audio
        core = Core(engine: audio.preview, prefs: MemoryPrefs(), cues: cueStore)
        var m = MixerState(); m.master = 0.8
        core.mixer = m
        core.clock = { [unowned self] in self.smoothClock() }
        core.lag = { [unowned audio] in audio.latency }          // jumps start from the playhead, as on the decks
        core.status = { [weak self] s, _ in self?.session?.message = s }
        // the grid tools edit the track's grid: record it as the staged edit
        core.trackChanged = { [weak self] t in
            guard let self, t.gridManual, let k = self.key, t.id == k else { return }
            self.session?.edit(k) { $0.bpm = t.bpm; $0.firstBeat = t.firstBeat }
        }
    }

    func setActive(_ on: Bool) {
        if on {
            audio.previewOn = true
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                l.add(to: .main, forMode: .common); link = l
            }
        } else {
            if deck.playing { deck.setPlaying(false) }
            link?.invalidate(); link = nil
            // let the stop reach the engine before it's switched off
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in if self?.link == nil { self?.audio.previewOn = false } }
        }
    }
    @objc private func tick() {
        core.tick()
        frame += 1
        if frame % 3 == 0 && deck.loaded { deck.objectChanged() }
    }
    private var cAudio = 0.0, cHost = 0.0
    private func smoothClock() -> Double {
        let s = core.lastSnapshot
        if s.host == 0 { return s.time }
        let now = hostSeconds(), raw = s.time + min(0.25, max(0, now - s.host))
        if cHost == 0 { cAudio = raw; cHost = now; return raw }
        let dt = max(0, now - cHost)
        var t = cAudio + dt
        let err = raw - t
        if abs(err) > 0.08 { t = raw } else { t += err * min(1, dt * 2) }
        cAudio = t; cHost = now
        return t - audio.latency
    }

    /// takes the track off the preview deck and frees its audio; a load still decoding is dropped when it
    /// finishes (finishLoad only takes the track the deck is waiting for)
    func unload() {
        deck.unload()
        key = nil; loadingKey = nil
    }

    /// what rekordbox's analysis files say about a track: grid (beat by beat when it changes tempo), phrases,
    /// cues, memory cues and the colour waveform
    struct RBAnalysis {
        var bpm: Double?, firstBeat: Double?, beats: [Double]?, beat0 = 0
        var phrases: [Phrase] = []
        var cue: Double?, hot: [Double?] = [Double?](repeating: nil, count: 8)
        var memory: [USBMemoryCue] = []
        var wave: Waveform?
    }
    static func readAnalysis(root: URL, track t: USBTrack) -> RBAnalysis {
        var r = RBAnalysis()
        guard !t.anlzPath.isEmpty else { return r }
        let datURL = root.appendingPathComponent(String(t.anlzPath.drop { $0 == "/" }))
        let a = RekordboxANLZ.parse([UInt8]((try? Data(contentsOf: datURL)) ?? Data()))
        let extBytes = [UInt8]((try? Data(contentsOf: datURL.deletingPathExtension().appendingPathExtension("EXT"))) ?? Data())
        var ext = RekordboxANLZ.parse(extBytes)
        ext.beats = a.beats
        if let g = RekordboxANLZ.grid(a.beats) { r.bpm = g.bpm; r.firstBeat = g.firstBeat }
        if Set(a.beats.map { $0.bpm }).count > 1 { r.beats = a.beats.map { Double($0.ms) / 1000 }; r.beat0 = a.beats.firstIndex { $0.n == 1 } ?? 0 }
        r.phrases = RekordboxANLZ.phrases(ext) ?? []
        let src = !ext.hot.isEmpty || !ext.memory.isEmpty ? ext : a
        let c = RekordboxANLZ.cues(src)
        r.cue = c.cue; r.hot = c.hot
        r.memory = src.memory.sorted { $0.ms < $1.ms }.map { USBMemoryCue(time: Double($0.ms) / 1000, loopEnd: $0.loopMs.map { Double($0) / 1000 }) }
        r.wave = RekordboxANLZ.waveform(ext: extBytes, duration: t.duration)
        return r
    }

    func load(_ t: USBTrack) {
        guard let s = session, let root = s.root else { return }
        let d = deck
        if d.playing { d.setPlaying(false) }
        let info = TrackInfo(id: t.key, title: t.title, artist: t.artist, bpm: t.bpm > 0 ? t.bpm : nil, key: RekordboxANLZ.keyIndex(t.keyName), duration: t.duration)
        info.keyFromRekordbox = info.key >= 0
        let edit = s.edits[t.key]
        d.beginLoad(info)
        loadingKey = t.key; key = t.key
        let url = root.appendingPathComponent(String(t.path.drop { $0 == "/" }))
        Task.detached(priority: .userInitiated) {
            let rb = USBPreview.readAnalysis(root: root, track: t)
            do {
                let pcm = try AudioDecoder.decode(url)
                let m = AudioDecoder.mono(pcm, 11025)
                let dur = Double(pcm.count) / pcm.sampleRate
                var a: DeckAnalysis
                if let bpm = edit?.bpm ?? rb.bpm, let fb = edit?.firstBeat ?? rb.firstBeat {
                    let wave = rb.wave ?? { let w = AudioDecoder.mono(pcm, 22050); return Analysis.waveform(w.x, w.fs) }()
                    a = DeckAnalysis(bpm: bpm, firstBeat: fb, key: info.key >= 0 ? info.key : Analysis.detectKey(m.x, m.fs).key,
                                     phrases: rb.phrases.isEmpty ? Analysis.phraseAnalysis(m.x, m.fs, bpm, fb) : rb.phrases, wave: wave, duration: dur)
                    if edit?.bpm == nil && edit?.firstBeat == nil, let b = rb.beats, b.count >= 2 { a.beats = b; a.beat0 = rb.beat0 }
                    info.rbGrid = rb.bpm != nil
                } else {
                    // not analysed by rekordbox: Cratebox's own analysis, so the grid tools have something to work on
                    let w = AudioDecoder.mono(pcm, 22050)
                    let r = Analysis.analyze(m.x, fs: m.fs, range: Settings.bpmRange, waveSource: w)
                    a = DeckAnalysis(bpm: r.bpm, firstBeat: r.firstBeat, key: info.key >= 0 ? info.key : r.key, phrases: r.phrases, wave: rb.wave ?? r.wave, duration: dur)
                }
                info.autoBpm = rb.bpm ?? a.bpm; info.autoFirst = rb.firstBeat ?? a.firstBeat
                info.rbCues = (rb.cue, rb.hot)
                let memory = rb.memory
                await MainActor.run {
                    guard d.track === info else { return }        // unloaded or replaced meanwhile
                    d.finishLoad(info, pcm: pcm, analysis: a, mono: m)
                    // the memory cues start as rekordbox's, unless you've edited them
                    if s.edits[t.key]?.memory == nil && !memory.isEmpty { s.rbMemory[t.key] = memory }
                    if self.loadingKey == t.key { self.loadingKey = nil }
                }
            } catch {
                await MainActor.run { d.failLoad(info, error.localizedDescription); if self.loadingKey == t.key { self.loadingKey = nil } }
            }
        }
    }

    /// Deep Scan's decode test: open the file and read a little from its start, middle and end
    static func decodeCheck(_ url: URL) -> String? {
        do {
            let f = try AVAudioFile(forReading: url)
            guard f.length > 0 else { return "it has no audio frames" }
            let fmt = f.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return "can't make a buffer for its format" }
            for frac in [0.0, 0.5, 0.97] {
                f.framePosition = AVAudioFramePosition(Double(f.length) * frac)
                try f.read(into: buf, frameCount: 4096)
                if buf.frameLength == 0 && frac < 0.9 { return "reading stopped at \(Int(frac * 100))%" }
            }
            return nil
        } catch { return "iOS can't decode it: \(error.localizedDescription)" }
    }
}
