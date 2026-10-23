// Cratebox Mic (personal/heat only, an experiment): the watch's mic streamed to Cratebox on the iPhone.
// watchOS only lets a third-party app open its own network connection during a CallKit call (TN3135), so going
// live starts an outgoing call "to Cratebox". While the call runs: the mic goes into a sink node, a 5 ms timer
// turns it into 24 kHz 16-bit packets and sends them over UDP to the phone, found by Bonjour or a typed address.
import AVFoundation
import CallKit
import Network
import os
import SwiftUI
import WatchKit

final class MicCall: NSObject, ObservableObject, CXProviderDelegate {
    @Published private(set) var live = false
    @Published private(set) var status = "Ready"
    @Published private(set) var link = ""
    @Published private(set) var rttMs: Int?
    @Published private(set) var phoneBufferMs: Int?
    @Published private(set) var phoneDropouts = 0
    @Published private(set) var phoneLost = 0
    @Published private(set) var level: Float = 0
    /// the phone has answered (a pong or stats came back); only then is the call reported as connected
    @Published private(set) var connected = false
    /// connected, but nothing back from the phone for 3 s
    @Published private(set) var lost = false
    @Published private(set) var inputInfo = ""
    @Published var muted = false { didSet { if oldValue != muted { syncMute() } } }
    /// 0...2, the crown
    @Published var gain = 1.0
    /// typed phone address; empty = find it with Bonjour
    @AppStorage("mic.host") var host = ""

