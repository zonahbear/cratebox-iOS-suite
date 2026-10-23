// Cratebox Mic (personal/heat only, an experiment): the watch's mic streamed to Cratebox on the iPhone.
// watchOS only lets a third-party app open its own network connection during a CallKit call (TN3135), so going
// live starts an outgoing call "to Cratebox". While the call runs: the mic goes into a sink node, a 5 ms timer
// turns it into 24 kHz 16-bit packets and sends them over UDP to the phone, found by Bonjour or a typed address.
// With no shared Wi-Fi (no reply over UDP for 2 s) the same packets go by Watch Connectivity instead, 4 a message.
// Link "Bluetooth" skips the call and the network altogether: the mic runs as a plain recording (audio background
// mode) and everything goes by Watch Connectivity. "Wi-Fi" never uses Watch Connectivity. "Auto" is both, as above.
import AVFoundation
import CallKit
import Network
import os
import SwiftUI
import WatchConnectivity
import WatchKit

final class MicCall: NSObject, ObservableObject, CXProviderDelegate, WCSessionDelegate {
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
    /// "Wi-Fi" or "Bluetooth": which way the voice is going
    @Published private(set) var path = ""
    /// the Bluetooth (Watch Connectivity) link as the watch sees it, plus its last error: shown so a failed test says why
    @Published private(set) var wcInfo = ""
    @Published private(set) var inputInfo = ""
    @Published var muted = false { didSet { if oldValue != muted { syncMute() } } }
    /// 0...2, the crown
    @Published var gain = 1.0
    /// typed phone address; empty = find it with Bonjour
    @AppStorage("mic.host") var host = ""
    /// "bt", "wifi" or "auto"
    @Published var mode = UserDefaults.standard.string(forKey: "mic.mode") ?? "bt" { didSet { UserDefaults.standard.set(mode, forKey: "mic.mode") } }

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
    private var udpHeard = 0.0
    private var wcBatch: [Data] = []
    private var wcError = ""
    private var wcSent = 0, wcReplies = 0, wcErrors = 0
    /// Watch Connectivity messages sent but not yet answered (on `queue`). Apple queues sends it can't deliver yet and
    /// never drops them, so without a cap the delay grows for as long as the link is slower than the mic (seconds).
    private var wcInFlight: [Double] = []   // when each was sent
    /// bumped each time the mic starts, so answers to an earlier session's messages don't count
    private var wcGen = 0
    static let wcMaxInFlight = 2
    /// the most packets waiting for a free send (100 ms); past that the oldest go
    static let wcMaxBatch = 10
    /// times the watch threw away audio it was too late to send (on `queue`)
    private var backlogDrops = 0
    /// the last round trip (ms, on `queue`), sent on to the phone
    private var lastRtt = 0
    /// the most mic audio allowed to wait on the watch (frames at the mic's rate), set when the mic starts
    private var keepFrames = 1440
    /// the link chosen when going live, read on `queue`
    private var liveMode = "auto"
    /// Bluetooth mode: the audio session was activated by us, not by CallKit
    private var ownSession = false
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
        MicLog.start()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        MicLog.add("WC activated: state \(state.rawValue)\(error.map { ", error \($0.localizedDescription)" } ?? ""), reachable \(session.isReachable)")
        queue.async { if let error { self.wcError = "activate: \(error.localizedDescription)" }; self.refreshWC() }
    }
    func sessionReachabilityDidChange(_ session: WCSession) { MicLog.add("WC reachable \(session.isReachable)"); queue.async { self.refreshWC() } }
    /// sends this session's log and the last one to the phone (queued: it gets there even if the phone app isn't open)
    func sendLog() {
        guard WCSession.default.activationState == .activated else { status = "Bluetooth link not up yet"; return }
        WCSession.default.transferUserInfo(["micLog": "— last session —\n" + MicLog.previous + "\n— this session —\n" + MicLog.current])
        status = "Log sent to the phone"
    }

    /// on `queue`
    private func refreshWC() {
        var e = wcError
        if backlogDrops > 0 { e = "late drops \(backlogDrops)" + (e.isEmpty ? "" : " · " + e) }
        if wcSent + wcErrors > 0 { e = "sent \(wcSent) · replies \(wcReplies) · errors \(wcErrors)" + (e.isEmpty ? "" : " · " + e) }
        DispatchQueue.main.async { let s = self.wcSummary(e); if self.wcInfo != s { self.wcInfo = s } }
    }
    private func wcSummary(_ e: String) -> String {
        guard WCSession.isSupported() else { return "BT: not supported" }
        let w = WCSession.default
        let state = w.activationState == .activated ? "on" : w.activationState == .inactive ? "inactive" : "not active"
        var s = "BT \(state) · phone \(w.isReachable ? "in reach" : "NOT in reach") · app \(w.isCompanionAppInstalled ? "ok" : "MISSING")"
        if !e.isEmpty { s += " · \(e)" }
        return s
    }
    /// any thread: remembers why a Watch Connectivity send failed
    private func wcFailed(_ e: Error) {
        let ns = e as NSError
        queue.async {
            self.wcErrors += 1
            let msg = "err \(ns.code): \(ns.localizedDescription)"
            if msg != self.wcError { MicLog.add("WC send failed: \(msg)") }
            self.wcError = msg
        }
    }

    func askForMic() { AVAudioApplication.requestRecordPermission { ok in if !ok { DispatchQueue.main.async { self.status = "Mic not allowed: Settings → Privacy → Microphone" } } } }

    // MARK: call

    func goLive() {
        guard callID == nil, !live else { return }
        let m = mode
        queue.async { self.liveMode = m; self.backlogDrops = 0; self.wcSent = 0; self.wcReplies = 0; self.wcErrors = 0; self.wcError = "" }
        MicLog.add("go live, link \(m), WC reachable \(WCSession.default.isReachable)")
        if m == "bt" { goLiveBluetooth(); return }
        let id = UUID()
        callID = id
        status = "Starting call…"
        let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Cratebox"))
        calls.request(CXTransaction(action: start)) { error in
            if let error { MicLog.add("start call failed: \(error)"); DispatchQueue.main.async { self.callID = nil; self.status = "Call failed: \(error.localizedDescription)" } }
        }
    }

    /// no call: a plain recording session (it keeps running with the screen off once started), Watch Connectivity only
    private func goLiveBluetooth() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [])
            try s.setActive(true)
            ownSession = true
        } catch {
            MicLog.add("BT session failed: \(error)")
            status = "Mic session: \(error.localizedDescription)"
            return
        }
        live = true
        status = "Connecting to the phone over Bluetooth…"
        startAudio()
        armGiveUp()
    }

    /// gives the phone 10 s to answer
    private func armGiveUp() {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.live, !self.connected else { return }
            self.fail("No answer from Cratebox on the phone. Is Listen on in Cratebox HEAT, and is the phone nearby? (\(self.wcInfo))")
        }
        giveUp = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    func end() {
        MicLog.add("end tapped")
        guard let id = callID else { teardown(); return }
        calls.request(CXTransaction(action: CXEndCallAction(call: id))) { error in
            if error != nil { DispatchQueue.main.async { self.teardown() } }
        }
    }

    private func syncMute() {
        guard let id = callID else { return }
        calls.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) { _ in }
    }

    func providerDidReset(_ provider: CXProvider) { MicLog.add("provider reset"); DispatchQueue.main.async { self.teardown() } }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // the session is set up here; CallKit activates it and then calls didActivate
        MicLog.add("CallKit: start call")
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
        MicLog.add("CallKit: end call")
        DispatchQueue.main.async { self.teardown() }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        DispatchQueue.main.async { if self.muted != action.isMuted { self.muted = action.isMuted } }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MicLog.add("CallKit: audio on")
        DispatchQueue.main.async {
            guard self.callID != nil else { MicLog.add("audio on after the call ended: ignored"); return }
            self.live = true
            self.status = "Connecting to the phone…"
            self.startAudio()
            // the network only works during the call, so the call has to start first
            if self.mode != "bt" { self.connect() }
            self.armGiveUp()
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MicLog.add("CallKit: audio off")
        DispatchQueue.main.async { self.stopAudio() }
    }

    /// ends the call as failed (the watch shows it as a failed call, not a finished one)
    private func fail(_ why: String) {
        MicLog.add("fail: \(why)")
        if let id = callID { provider.reportCall(with: id, endedAt: Date(), reason: .failed) }
        teardown()
        status = why
    }

    /// on `queue`: something came back from the phone
    private func heard() {
        lastHeard = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            if self.lost { self.lost = false }
            guard self.live, !self.connected else { return }
            MicLog.add("phone answered")
            self.connected = true
            self.status = "Live"
            self.giveUp?.cancel(); self.giveUp = nil
            if let id = self.callID { self.provider.reportOutgoingCall(with: id, connectedAt: Date()) }
        }
    }

    private func teardown() {
        MicLog.add("teardown (live \(live), call \(callID != nil))")
        giveUp?.cancel(); giveUp = nil
        // stop the timer first so nothing reads the mic while it's taken down
        timer?.cancel(); timer = nil
        connected = false; lost = false
        stopAudio()
        if ownSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); ownSession = false }
        browser?.cancel(); browser = nil
        conn?.cancel(); conn = nil
        ready = false
        callID = nil
        live = false
        status = "Ready"; link = ""; rttMs = nil; phoneBufferMs = nil; level = 0
    }

    // MARK: audio

    private func startAudio() {
        stopAudio()                     // never two sinks on the input
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { MicLog.add("no mic input"); status = "No mic input"; return }
        inRate = fmt.sampleRate
        let io = AVAudioSession.sharedInstance().ioBufferDuration
        let keep = Int(fmt.sampleRate * max(0.03, io * 2))
        queue.async { self.keepFrames = keep }
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
        do { try engine.start(); MicLog.add("mic on: \(inputInfo)") } catch { MicLog.add("engine start failed: \(error)"); status = "Mic: \(error.localizedDescription)" }
        queue.async { self.pending.removeAll(); self.out.removeAll(); self.pos = 0; self.last = 0; self.wcBatch.removeAll(); self.wcInFlight.removeAll(); self.wcGen &+= 1 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    private func stopAudio() {
        guard sink != nil || engine.isRunning else { return }
        engine.stop()
        if let s = sink { engine.disconnectNodeOutput(engine.inputNode); engine.detach(s); sink = nil }
    }

    /// on `queue`: mic → 24 kHz 16-bit → packets
    private func pump() {
        // never send old audio: if the timer fell behind (screen off, busy watch), keep only the newest bit
        // (30 ms, or two of the mic's own buffers if those are bigger, so a normal delivery is never cut)
        if let have = ring.tryCount(), have > keepFrames { ring.trim(to: keepFrames); backlogDrops += 1 }
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
        // same for samples waiting to be packed: at most 3 packets (30 ms)
        let maxOut = keepFrames * Int(WatchMic.rate) / max(1, Int(inRate)) + WatchMic.packetSamples * 3
        if out.count > maxOut { out.removeFirst(out.count - maxOut); backlogDrops += 1 }
        let g = Float(gain), m = muted, now = ProcessInfo.processInfo.systemUptime
        // Wi-Fi while the phone answers over it; otherwise Watch Connectivity (Bluetooth) if the phone is reachable
        let udp = liveMode != "bt" && ready && now - udpHeard < 2
        let wc = liveMode != "wifi" && WCSession.default.activationState == .activated && WCSession.default.isReachable
        while out.count >= WatchMic.packetSamples {
            let chunk = Array(out.prefix(WatchMic.packetSamples))
            out.removeFirst(WatchMic.packetSamples)
            seq &+= 1
            let pkt = WatchMicPacket.audio(seq: seq, gain: g, muted: m, samples: chunk).encode()
            if udp { conn?.send(content: pkt, completion: .idempotent) } else if wc { wcBatch.append(pkt) }
        }
        if udp || !wc { wcBatch.removeAll(keepingCapacity: true) }
        // too much waiting for a free send: drop the oldest, never let it queue up
        if wcBatch.count > MicCall.wcMaxBatch { wcBatch.removeFirst(wcBatch.count - MicCall.wcMaxBatch); backlogDrops += 1 }
        tick += 1
        var ping: [Data]?
        if tick % 200 == 0 || (!connected && tick % 40 == 0) {   // a ping a second, 5 a second until the phone answers
            pingID &+= 1
            // with the ping goes the last round trip, so the phone can show it while the call screen covers ours
            let p = [WatchMicPacket.ping(id: pingID, sent: now).encode(),
                     WatchMicPacket.report(rttMs: UInt32(lastRtt), lateDrops: UInt32(backlogDrops)).encode()]
            if ready { for x in p { conn?.send(content: x, completion: .idempotent) } }
            ping = p
        }
        // an answer that never comes (no reply and no error) mustn't hold a slot forever
        wcInFlight.removeAll { now - $0 > 2 }
        // Bluetooth: at most 2 messages on the way. While they are, packets gather here (bigger messages, fewer of
        // them), so the link carries what it can and the delay stays put instead of growing.
        if !udp, wc, wcInFlight.count < MicCall.wcMaxInFlight, wcBatch.count >= 4 || (ping != nil && wcInFlight.isEmpty) {
            if let ping { wcBatch += ping }
            sendWC(wcBatch)
            wcBatch.removeAll(keepingCapacity: true)
        }
        if tick % 20 == 0 {                          // meter at 10 Hz
            let p = peak; peak = 0
            let gone = connected && now - lastHeard > 3
            let way = udp ? "Wi-Fi" : wc ? "Bluetooth" : "no link"
            DispatchQueue.main.async { self.level = p; if self.lost != gone { self.lost = gone }; if self.path != way { self.path = way } }
            refreshWC()
        }
    }

    /// on `queue`: one Watch Connectivity message, answered by the phone (that answer frees the slot, and carries the
    /// pong and the phone's stats)
    private func sendWC(_ frames: [Data]) {
        wcSent += 1; wcInFlight.append(ProcessInfo.processInfo.systemUptime)
        let gen = wcGen
        WCSession.default.sendMessageData(WatchMicFrames.join(frames), replyHandler: { [weak self] d in
            guard let self else { return }
            self.queue.async {
                guard gen == self.wcGen else { return }
                if !self.wcInFlight.isEmpty { self.wcInFlight.removeFirst() }; self.wcReplies += 1
                for f in WatchMicFrames.split(d) { if let p = WatchMicPacket.decode(f) { self.incoming(p) } }
            }
        }, errorHandler: { [weak self] e in
            guard let self else { return }
            self.queue.async { if gen == self.wcGen, !self.wcInFlight.isEmpty { self.wcInFlight.removeFirst() } }
            self.wcFailed(e)
        })
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
                self.udpHeard = ProcessInfo.processInfo.systemUptime
                self.incoming(p)
            }
            if error == nil, self.conn === c { self.receive(c) }
        }
    }

    /// on `queue`: a pong or stats from the phone, by either path
    private func incoming(_ p: WatchMicPacket) {
        switch p {
        case let .pong(_, sent):
            heard()
            let ms = Int(max(0, min(60_000, (ProcessInfo.processInfo.systemUptime - sent) * 1000)))
            lastRtt = ms
            DispatchQueue.main.async { self.rttMs = ms }
        case let .stats(buffered, under, lost):
            heard()
            DispatchQueue.main.async { self.phoneBufferMs = buffered.isFinite ? Int(max(0, min(60_000, buffered))) : nil; self.phoneDropouts = Int(under); self.phoneLost = Int(lost) }
        default: break
        }
    }
}
