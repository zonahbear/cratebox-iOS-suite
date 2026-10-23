// Watch mic (personal/heat only, an experiment): listens for the Cratebox Mic watch app's voice over UDP and adds
// it to the master. A jitter buffer smooths the network; the phone's own Mute and Level always win over the watch.
// The voice goes straight onto the master outputs after the limiter, so it isn't in recordings and isn't limited.
import Foundation
import Network
import os

final class WatchMicReceiver: ObservableObject {
    static let shared = WatchMicReceiver()

    @Published private(set) var listening = false
    @Published private(set) var status = "Off"
    @Published private(set) var peer = ""
    @Published private(set) var bufferedMs = 0
    @Published private(set) var underruns = 0
    @Published private(set) var lost = 0
    @Published private(set) var watchMuted = false
    @Published private(set) var level: Float = 0
    /// phone-side controls (the watch can't override these)
    @Published var phoneMuted = false { didSet { ctl.pointee.phoneMuted = phoneMuted } }
    @Published var phoneLevel: Float = 1 { didSet { ctl.pointee.phoneLevel = phoneLevel } }
    /// jitter buffer target: more = fewer dropouts, more delay
    @Published var targetMs = UserDefaults.standard.object(forKey: "cb.watchMicMs") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(targetMs, forKey: "cb.watchMicMs"); ctl.pointee.target = targetMs * 48 }
    }

    /// what the audio thread reads; plain fields, written whole from the main or network queue
    struct Control { var gain: Float = 1; var watchMuted = false; var phoneMuted = false; var phoneLevel: Float = 1; var target = 60 * 48; var on = false }
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
    private var peak: Float = 0
    // audio-thread state
    private var priming = true
    private var smooth: Float = 0
    private var underrunCount: UInt32 = 0
    private let scratch: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096); p.initialize(repeating: 0, count: 4096); return p }()

    private init() { ctl.pointee.target = targetMs * 48 }

    func start() {
        guard listener == nil else { return }
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

    func stop() {
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
            if let data, let p = WatchMicPacket.decode(data) { self.handle(p, on: c) }
            if error == nil, self.conn === c { self.receive(c) }
        }
    }

    private func handle(_ p: WatchMicPacket, on c: NWConnection) {
        switch p {
        case let .audio(seq, gain, muted, samples):
            if let last = lastSeq, seq > last + 1 { lostCount &+= seq - last - 1 }
            lastSeq = seq
            ctl.pointee.gain = max(0, min(2, gain)); ctl.pointee.watchMuted = muted
            // 24 kHz → 48 kHz: each sample becomes two, the first halfway from the previous one
            var up = [Float](repeating: 0, count: samples.count * 2)
            for (i, s) in samples.enumerated() {
                let x = Float(s) / 32767
                up[2 * i] = (prev + x) * 0.5; up[2 * i + 1] = x; prev = x
                peak = max(peak, abs(x))
            }
            up.withUnsafeBufferPointer { ring.write($0.baseAddress!, $0.count) }
            // never let the delay creep up: past target + 150 ms, drop back to the target
            let target = ctl.pointee.target
            if ring.count > target + 150 * 48 { ring.trim(to: target) }
            packets += 1
            if packets % 10 == 0 {
                let ms = Float(ring.count) / 48, under = underrunCount, lostNow = lostCount, pk = peak
                peak = 0
                c.send(content: WatchMicPacket.stats(bufferedMs: ms, underruns: under, lost: lostNow).encode(), completion: .idempotent)
                DispatchQueue.main.async {
                    self.bufferedMs = Int(ms); self.underruns = Int(under); self.lost = Int(lostNow)
                    self.watchMuted = muted; self.level = pk
                }
            }
        case let .ping(id, sent):
            c.send(content: WatchMicPacket.pong(id: id, sent: sent).encode(), completion: .idempotent)
        default: break
        }
    }

    // MARK: audio thread

    /// Adds the voice to the master channels. master: 0 = channels 1/2, 2 = channels 3/4, -1 = channel 1 only (split).
    func mix(_ outs: [UnsafeMutablePointer<Float>], _ frames: Int, master: Int) {
        let c = ctl.pointee
        guard c.on, !outs.isEmpty else { return }
        let want: Float = (c.watchMuted || c.phoneMuted) ? 0 : c.gain * c.phoneLevel
        if priming {
            guard let n = ring.tryCount(), n >= c.target else { return }
            priming = false
        }
        let lc = master == 2 && outs.count >= 4 ? 2 : 0
        let rc = master == -1 ? -1 : (master == 2 && outs.count >= 4 ? 3 : (outs.count > 1 ? 1 : -1))
        var done = 0
        while done < frames {
            let k = min(4096, frames - done)
            guard let got = ring.tryRead(scratch, k) else { return }
            for j in 0..<got {
                smooth += (want - smooth) * 0.002          // ~10 ms ramp at 48 kHz
                let v = scratch[j] * smooth
                outs[lc][done + j] += v
                if rc >= 0 { outs[rc][done + j] += v }
            }
            done += got
            if got < k { priming = true; underrunCount &+= 1; return }
        }
    }
}
