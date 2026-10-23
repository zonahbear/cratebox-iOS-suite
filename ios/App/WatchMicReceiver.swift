// Watch mic (personal/heat only, an experiment): listens for the Cratebox Mic watch app's voice over UDP and adds
// it to the master. A jitter buffer smooths the network; the phone's own Mute and Level always win over the watch.
// The voice goes straight onto the master outputs after the limiter, so it isn't in recordings and isn't limited.
// Without shared Wi-Fi the watch falls back to Watch Connectivity (over Bluetooth): same packets, several per message.
import Accelerate
import Foundation
import Network
import os
import WatchConnectivity

final class WatchMicReceiver: ObservableObject {
    static let shared = WatchMicReceiver()

    @Published private(set) var listening = false
    @Published private(set) var status = "Off"
    @Published private(set) var peer = ""
    @Published private(set) var bufferedMs = 0
    /// the watch's round trip and late drops, as the watch reports them (its own screen is under the call screen)
    @Published private(set) var watchRttMs: Int?
    @Published private(set) var watchLateDrops = 0
    @Published private(set) var underruns = 0
    @Published private(set) var lost = 0
    @Published private(set) var watchMuted = false
    @Published private(set) var level: Float = 0
    /// which way the voice is arriving: "Wi-Fi" or "Bluetooth"
    @Published private(set) var path = ""
    /// the Bluetooth (Watch Connectivity) link as the phone sees it
    @Published private(set) var wcInfo = "Watch link: starting"
    /// phone-side controls (the watch can't override these)
    @Published var phoneMuted = false { didSet { ctl.pointee.phoneMuted = phoneMuted } }
    /// Settings: the mic's gain, set once for the room (dB)
    @Published var gainDb = UserDefaults.standard.object(forKey: "cb.watchMicGainDb") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(gainDb, forKey: "cb.watchMicGainDb"); setLevel() }
    }
    /// the board: the MIC knob in the mixer (MIDI-learnable), 0...1, 1 = the Settings gain
    @Published var volume = UserDefaults.standard.object(forKey: "cb.watchMicVol") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(volume, forKey: "cb.watchMicVol"); setLevel() }
    }
    /// feedback suppression (high-pass + automatic notches)
    @Published var feedbackOn = UserDefaults.standard.object(forKey: "cb.watchMicFeedback") as? Bool ?? true {
        didSet { UserDefaults.standard.set(feedbackOn, forKey: "cb.watchMicFeedback"); let on = feedbackOn; queue.async { self.fbOn = on } }
    }
    /// the notches the feedback filter has placed (Hz)
    @Published private(set) var notches: [Double] = []
    /// auto duck: while you talk, the tracks on the master drop by `duckDb`; the mic can also open only then
    @Published var duckOn = UserDefaults.standard.bool(forKey: "cb.duckOn") { didSet { UserDefaults.standard.set(duckOn, forKey: "cb.duckOn"); setDuck() } }
    @Published var duckDb = UserDefaults.standard.object(forKey: "cb.duckDb") as? Double ?? -12 { didSet { UserDefaults.standard.set(duckDb, forKey: "cb.duckDb"); setDuck() } }
    @Published var gateOn = UserDefaults.standard.object(forKey: "cb.micGate") as? Bool ?? true { didSet { UserDefaults.standard.set(gateOn, forKey: "cb.micGate"); setDuck() } }
    /// how loud (dBFS, after the mic gain) counts as talking
    @Published var voiceDb = UserDefaults.standard.object(forKey: "cb.voiceDb") as? Double ?? -35 { didSet { UserDefaults.standard.set(voiceDb, forKey: "cb.voiceDb"); let v = Float(voiceDb); queue.async { self.voiceThreshold = v } } }
    /// how long the duck holds after you stop talking (s)
    @Published var holdS = UserDefaults.standard.object(forKey: "cb.duckHold") as? Double ?? 0.6 { didSet { UserDefaults.standard.set(holdS, forKey: "cb.duckHold"); setDuck() } }
    /// true while the voice detector hears you (for the screen)
    @Published private(set) var talking = false
    /// which link to take the watch's voice from: "bt" (Watch Connectivity), "wifi" (UDP) or "auto" (both)
    @Published var mode = UserDefaults.standard.string(forKey: "cb.watchMicMode") ?? "bt" {
        didSet {
            UserDefaults.standard.set(mode, forKey: "cb.watchMicMode")
            let m = mode; queue.async { self.linkMode = m }
            if listening { stop(); start() }
        }
    }
    /// Bluetooth messages from the watch since Listen went on (to see whether anything arrives at all)
    @Published private(set) var btMessages = 0
    /// the watch's log, when it sends one (Send log to phone on the watch)
    @Published private(set) var watchLog = UserDefaults.standard.string(forKey: "cb.watchMicLog") ?? ""
    /// jitter buffer target: more = fewer dropouts, more delay
    @Published var targetMs = UserDefaults.standard.object(forKey: "cb.watchMicMs") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(targetMs, forKey: "cb.watchMicMs"); ctl.pointee.target = targetMs * 48 }
    }

    /// what the audio thread reads; plain fields, written whole from the main or network queue
    struct Control { var gain: Float = 1; var watchMuted = false; var phoneMuted = false; var level: Float = 1; var target = 60 * 48; var on = false
        var duckOn = false; var duckGain: Float = 0.25; var gateOn = true; var holdFrames = 28800
        /// bumped by the network queue every time it hears voice; the audio thread holds the duck for holdFrames after
        var voiceStamp: UInt32 = 0 }
    private let ctl: UnsafeMutablePointer<Control> = { let p = UnsafeMutablePointer<Control>.allocate(capacity: 1); p.initialize(to: Control()); return p }()
    /// the voice at 48 kHz, ready to mix
    private let ring = FloatRing(capacity: 48000 * 2)
    private let queue = DispatchQueue(label: "cb.watchmic")
    private var listener: NWListener?
    private var conn: NWConnection?
    private var lastSeq: UInt32?
    private var lostCount: UInt32 = 0
    private var prev: Float = 0
    private var packets = 0
    private var lowest = Int.max, lowWindow = 0
    private var trims: UInt32 = 0
    private var peak: Float = 0
    // audio-thread state
    private var priming = true
    private var smooth: Float = 0
    private var duckSmooth: Float = 1
    private var lastStamp: UInt32 = 0
    private var holdLeft = 0
    // voice detector (on `queue`)
    private var voiceThreshold: Float = -35
    private var floorDb: Float = -60
    private var voiceRun = 0
    private var sinceVoice = 1000
    private var underrunCount: UInt32 = 0
    private let wc = WatchMicWC()
    // on `queue`
    private let fb = MicFeedback(rate: WatchMic.rate)
    private var fbOn = true
    private var linkMode = "bt"
    private var btCount = 0
    private let scratch: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096); p.initialize(repeating: 0, count: 4096); return p }()

    /// Watch Connectivity starts with the app, not with Listen: a message from the watch can launch the app in the
    /// background, and it's dropped if nothing is the session's delegate by then (CrateboxApp touches .shared at launch).
    private init() {
        ctl.pointee.target = targetMs * 48
        fbOn = feedbackOn
        linkMode = mode
        voiceThreshold = Float(voiceDb)
        setDuck()
        setLevel()
        fb.onChange = { [weak self] f in DispatchQueue.main.async { self?.notches = f } }
        wc.onData = { [weak self] d, reply in self?.queue.async { self?.fromWatchConnectivity(d, reply) } }
        wc.onChange = { [weak self] info in DispatchQueue.main.async { self?.wcInfo = info } }
        wc.onLog = { [weak self] log in
            UserDefaults.standard.set(log, forKey: "cb.watchMicLog")
            DispatchQueue.main.async { self?.watchLog = log }
        }
        wc.activate()
    }

    func start() {
        guard !listening else { return }
        queue.async { self.btCount = 0 }
        btMessages = 0
        if mode == "bt" {
            ctl.pointee.on = true
            listening = true
            status = "Waiting for the watch (Bluetooth)"
            return
        }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: WatchMic.port)!)
            l.service = NWListener.Service(name: "Cratebox", type: WatchMic.service)
            l.stateUpdateHandler = { [weak self] s in
                let text: String
                switch s {
                case .ready: text = "Waiting for the watch"
                case .failed(let e): text = "Listener failed: \(e)"
                case .waiting(let e): text = "Listener waiting: \(e)"
                default: return
                }
                DispatchQueue.main.async { self?.status = text }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
            ctl.pointee.on = true
            listening = true
        } catch {
            status = "Couldn't listen: \(error.localizedDescription)"
        }
    }

    /// the volume knob is a fader-like curve (squared), so the bottom half is usable
    private func setLevel() { ctl.pointee.level = Float(pow(10, gainDb / 20) * volume * volume) }
    private func setDuck() {
        ctl.pointee.duckOn = duckOn; ctl.pointee.gateOn = gateOn
        ctl.pointee.duckGain = Float(pow(10, duckDb / 20)); ctl.pointee.holdFrames = Int(holdS * 48000)
    }
    func resetFeedback() { queue.async { self.fb.reset() } }

    func stop() {
        resetFeedback()
        listener?.cancel(); listener = nil
        conn?.cancel(); conn = nil
        ctl.pointee.on = false
        ring.clear()
        listening = false; status = "Off"; peer = ""; level = 0
    }

    /// this phone's Wi-Fi address, for typing into the watch if Bonjour doesn't find it
    var address: String {
        var out = "", ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return "—" }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), String(cString: a.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out = String(cString: host) }
        }
        return out.isEmpty ? "— (not on Wi-Fi)" : out
    }

    // MARK: network (on `queue`)

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        lastSeq = nil; prev = 0
        let who = "\(c.endpoint)"
        DispatchQueue.main.async { self.peer = who; self.status = "Watch connected" }
        c.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { DispatchQueue.main.async { self?.status = "Link failed: \(e)" } }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let p = WatchMicPacket.decode(data) {
                self.handle(p, via: "Wi-Fi") { c.send(content: $0, completion: .idempotent) }
            }
            if error == nil, self.conn === c { self.receive(c) }
        }
    }

    /// on `queue`: a Watch Connectivity message (several packets). A ping's reply carries a pong and the stats.
    private func fromWatchConnectivity(_ d: Data, _ reply: ((Data) -> Void)?) {
        // not listening, or Wi-Fi only: answer nothing (an empty reply), so the watch doesn't think the phone is taking the voice
        guard ctl.pointee.on, linkMode != "wifi" else { reply?(Data()); return }
        btCount += 1
        if btCount == 1 || btCount % 25 == 0 { let n = btCount; DispatchQueue.main.async { self.btMessages = n } }
        var answers = [Data]()
        for f in WatchMicFrames.split(d) {
            guard let p = WatchMicPacket.decode(f) else { continue }
            handle(p, via: "Bluetooth") { answers.append($0) }
        }
        if let reply {
            answers.append(WatchMicPacket.stats(bufferedMs: Float(ring.count) / 48, underruns: underrunCount, lost: lostCount).encode())
            reply(WatchMicFrames.join(answers))
        }
    }

    private func handle(_ p: WatchMicPacket, via: String, send: (Data) -> Void) {
        if path != via { DispatchQueue.main.async { self.path = via; self.status = "Watch connected (\(via))" } }
        switch p {
        case let .audio(seq, gain, muted, samples):
            if let last = lastSeq, seq > last + 1 { lostCount &+= seq - last - 1 }
            lastSeq = seq
            ctl.pointee.gain = max(0, min(2, gain)); ctl.pointee.watchMuted = muted
            // feedback suppression at 24 kHz; the high-pass and notches always run, the detector only when it's on
            var v = samples.map { Float($0) / 32767 }
            fb.process(&v, detect: fbOn)
            detectVoice(v, gain: max(0, min(2, gain)), muted: muted)
            // 24 kHz → 48 kHz: each sample becomes two, the first halfway from the previous one
            var up = [Float](repeating: 0, count: v.count * 2)
            for (i, x) in v.enumerated() {
                up[2 * i] = (prev + x) * 0.5; up[2 * i + 1] = x; prev = x
                peak = max(peak, abs(x))
            }
            let before = ring.count
            up.withUnsafeBufferPointer { ring.write($0.baseAddress!, $0.count) }
            // never let the delay creep up. A burst (Bluetooth sends 4 packets at once, and sometimes stalls then
            // catches up) leaves extra audio queued that never drains on its own, so: the lowest the buffer got
            // just before a packet, over each second, is delay we don't need beyond the target: drop it.
            // And past target + 150 ms, drop back to the target straight away.
            let target = ctl.pointee.target
            lowest = min(lowest, before)
            lowWindow += 1
            if lowWindow >= 100 {
                if lowest > target + 10 * 48 { ring.trim(to: max(target, ring.count - (lowest - target))); trims &+= 1 }
                lowest = Int.max; lowWindow = 0
            }
            if ring.count > target + 150 * 48 { ring.trim(to: target); trims &+= 1 }
            packets += 1
            if packets % 10 == 0 {
                let ms = Float(ring.count) / 48, under = underrunCount, lostNow = lostCount, pk = peak
                peak = 0
                send(WatchMicPacket.stats(bufferedMs: ms, underruns: under, lost: lostNow).encode())
                DispatchQueue.main.async {
                    self.bufferedMs = Int(ms); self.underruns = Int(under); self.lost = Int(lostNow)
                    self.watchMuted = muted; self.level = pk
                }
            }
        case let .ping(id, sent):
            send(WatchMicPacket.pong(id: id, sent: sent).encode())
        case let .report(rtt, late):
            DispatchQueue.main.async { self.watchRttMs = rtt > 0 ? Int(min(rtt, 60_000)) : nil; self.watchLateDrops = Int(late) }
        default: break
        }
    }

    /// on `queue`, one packet (10 ms): is that you talking? Louder than the threshold AND 10 dB over the room's
    /// floor (which follows the quietest level, so steady music bleeding into the mic doesn't count), for 30 ms.
    private func detectVoice(_ v: [Float], gain: Float, muted: Bool) {
        var ms: Float = 0
        vDSP_measqv(v, 1, &ms, vDSP_Length(v.count))
        let db = 10 * log10(max(ms, 1e-12)) + 20 * log10(max(gain, 1e-6)) + Float(gainDb)
        if db < floorDb { floorDb = max(-90, db) } else { floorDb = min(floorDb + 0.02, db) }   // up ~2 dB/s, down at once
        let voice = !muted && db > max(voiceThreshold, floorDb + 10)
        voiceRun = voice ? voiceRun + 1 : 0
        if voiceRun >= 3 { ctl.pointee.voiceStamp &+= 1; sinceVoice = 0 } else { sinceVoice += 1 }
        let now = sinceVoice * 10 < Int(holdS * 1000)
        if now != talkingQ { talkingQ = now; DispatchQueue.main.async { self.talking = now } }
    }
    private var talkingQ = false

    // MARK: audio thread

    /// Adds the voice to the master channels. master: 0 = channels 1/2, 2 = channels 3/4, -1 = channel 1 only (split).
    func mix(_ outs: [UnsafeMutablePointer<Float>], _ frames: Int, master: Int) {
        let c = ctl.pointee
        guard !outs.isEmpty else { return }
        let lc = master == 2 && outs.count >= 4 ? 2 : 0
        let rc = master == -1 ? -1 : (master == 2 && outs.count >= 4 ? 3 : (outs.count > 1 ? 1 : -1))
        // voice heard lately? (counts down here, so it lets go even if the watch stops sending)
        if c.voiceStamp != lastStamp { lastStamp = c.voiceStamp; holdLeft = c.holdFrames }
        let voice = c.on && holdLeft > 0
        holdLeft = max(0, holdLeft - frames)
        // auto duck: the tracks on the master only (the voice is added after), ~15 ms down, ~0.5 s back up
        let duckTo: Float = voice && c.duckOn ? c.duckGain : 1
        if duckTo < 1 || duckSmooth < 0.9999 {
            let rate: Float = duckTo < duckSmooth ? 0.0014 : 0.00004
            for j in 0..<frames {
                duckSmooth += (duckTo - duckSmooth) * rate
                outs[lc][j] *= duckSmooth
                if rc >= 0 { outs[rc][j] *= duckSmooth }
            }
        }
        guard c.on else { return }
        let open = !(c.duckOn && c.gateOn) || voice
        let want: Float = (c.watchMuted || c.phoneMuted || !open) ? 0 : c.gain * c.level
        if priming {
            guard let n = ring.tryCount(), n >= c.target else { return }
            priming = false
        }
        var done = 0
        while done < frames {
            let k = min(4096, frames - done)
            guard let got = ring.tryRead(scratch, k) else { return }
            for j in 0..<got {
                smooth += (want - smooth) * 0.002          // ~10 ms ramp at 48 kHz
                var v = scratch[j] * smooth
                // soft knee above -2 dBFS so a hot gain rounds off instead of clipping hard
                let a = abs(v)
                if a > 0.8 { v = (v < 0 ? -1 : 1) * (0.8 + 0.2 * tanhf((a - 0.8) / 0.2)) }
                outs[lc][done + j] += v
                if rc >= 0 { outs[rc][done + j] += v }
            }
            done += got
            if got < k { priming = true; underrunCount &+= 1; return }
        }
    }
}

/// The phone's end of Watch Connectivity for the watch mic: hands every message from the watch to WatchMicReceiver.
final class WatchMicWC: NSObject, WCSessionDelegate {
    var onData: ((Data, ((Data) -> Void)?) -> Void)?
    var onChange: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    private var error = ""
    func activate() {
        guard WCSession.isSupported() else { onChange?("Watch link: not supported"); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    private func report() {
        let w = WCSession.default
        let state = w.activationState == .activated ? "on" : w.activationState == .inactive ? "inactive" : "not active"
        var s = "Watch link \(state) · paired \(w.isPaired ? "yes" : "NO") · watch app \(w.isWatchAppInstalled ? "yes" : "NO") · watch app open \(w.isReachable ? "yes" : "no")"
        if !error.isEmpty { s += " · \(error)" }
        onChange?(s)
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { self.error = error.localizedDescription }
        report()
    }
    func sessionDidBecomeInactive(_ session: WCSession) { report() }
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionReachabilityDidChange(_ session: WCSession) { report() }
    func sessionWatchStateDidChange(_ session: WCSession) { report() }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { if let l = userInfo["micLog"] as? String { onLog?(l) } }
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) { onData?(messageData, nil) }
    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) { onData?(messageData, replyHandler) }
}
