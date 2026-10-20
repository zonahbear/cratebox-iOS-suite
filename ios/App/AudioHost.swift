// The iOS side of the audio: the audio session, and an AVAudioEngine whose only source is Cratebox's own
// engine (CrateboxKit.Engine) rendering into the output. With a 4-channel output (the FLX4 over USB) the
// master goes to 1/2 and the headphone mix to 3/4, like the web app's "FLX4 jack" headphone setting.
import AVFoundation
import CrateboxKit

final class AudioHost {
    static let sampleRate = 48000.0
    let engine = Engine(sampleRate: AudioHost.sampleRate)
    private var av = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var outputChannels = 2
    private(set) var routeName = ""
    var onRoute: (() -> Void)?
    var running: Bool { av.isRunning }

    func start() {
        configureSession()
        build()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.restart() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if t == .ended { self?.restart() }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in self?.restart() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.source = nil; self?.av = AVAudioEngine(); self?.restart()
        }
    }
    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setPreferredSampleRate(AudioHost.sampleRate)
        try? s.setPreferredIOBufferDuration(256 / AudioHost.sampleRate)
        try? s.setActive(true)
        // the FLX4 has 4 outputs: master on 1/2, headphones on 3/4
        if s.maximumOutputNumberOfChannels >= 4 { try? s.setPreferredOutputNumberOfChannels(4) }
        else { try? s.setPreferredOutputNumberOfChannels(2) }
    }
    private(set) var lastError = ""
    private var building = false
    private func build() {
        let s = AVAudioSession.sharedInstance()
        routeName = s.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        let hw = max(1, min(s.outputNumberOfChannels, 4))
        // try the controller's 4 outputs first (master 1/2, headphones 3/4), then plain stereo
        for ch in (hw >= 4 && routing != "stereo" ? [4, 2] : [2]) {
            if attach(channels: ch) { outputChannels = ch; lastError = ""; onRoute?(); return }
        }
        outputChannels = 2
        onRoute?()
    }
    /// what iOS reports about the output, for Settings (and for working out a wrong routing)
    private(set) var diagnostics = ""
    var routing: String { UserDefaults.standard.string(forKey: "cb.routing") ?? "auto" }      // auto, swapped, stereo
    private func describe() {
        let s = AVAudioSession.sharedInstance(), hw = av.outputNode.outputFormat(forBus: 0)
        let chans = s.currentRoute.outputs.flatMap { p in (p.channels ?? []).map { "\($0.channelNumber): \($0.channelName)" } }
        let tag = hw.channelLayout.map { String(format: "0x%08X", $0.layoutTag) } ?? "none"
        diagnostics = "\(s.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")) · hardware \(hw.channelCount) ch at \(Int(hw.sampleRate)) Hz, layout \(tag) · session \(s.outputNumberOfChannels) of max \(s.maximumOutputNumberOfChannels) · channels: \(chans.joined(separator: ", "))"
    }
    /// one try at a format; AVAudioEngine raises an Objective-C exception for one it can't use, caught here
    private func attach(channels ch: Int) -> Bool {
        // the hardware's own channel layout when it has 4 or more channels, so channel 1 really is the
        // controller's output 1 (a generic layout can get re-mapped by iOS)
        let hw = av.outputNode.outputFormat(forBus: 0)
        var fmt: AVAudioFormat
        if ch >= 4, hw.channelCount >= 4, let hl = hw.channelLayout {
            fmt = AVAudioFormat(standardFormatWithSampleRate: AudioHost.sampleRate, channelLayout: hl)
        } else if ch >= 4, hw.channelCount >= 4 {
            fmt = AVAudioFormat(standardFormatWithSampleRate: AudioHost.sampleRate, channels: hw.channelCount)!
        } else {
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo) else { return false }
            fmt = AVAudioFormat(standardFormatWithSampleRate: AudioHost.sampleRate, channelLayout: layout)
        }
        let eng = engine
        var ptrs = [UnsafeMutablePointer<Float>]()
        ptrs.reserveCapacity(8)
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            ptrs.removeAll(keepingCapacity: true)
            for b in list { if let d = b.mData { ptrs.append(d.assumingMemoryBound(to: Float.self)) } }
            if ptrs.isEmpty { return noErr }
            eng.render(ptrs, Int(frames))
            return noErr
        }
        var started = false
        let ex = CBTry {
            if let old = self.source { self.av.disconnectNodeOutput(old); self.av.detach(old); self.source = nil }
            self.av.attach(node)
            self.av.connect(node, to: self.av.outputNode, format: fmt)
            self.av.prepare()
            do { try self.av.start(); started = true } catch { self.lastError = error.localizedDescription }
        }
        if let ex { lastError = "\(ex.name.rawValue): \(ex.reason ?? "")" }
        if ex != nil || !started {
            _ = CBTry { self.av.stop(); self.av.disconnectNodeOutput(node); self.av.detach(node) }
            return false
        }
        source = node
        engine.post(.output(outputMode(ch)))
        describe()
        return true
    }
    func restart() {
        if building { return }
        building = true
        defer { building = false }
        _ = CBTry { self.av.stop() }
        configureSession()
        build()
    }
    /// headphones on a plain stereo output: mono master left, mono cue right (a splitter cable)
    func setSplit(_ on: Bool) { engine.post(.output(on ? .split : outputMode(outputChannels))) }
    func outputMode(_ ch: Int) -> OutputMode {
        if ch >= 4 { return routing == "swapped" ? .quadSwapped : .quad }
        return UserDefaults.standard.bool(forKey: "cb.split") ? .split : .stereo
    }
    func setRouting(_ r: String) { UserDefaults.standard.set(r, forKey: "cb.routing"); restart() }
}
