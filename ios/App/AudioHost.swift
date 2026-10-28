// The iOS side of the audio: the audio session, and an AVAudioEngine whose only source is Cratebox's own
// engine (CrateboxKit.Engine) rendering into the output. With a 4-channel output (the FLX4 over USB) the
// master goes to 1/2 and the headphone mix to 3/4, like the web app's "FLX4 jack" headphone setting.
import AVFoundation
import CrateboxKit

final class AudioHost {
    static let sampleRate = 48000.0
    let engine = Engine(sampleRate: AudioHost.sampleRate)
    /// Cratebox USB's preview player: a second engine mixed in on top of the decks, only while it's on
    let preview = Engine(sampleRate: AudioHost.sampleRate)
    private let previewFlag: UnsafeMutablePointer<Bool> = { let p = UnsafeMutablePointer<Bool>.allocate(capacity: 1); p.initialize(to: false); return p }()
    private static let previewChunk = 1024
    private let previewScratch: [UnsafeMutablePointer<Float>] = (0..<8).map { _ in
        let p = UnsafeMutablePointer<Float>.allocate(capacity: AudioHost.previewChunk); p.initialize(repeating: 0, count: AudioHost.previewChunk); return p
    }
    var previewOn: Bool {
        get { previewFlag.pointee }
        set { previewFlag.pointee = newValue }
    }
    private var av = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var outputChannels = 2
    private(set) var routeName = ""
    var onRoute: (() -> Void)?
    var running: Bool { av.isRunning }

    func start() {
        configureSession()
        build()
        builtFor = routeKey()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // a category change is our own setCategory in restart() coming back: not a new route
            let why = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            if why != .categoryChange { self?.restartSoon() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if t == .ended { self?.restart() }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in self?.restartSoon() }
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
        measureLatency()
        onRoute?()
    }
    /// what iOS reports about the output, for Settings (and for working out a wrong routing)
    private(set) var diagnostics = ""
    var routing: String { UserDefaults.standard.string(forKey: "cb.routing") ?? "auto" }      // auto, swapped, stereo
    /// how far behind the audio clock you hear things (the output's latency plus a buffer): with Bluetooth
    /// this is 150-300 ms. The screen shows positions this much later, so waveforms match what you hear.
    private(set) var latency = 0.0
    private(set) var wireless = false
    private(set) var outputName = ""
    private func measureLatency() {
        let s = AVAudioSession.sharedInstance()
        latency = min(0.6, max(0, s.outputLatency + s.ioBufferDuration))
        let kinds: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]
        wireless = s.currentRoute.outputs.contains { kinds.contains($0.portType) }
        outputName = s.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
    }
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
        let eng = engine, prev = preview, flag = previewFlag, scratch = previewScratch, chunk = AudioHost.previewChunk
        var ptrs = [UnsafeMutablePointer<Float>]()
        ptrs.reserveCapacity(8)
        var sp = [UnsafeMutablePointer<Float>]()
        sp.reserveCapacity(8)
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            ptrs.removeAll(keepingCapacity: true)
            for b in list { if let d = b.mData { ptrs.append(d.assumingMemoryBound(to: Float.self)) } }
            if ptrs.isEmpty { return noErr }
            eng.render(ptrs, Int(frames))
            // Cratebox USB's preview, added on top (in chunks through preallocated buffers: nothing allocated here)
            if flag.pointee {
                let nch = min(ptrs.count, scratch.count)
                var done = 0
                while done < Int(frames) {
                    let n = min(chunk, Int(frames) - done)
                    sp.removeAll(keepingCapacity: true)
                    for c in 0..<nch { sp.append(scratch[c]) }
                    prev.render(sp, n)
                    for c in 0..<nch { let o = ptrs[c] + done, x = scratch[c]; for k in 0..<n { o[k] += x[k] } }
                    done += n
                }
            }
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
        preview.post(.output(outputMode(ch)))
        describe(); measureLatency()
        return true
    }
    /// a plug-in usually sends a route change and an engine configuration change together: one restart for both
    private var restartWork: DispatchWorkItem?
    private func restartSoon() {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // our own restart's setPreferredOutputNumberOfChannels comes back as a route change too: when the engine
            // is still running on the same outputs, there's nothing to rebuild (no second dropout)
            if self.av.isRunning && self.routeKey() == self.builtFor { NSLog("Cratebox audio: route notice, same outputs, engine running: no restart"); return }
            self.restart()
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }
    func restart() {
        restartWork?.cancel(); restartWork = nil
        if building { return }
        building = true
        defer { building = false }
        NSLog("Cratebox audio: restart (was on %@)", builtFor)
        _ = CBTry { self.av.stop() }
        configureSession()
        build()
        builtFor = routeKey()
    }
    /// the outputs the engine was last built for, and how many channels they have
    private var builtFor = ""
    private func routeKey() -> String {
        let s = AVAudioSession.sharedInstance()
        return s.currentRoute.outputs.map { $0.uid }.joined(separator: "+") + "/\(s.outputNumberOfChannels)"
    }
    /// headphones on a plain stereo output: mono master left, mono cue right (a splitter cable)
    func setSplit(_ on: Bool) { engine.post(.output(on ? .split : outputMode(outputChannels))); preview.post(.output(on ? .split : outputMode(outputChannels))) }
    func outputMode(_ ch: Int) -> OutputMode {
        if ch >= 4 { return routing == "swapped" ? .quadSwapped : .quad }
        return UserDefaults.standard.bool(forKey: "cb.split") ? .split : .stereo
    }
    func setRouting(_ r: String) { UserDefaults.standard.set(r, forKey: "cb.routing"); restart() }
}