    private let provider: CXProvider
    private let calls = CXCallController()
    private var callID: UUID?
    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private let ring = FloatRing(capacity: 48000)
    private var inRate = 48000.0
    private let queue = DispatchQueue(label: "cb.mic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var ready = false
    private var seq: UInt32 = 0
    private var pingID: UInt32 = 0
    private var tick = 0
    private var lastHeard = 0.0
    private var giveUp: DispatchWorkItem?
    // resampler state (on `queue`)
    private var pending: [Float] = []
    private var pos = 0.0
    private var last: Float = 0
    private var out: [Int16] = []
    private let drain: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 48000); p.initialize(repeating: 0, count: 48000); return p }()
    private var peak: Float = 0

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func askForMic() { AVAudioApplication.requestRecordPermission { ok in if !ok { DispatchQueue.main.async { self.status = "Mic not allowed: Settings → Privacy → Microphone" } } } }

    // MARK: call

    func goLive() {
        guard callID == nil else { return }
        let id = UUID()
        callID = id
        status = "Starting call…"
        let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Cratebox"))
        calls.request(CXTransaction(action: start)) { error in
            if let error { DispatchQueue.main.async { self.callID = nil; self.status = "Call failed: \(error.localizedDescription)" } }
        }
    }

    func end() {
        guard let id = callID else { teardown(); return }
        calls.request(CXTransaction(action: CXEndCallAction(call: id))) { error in
            if error != nil { DispatchQueue.main.async { self.teardown() } }
        }
    }

    private func syncMute() {
        guard let id = callID else { return }
        calls.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) { _ in }
    }

    func providerDidReset(_ provider: CXProvider) { teardown() }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // the session is set up here; CallKit activates it and then calls didActivate
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [])
        } catch {
            status = "Audio session: \(error.localizedDescription)"
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
        // "connected" is reported in heard(), once the phone actually answers
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        teardown()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        DispatchQueue.main.async { if self.muted != action.isMuted { self.muted = action.isMuted } }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        DispatchQueue.main.async {
            self.live = true
            self.status = "Connecting to the phone…"
            self.startAudio()
            self.connect()
            // the network only works during the call, so the call has to start first; give the phone 10 s to answer
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.live, !self.connected else { return }
                self.fail("No answer from Cratebox on the phone. Is Listen on, and are both on the same Wi-Fi?")
            }
            self.giveUp = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DispatchQueue.main.async { self.stopAudio() }
    }

    /// ends the call as failed (the watch shows it as a failed call, not a finished one)
    private func fail(_ why: String) {
        if let id = callID { provider.reportCall(with: id, endedAt: Date(), reason: .failed) }
        teardown()
        status = why
    }

    /// on `queue`: something came back from the phone
    private func heard() {
        lastHeard = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            if self.lost { self.lost = false }
            guard self.live, !self.connected, let id = self.callID else { return }
            self.connected = true
            self.status = "Live"
            self.giveUp?.cancel(); self.giveUp = nil
            self.provider.reportOutgoingCall(with: id, connectedAt: Date())
        }
    }

    private func teardown() {
        giveUp?.cancel(); giveUp = nil
        connected = false; lost = false
        stopAudio()
        timer?.cancel(); timer = nil
        browser?.cancel(); browser = nil
        conn?.cancel(); conn = nil
        ready = false
        callID = nil
        live = false
        status = "Ready"; link = ""; rttMs = nil; phoneBufferMs = nil; level = 0
    }

    // MARK: audio

    private func startAudio() {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { status = "No mic input"; return }
        inRate = fmt.sampleRate
        inputInfo = "\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, buffer \(Int(AVAudioSession.sharedInstance().ioBufferDuration * 1000)) ms"
        ring.clear()
        let ring = self.ring
        let node = AVAudioSinkNode { _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            if let d = list.first?.mData { _ = ring.tryWrite(d.assumingMemoryBound(to: Float.self), Int(frames)) }
            return noErr
        }
        engine.attach(node)
        engine.connect(input, to: node, format: fmt)
        sink = node
        do { try engine.start() } catch { status = "Mic: \(error.localizedDescription)" }
        queue.async { self.pending.removeAll(); self.out.removeAll(); self.pos = 0; self.last = 0 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    private func stopAudio() {
        engine.stop()
        if let s = sink { engine.disconnectNodeOutput(engine.inputNode); engine.detach(s); sink = nil }
    }

    /// on `queue`: mic → 24 kHz 16-bit → packets
    private func pump() {
        let n = ring.read(drain, 48000)
        if n > 0 {
            let step = inRate / WatchMic.rate
            // crude anti-alias for 48 → 24 kHz: average neighbours (nulls the top of the band)
            for i in 0..<n {
                let x = drain[i]
                pending.append(step >= 1.5 ? (x + last) * 0.5 : x)
                last = x
            }
            while pos + 1 < Double(pending.count) {
                let i = Int(pos), f = Float(pos - Double(i))
                let s = pending[i] + (pending[i + 1] - pending[i]) * f
                out.append(Int16(max(-1, min(1, s)) * 32767))
                peak = max(peak, abs(s))
                pos += step
            }
            let used = min(Int(pos), pending.count - 1)
            if used > 0 { pending.removeFirst(used); pos -= Double(used) }
        }
        let g = Float(gain), m = muted
        while out.count >= WatchMic.packetSamples {
            let chunk = Array(out.prefix(WatchMic.packetSamples))
            out.removeFirst(WatchMic.packetSamples)
            seq &+= 1
            if ready { conn?.send(content: WatchMicPacket.audio(seq: seq, gain: g, muted: m, samples: chunk).encode(), completion: .idempotent) }
        }
        tick += 1
        if tick % 200 == 0 || (!connected && tick % 40 == 0), ready {   // a ping a second, 5 a second until the phone answers
            pingID &+= 1
            conn?.send(content: WatchMicPacket.ping(id: pingID, sent: ProcessInfo.processInfo.systemUptime).encode(), completion: .idempotent)
        }
        if tick % 20 == 0 {                          // meter at 10 Hz
            let p = peak; peak = 0
            let gone = connected && ProcessInfo.processInfo.systemUptime - lastHeard > 3
            DispatchQueue.main.async { self.level = p; if self.lost != gone { self.lost = gone } }
        }
    }

    // MARK: network (only works while the call is up)

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty {
            open(.hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: WatchMic.port)!), name: h)
            return
        }
        link = "Looking for Cratebox…"
        let b = NWBrowser(for: .bonjour(type: WatchMic.service, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.conn == nil, let r = results.first else { return }
            DispatchQueue.main.async { self.open(r.endpoint, name: "Cratebox (Bonjour)") }
        }
        b.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { DispatchQueue.main.async { self?.link = "Bonjour failed: \(e)" } }
            if case .waiting(let e) = s { DispatchQueue.main.async { self?.link = "Bonjour waiting: \(e)" } }
        }
        b.start(queue: queue)
        browser = b
    }

    private func open(_ endpoint: NWEndpoint, name: String) {
        conn?.cancel()
        let c = NWConnection(to: endpoint, using: .udp)
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            let text: String
            switch s {
            case .ready: self.ready = true; text = "Sending to \(name)"
            case .waiting(let e): self.ready = false; text = "Waiting: \(e)"
            case .failed(let e): self.ready = false; text = "Failed: \(e)"
            case .preparing: text = "Connecting to \(name)…"
            default: return
            }
            DispatchQueue.main.async { self.link = text }
        }
        c.start(queue: queue)
        conn = c
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let p = WatchMicPacket.decode(data) {
                switch p {
                case let .pong(_, sent):
                    self.heard()
                    let ms = Int((ProcessInfo.processInfo.systemUptime - sent) * 1000)
                    DispatchQueue.main.async { self.rttMs = ms }
                case let .stats(buffered, under, lost):
                    self.heard()
                    DispatchQueue.main.async { self.phoneBufferMs = Int(buffered); self.phoneDropouts = Int(under); self.phoneLost = Int(lost) }
                default: break
                }
            }
            if error == nil, self.conn === c { self.receive(c) }
        }
    }
}
