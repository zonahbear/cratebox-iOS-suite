// Set recording: Performance Mode's master output after the limiter (the decks: not the watch mic or Cratebox USB's preview, which are mixed in after it), to a WAV (16-bit,
// lossless) or an AAC .m4a (256 kbps; the web app's MP3 encoder isn't on iOS), in Cratebox's folder in the Files
// app. A tracklist is kept while recording: every track that could be heard, with the time it came in.
import AVFoundation
import Foundation
import CrateboxKit

final class Recorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0.0
    @Published private(set) var lastFile: URL?
    @Published private(set) var tracklist: [(Double, String)] = []
    var format: String { UserDefaults.standard.string(forKey: "cb.recFmt") ?? "wav" }
    private var file: AVAudioFile?
    private var url: URL?
    // the audio thread copies blocks in here (never waiting); a writer thread empties it into the file
    private let ring = RecordRing(capacity: 48000 * 8)
    private var writer: Thread?
    private var stopFlag = false                // set by stop's worker, read by the writer (both after `lock`)
    private let lock = NSLock()
    private var writeError: String?             // the writer thread's, read after it's finished
    private var tapsPosted = 0                  // .recordTap commands sent: the engine's tapChanges catches up
    private var stopping = false
    private var noted = Set<String>()
    weak var app: AppModel?

    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// the app's folder name in Files (On My iPhone / iPad): the app's display name, e.g. "Cratebox Suite"
    static var filesName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Cratebox" }

    func start(_ engine: Engine) {
        guard !recording, !stopping else { return }
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
        file = f; url = u; writeError = nil; seconds = 0; tracklist = []; noted = []
        ring.reset()
        lock.lock(); stopFlag = false; lock.unlock()
        recording = true
        let ring = self.ring
        engine.post(.recordTap { l, r, n in ring.write(l, r, n) }); tapsPosted += 1
        let th = Thread { [weak self] in self?.drainLoop() }
        th.qualityOfService = .userInitiated
        writer = th; th.start()
        app?.status("Recording to \(u.lastPathComponent)", 4)
    }
    private func drainLoop() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: AudioHost.sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48000)!
        var total = 0
        while true {
            lock.lock(); let done = stopFlag; lock.unlock()
            // after stopFlag, one more pass picks up the tail `finish` published
            while true {
                let m = ring.read(into: buf.floatChannelData![0], buf.floatChannelData![1], max: Int(buf.frameCapacity))
                if m == 0 { break }
                buf.frameLength = AVAudioFrameCount(m)
                do { try file?.write(from: buf) } catch { if writeError == nil { writeError = error.localizedDescription } }
                total += m
            }
            let secs = Double(total) / AudioHost.sampleRate
            DispatchQueue.main.async { self.seconds = secs }
            if done { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    /// Stops in the background: waits until the audio thread has dropped the tap (so its last block is in), hands
    /// that block over, lets the writer finish, then closes the file. The screen never waits.
    func stop(_ engine: Engine) {
        guard recording, !stopping else { return }
        stopping = true
        engine.post(.recordTap(nil)); tapsPosted += 1
        let want = tapsPosted, ring = self.ring, w = writer
        DispatchQueue.global(qos: .userInitiated).async {
            // the engine applies commands before it renders, so once it's past ours the tap won't run again; if the
            // audio is stopped (an interruption) nothing calls the tap either, so give up waiting after a second
            let until = Date().addingTimeInterval(1)
            while engine.tapChanges < want && Date() < until { Thread.sleep(forTimeInterval: 0.005) }
            ring.finish()
            self.lock.lock(); self.stopFlag = true; self.lock.unlock()
            while w?.isFinished == false { Thread.sleep(forTimeInterval: 0.01) }
            DispatchQueue.main.async { self.finishStop(lost: Double(ring.droppedFrames) / AudioHost.sampleRate) }
        }
    }
    private func finishStop(lost: Double) {
        file = nil                                  // closes it
        recording = false; stopping = false
        lastFile = url
        saveTracklist()
        let name = url?.lastPathComponent ?? "the recording"
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
