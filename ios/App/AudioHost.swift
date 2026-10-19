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
            self?.av = AVAudioEngine(); self?.source = nil; self?.restart()
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
    private func build() {
        let s = AVAudioSession.sharedInstance()
        outputChannels = max(1, min(s.outputNumberOfChannels, 4))
        routeName = s.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        let ch = outputChannels >= 4 ? 4 : max(2, outputChannels)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(ch))!
        let fmt = AVAudioFormat(standardFormatWithSampleRate: AudioHost.sampleRate, channelLayout: layout)
        let eng = engine
        var ptrs = [UnsafeMutablePointer<Float>]()
        ptrs.reserveCapacity(4)
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            ptrs.removeAll(keepingCapacity: true)
            for b in list { if let d = b.mData { ptrs.append(d.assumingMemoryBound(to: Float.self)) } }
            eng.render(ptrs, Int(frames))
            return noErr
        }
        if let old = source { av.detach(old) }
        av.attach(node)
        av.connect(node, to: av.outputNode, format: fmt)
        source = node
        engine.post(.output(ch >= 4 ? .quad : .stereo))
        av.prepare()
        try? av.start()
        onRoute?()
    }
    func restart() {
        av.stop()
        configureSession()
        build()
    }
    /// headphones on a plain stereo output: mono master left, mono cue right (a splitter cable)
    func setSplit(_ on: Bool) { engine.post(.output(on ? .split : (outputChannels >= 4 ? .quad : .stereo))) }
}
