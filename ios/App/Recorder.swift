// Set recording: Performance Mode's master output after the limiter (the decks: not the watch mic or Cratebox USB's preview, which are mixed in after it), to a WAV (16-bit,
// lossless) or an AAC .m4a (256 kbps; the web app's MP3 encoder isn't on iOS), in Cratebox's folder in the Files
// app. A tracklist is kept while recording: every track that could be heard, with the time it came in.
import AVFoundation
import Foundation
import os
import CrateboxKit

final class Recorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0.0
    @Published private(set) var lastFile: URL?
    @Published private(set) var tracklist: [(Double, String)] = []
    var format: String { UserDefaults.standard.string(forKey: "cb.recFmt") ?? "wav" }
    private var file: AVAudioFile?
    private var url: URL?
    // the audio thread copies blocks in here; a writer thread empties it into the file
    private let cap = 48000 * 8
    private let ringL: UnsafeMutablePointer<Float>, ringR: UnsafeMutablePointer<Float>
    // w / r / dropped are shared (under the lock); the tap keeps its own copies and never waits for the lock: it
    // publishes with a try-lock, and a block that finds the ring full is counted as dropped, never written over
    private var w = 0, r = 0, dropped = 0
    private var tapW = 0, tapR = 0, tapDropped = 0          // the audio thread's own
    private var writeError: String?                          // the writer thread's, read after it's finished
    private var lock = os_unfair_lock()
    private var writer: Thread?
    private var stopFlag = false
    private var noted = Set<String>()
    weak var app: AppModel?

    init() {
        ringL = .allocate(capacity: cap); ringR = .allocate(capacity: cap)
        ringL.initialize(repeating: 0, count: cap); ringR.initialize(repeating: 0, count: cap)
    }

    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// the app's folder name in Files (On My iPhone / iPad): the app's display name, e.g. "Cratebox Suite"
    static var filesName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Cratebox" }

    func start(_ engine: Engine) {
        guard !recording else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm"
        let ext = format == "aac" ? "m4a" : "wav"
        // never over an earlier set: two recordings started in the same minute get "(2)", "(3)"...
        let stem = "Cratebox set \(df.string(from: Date()))"
        var u = Recorder.folder.appendingPathComponent("\(stem).\(ext)"), k = 2
        while FileManager.default.fileExists(atPath: u.path) { u = Recorder.folder.appendingPathComponent("\(stem) (\(k)).\(ext)"); k += 1 }
        let settings: [String: Any] = format == "aac"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioHost.sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioHost.sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let f = try? AVAudioFile(forWriting: u, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { app?.status("Couldn't start recording"); return }
        file = f; url = u; w = 0; r = 0; dropped = 0; tapW = 0; tapR = 0; tapDropped = 0; writeError = nil; seconds = 0; tracklist = []; noted = []
        stopFlag = false; recording = true
        let L = ringL, R = ringR, cap = self.cap
        engine.post(.recordTap { [unowned self] l, rr, n in
            var wi = self.tapW
            // one slot stays empty so a full ring can't look like an empty one
            if n <= cap - 1 - (wi - self.tapR + cap) % cap {
                for j in 0..<n { L[wi] = l[j]; R[wi] = rr[j]; wi += 1; if wi == cap { wi = 0 } }
                self.tapW = wi
            } else { self.tapDropped += n }
            if os_unfair_lock_trylock(&self.lock) {
                self.w = self.tapW; self.tapR = self.r; self.dropped += self.tapDropped; self.tapDropped = 0
                os_unfair_lock_unlock(&self.lock)
            }
        })
        let th = Thread { [weak self] in self?.drainLoop() }
        th.qualityOfService = .userInitiated
        writer = th; th.start()
        app?.status("Recording to \(u.lastPathComponent)", 4)
    }
    private func drainLoop() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: AudioHost.sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48000)!
        var total = 0, rd = 0
        while true {
            os_unfair_lock_lock(&lock); let wi = w, done = stopFlag; os_unfair_lock_unlock(&lock)
            var n = (wi - rd + cap) % cap
            while n > 0 {
                let m = min(n, Int(buf.frameCapacity))
                for j in 0..<m { let k = (rd + j) % cap; buf.floatChannelData![0][j] = ringL[k]; buf.floatChannelData![1][j] = ringR[k] }
                buf.frameLength = AVAudioFrameCount(m)
                do { try file?.write(from: buf) } catch { if writeError == nil { writeError = error.localizedDescription } }
                rd = (rd + m) % cap; n -= m; total += m
                os_unfair_lock_lock(&lock); r = rd; os_unfair_lock_unlock(&lock)     // that much room again for the tap
            }
            let secs = Double(total) / AudioHost.sampleRate
            DispatchQueue.main.async { self.seconds = secs }
            if done { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    func stop(_ engine: Engine) {
        guard recording else { return }
        engine.post(.recordTap(nil))
        Thread.sleep(forTimeInterval: 0.05)          // the audio thread drops the tap at its next block
        os_unfair_lock_lock(&lock); stopFlag = true; os_unfair_lock_unlock(&lock)
        while writer?.isFinished == false { Thread.sleep(forTimeInterval: 0.02) }
        file = nil                                  // closes it
        recording = false
        lastFile = url
        saveTracklist()
        let name = url?.lastPathComponent ?? "the recording", lost = Double(dropped) / AudioHost.sampleRate
        if let e = writeError { app?.status("\(name) is incomplete: writing it failed (\(e)). Is the phone's storage full?", 12) }
        else if lost > 0 { app?.status("Saved \(name), but \(String(format: "%.1f", lost)) s are missing: the phone's storage fell behind", 12) }
        else { app?.status("Saved \(name) (Files → On My iPhone/iPad → \(Recorder.filesName))", 8) }
    }
    /// call about once a second while recording
    func noteAudible(_ core: Core) {
        guard recording else { return }
        for d in core.decks where d.playing && d.loaded {
            let i = d.i
            let heard = core.deckActive(i) && core.mixer.fader[i] > 0.05 && MixerCurves.xfGain(deck: i, core.mixer.xfader) > 0.05
            guard heard, let t = d.track, !noted.contains(t.id) else { continue }
            noted.insert(t.id)
            tracklist.append((seconds, t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)"))
        }
    }
    func tracklistText() -> String {
        tracklist.map { String(format: "%d:%02d  ", Int($0.0) / 60, Int($0.0) % 60) + $0.1 }.joined(separator: "\n") + "\n"
    }
    private func saveTracklist() {
        guard let url, !tracklist.isEmpty else { return }
        try? tracklistText().write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
}
