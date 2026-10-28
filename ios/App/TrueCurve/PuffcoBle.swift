// TrueCurve mini, the device side: the Puffco Lorax protocol over CoreBluetooth (a port of the web app's
// TC.Ble, which is TrueCurve's PuffcoBle) and a simulator with the same interface. Everything here runs on
// the main queue as small async reads/writes (~5 a second during a curve); the audio renders on its own
// real-time thread and never waits on any of it. The byte formats live in CrateboxKit (Lorax), with tests.
import CoreBluetooth
import QuartzCore
import CrateboxKit

struct SlotBackup: Codable { var temp: [UInt8]?; var time: [UInt8]? }

enum HeatError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

/// what the runner needs from a device (the Puffco or the simulator)
@MainActor protocol HeatDevice: AnyObject {
    var name: String { get }
    var id: String { get }
    var connected: Bool { get }
    var onDisconnect: (@MainActor () -> Void)? { get set }
    func connect() async throws
    func disconnect()
    func readTemp() async -> Double?
    func readState() async -> Int?
    func readBattery() async -> Int?
    func readActiveSlot() async -> UInt8?
    func setActiveSlot(_ s: UInt8) async -> Bool
    func backupSlot(_ s: UInt8) async -> SlotBackup
    func restoreSlot(_ s: UInt8, _ b: SlotBackup) async
    func writeProfileTemp(_ s: UInt8, _ f: Double) async -> Bool
    func writeProfileTime(_ s: UInt8, _ secs: Double) async -> Bool
    func start() async -> Bool
    func stop() async -> Bool
    func probeLiveFormat() async
    func setLiveTarget(_ f: Double) async -> Bool
}

private let SVC = CBUUID(string: Lorax.service), SVC_LEGACY = CBUUID(string: Lorax.serviceLegacy)
private let CH_CMD = CBUUID(string: Lorax.cmd), CH_REPLY = CBUUID(string: Lorax.reply), CH_VER = CBUUID(string: Lorax.version)
private typealias P = Lorax.Path

@MainActor
final class PuffcoBle: NSObject, HeatDevice {
    static let services = [SVC, SVC_LEGACY]
    let central: CBCentralManager
    let p: CBPeripheral
    let name: String
    var id: String { p.identifier.uuidString }
    let isProxy: Bool
    private(set) var connected = false
    var onDisconnect: (@MainActor () -> Void)?

    private var cmd: CBCharacteristic?, reply: CBCharacteristic?
    private var seq: UInt16 = 0
    private var pending: [UInt16: CheckedContinuation<(UInt8, [UInt8]), Error>] = [:]
    // one request at a time, like the web app's promise queue
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // the connection step being waited on (connect, discovery, pairing read, subscribe)
    private var step: CheckedContinuation<Void, Error>?
    private var stepId = 0
    private var withResp = true
    private var fmt: Lorax.Fmt = .f32, liveFmt: Lorax.Fmt?
    private var tempPath = P.temp
    private var soc = Lorax.SocDecoder()

    init(central: CBCentralManager, peripheral: CBPeripheral, name: String) {
        self.central = central; p = peripheral; self.name = name
        isProxy = name.range(of: "prox|pivot", options: [.regularExpression, .caseInsensitive]) != nil
        super.init()
        p.delegate = self
    }

    func connect() async throws {
        // the link often drops right after connecting (worst on Proxy), so connect + discovery are retried together
        var svc: CBService?
        for i in 1...3 where svc == nil {
            do {
                try await awaitStep(12) { central.connect(p) }
                try await Task.sleep(for: .milliseconds(300))
                try await awaitStep(10) { p.discoverServices(PuffcoBle.services) }
                svc = p.services?.first { $0.uuid == SVC } ?? p.services?.first { $0.uuid == SVC_LEGACY }
                if svc == nil { throw HeatError.msg("this isn't a Puffco (no Lorax service)") }
            } catch {
                central.cancelPeripheralConnection(p)
                if i == 3 { throw error }
                try? await Task.sleep(for: .milliseconds(800 * i))
            }
        }
        guard let svc else { throw HeatError.msg("no Lorax service") }
        try await awaitStep(10) { p.discoverCharacteristics([CH_CMD, CH_REPLY, CH_VER], for: svc) }
        guard let c = svc.characteristics?.first(where: { $0.uuid == CH_CMD }), let r = svc.characteristics?.first(where: { $0.uuid == CH_REPLY }) else {
            disconnect(); throw HeatError.msg("the device's command characteristics are missing")
        }
        cmd = c; reply = r
        // reading the version triggers iOS's pairing prompt; give the user time to accept it
        if let v = svc.characteristics?.first(where: { $0.uuid == CH_VER }) { try? await awaitStep(30) { p.readValue(for: v) } }
        // subscribing fails with "insufficient authentication" until pairing is done
        var subscribed = false
        for _ in 1...3 where !subscribed {
            do { try await awaitStep(15) { p.setNotifyValue(true, for: r) }; subscribed = true }
            catch { try? await Task.sleep(for: .milliseconds(1500)) }
        }
        guard subscribed else { disconnect(); throw HeatError.msg("couldn't subscribe to the device; accept the pairing prompt and try again") }
        try? await Task.sleep(for: .milliseconds(150))
        connected = true
        let both = c.properties.contains(.write) && c.properties.contains(.writeWithoutResponse)
        withResp = c.properties.contains(.write) || !c.properties.contains(.writeWithoutResponse)
        // unauthenticated clients get dropped after ~10 s, so the handshake has to land
        let authProblem = { (s: String) in s.range(of: "not paired|insufficient auth|encrypt", options: [.regularExpression, .caseInsensitive]) != nil }
        var why = ""
        for i in 1...3 {
            why = await auth()
            if why == "ok" || authProblem(why) { break }
            if i == 1 && both { withResp.toggle() }
            if i == 2 {
                p.setNotifyValue(false, for: r); try? await Task.sleep(for: .milliseconds(300))
                p.setNotifyValue(true, for: r); try? await Task.sleep(for: .milliseconds(300))
            }
        }
        guard why == "ok" else {
            connected = false; central.cancelPeripheralConnection(p)
            throw HeatError.msg(authProblem(why) ? "pair the device in the iPhone's Bluetooth settings first" : "handshake failed (\(why)); is the Puffco app connected to it?")
        }
        fmt = Lorax.detectFormat(await read(P.pTemp(0), max: 4), isProxy: isProxy)
    }

    func disconnect() {
        let was = connected
        connected = false
        central.cancelPeripheralConnection(p)
        failPending()
        if was { onDisconnect?() }
    }

    // called by HeatController's central delegate
    func didConnect() { finishStep(nil) }
    func didFail(_ e: Error?) { finishStep(e ?? HeatError.msg("couldn't connect")) }
    func lost() {
        finishStep(HeatError.msg("the device disconnected"))
        guard connected else { return }
        connected = false
        failPending()
        onDisconnect?()
    }
    private func failPending() {
        for k in pending.values { k.resume(throwing: HeatError.msg("Device disconnected")) }
        pending.removeAll()
    }

    private func awaitStep(_ secs: Double, _ start: () -> Void) async throws {
        stepId += 1
        let id = stepId
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            step = k
            start()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(secs))
                guard let self, self.stepId == id else { return }
                self.finishStep(HeatError.msg("the device didn't answer"))
            }
        }
    }
    fileprivate func finishStep(_ e: Error?) {
        guard let k = step else { return }
        step = nil
        if let e { k.resume(throwing: e) } else { k.resume() }
    }

    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func unlock() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }

    private func send(_ op: UInt8, _ payload: [UInt8] = [], timeout: Double = 3) async throws -> (UInt8, [UInt8]) {
        await lock()
        defer { unlock() }
        guard connected, let c = cmd else { throw HeatError.msg("Device is not connected") }
        seq = seq &+ 1; if seq == 0 { seq = 1 }
        let s = seq, frame = Data(Lorax.frame(seq: s, op: op, payload))
        return try await withCheckedThrowingContinuation { k in
            pending[s] = k
            p.writeValue(frame, for: c, type: withResp ? .withResponse : .withoutResponse)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: s)?.resume(throwing: HeatError.msg("BLE reply timed out"))
            }
        }
    }
    fileprivate func onReply(_ b: [UInt8]) {
        guard b.count >= 3 else { return }
        let s = UInt16(b[0]) | UInt16(b[1]) << 8
        pending.removeValue(forKey: s)?.resume(returning: (b[2], Array(b[3...])))
    }

    private func auth() async -> String {
        do {
            let (st, seed) = try await send(0)
            if st != 0 || seed.count < 16 { return "seed request returned status \(st)" }
            let (ok, _) = try await send(1, Lorax.token(seed: seed))
            return ok == 0 ? "ok" : "unlock returned status \(ok)"
        } catch {
            let m = error.localizedDescription
            return m.contains("timed out") ? "no reply from device" : m
        }
    }
    func read(_ path: String, max: UInt16 = 64) async -> [UInt8]? {
        guard let r = try? await send(16, Lorax.readPayload(path, max: max)), r.0 == 0 else { return nil }
        return r.1
    }
    func write(_ path: String, _ bytes: [UInt8]) async -> Bool {
        guard let r = try? await send(17, Lorax.writePayload(path, bytes)) else { return false }
        return r.0 == 0
    }

    func readTemp() async -> Double? {
        for path in tempPath == P.tempAlt ? [P.tempAlt, P.temp] : [P.temp, P.tempAlt] {
            if let c = Lorax.decodeC(await read(path, max: 4), fmt: fmt), c > 0 { tempPath = path; return (TrueCurve.cToF(c) * 10).rounded() / 10 }
        }
        return nil
    }
    func readState() async -> Int? { (await read(P.state, max: 1))?.first.map { Int($0) } }
    func readBattery() async -> Int? { soc.decode(await read(P.soc, max: 4)) }
    func readActiveSlot() async -> UInt8? { (await read(P.slot, max: 1))?.first }
    func setActiveSlot(_ s: UInt8) async -> Bool { await write(P.slot, [s]) }
    func backupSlot(_ s: UInt8) async -> SlotBackup { SlotBackup(temp: await read(P.pTemp(s), max: 4), time: await read(P.pTime(s), max: 4)) }
    func restoreSlot(_ s: UInt8, _ b: SlotBackup) async {
        if let t = b.temp, t.count >= 4 { _ = await write(P.pTemp(s), Array(t.prefix(4))) }
        if let t = b.time, t.count >= 4 { _ = await write(P.pTime(s), Array(t.prefix(4))) }
    }
    func writeProfileTemp(_ s: UInt8, _ f: Double) async -> Bool {
        let c = TrueCurve.fToC(min(TrueCurve.maxF, max(TrueCurve.minF, f)))
        for fm in [fmt, fmt == .i10 ? .f32 : .i10] {
            if !(await write(P.pTemp(s), Lorax.encodeC(c, fm))) { continue }
            if let b = await read(P.pTemp(s), max: 4), b.count >= 4, !(abs(Lorax.decodeAs(b, fm) - c) <= 1.5) { continue }
            fmt = fm
            return true
        }
        return false
    }
    /// Peak Pro: heat time in float seconds. Proxy units vary by firmware, so it's left alone and the run ends the session.
    func writeProfileTime(_ s: UInt8, _ secs: Double) async -> Bool {
        if isProxy { return false }
        if !(await write(P.pTime(s), Lorax.f32Bytes(secs))) { return false }
        guard let r = await read(P.pTime(s), max: 4), r.count >= 4 else { return true }
        return abs(Lorax.f32(r) - secs) <= 1
    }
    func start() async -> Bool { await write(P.mode, [7]) }
    func stop() async -> Bool {
        var ok = false
        for _ in 0..<3 { if await write(P.mode, [8]) { ok = true }; try? await Task.sleep(for: .milliseconds(45)) }
        return ok
    }
    func probeLiveFormat() async { if let f = Lorax.detectLiveFormat(await read(P.live, max: 4)) { liveFmt = f } }
    func setLiveTarget(_ f: Double) async -> Bool {
        let c = TrueCurve.fToC(min(TrueCurve.maxF, max(TrueCurve.minF, f))), first = liveFmt ?? fmt
        for fm in [first, first == .i10 ? .f32 : .i10] { if await write(P.live, Lorax.encodeC(c, fm)) { liveFmt = fm; return true } }
        return false
    }
}

extension PuffcoBle: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { finishStep(error) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated { finishStep(error) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { finishStep(error) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if ch.uuid == CH_REPLY { if let v = ch.value { onReply([UInt8](v)) } }
            else { finishStep(error) }
        }
    }
}

/// the web app's simulator: TrueCurve.SimHeater ticking in real time, with a little I/O delay and sensor noise
@MainActor
final class SimPuffco: HeatDevice {
    let name = "Simulator", id = "sim"
    private(set) var connected = false
    var onDisconnect: (@MainActor () -> Void)?
    private var h = TrueCurve.SimHeater()
    /// a pretend draw for PUFF (0...1)
    var airflow: Double { get { h.airflow } set { h.airflow = min(1, max(0, newValue)) } }
    private var ticker: Task<Void, Never>?

    func connect() async throws {
        connected = true
        ticker = Task { [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                let t = CACurrentMediaTime()
                var dt = min(t - last, 5)
                last = t
                while dt > 0 { let s = min(dt, 0.1); self.h.advance(s); dt -= s }
            }
        }
    }
    func disconnect() { ticker?.cancel(); let was = connected; connected = false; if was { onDisconnect?() } }
    private func io() async { try? await Task.sleep(for: .milliseconds(30 + Int.random(in: 0..<30))) }
    func readTemp() async -> Double? { await io(); return ((h.y + Double.random(in: -0.6...0.6)) * 10).rounded() / 10 }
    func readState() async -> Int? { await io(); return h.state }
    func readBattery() async -> Int? { 87 }
    func readActiveSlot() async -> UInt8? { UInt8(h.slotIdx) }
    func setActiveSlot(_ s: UInt8) async -> Bool { h.slotIdx = Int(s); return true }
    func backupSlot(_ s: UInt8) async -> SlotBackup { SlotBackup(temp: Lorax.f32Bytes(h.slots[Int(s)].temp), time: Lorax.f32Bytes(h.slots[Int(s)].time)) }
    func restoreSlot(_ s: UInt8, _ b: SlotBackup) async {
        if let t = b.temp, t.count >= 4 { h.slots[Int(s)].temp = Lorax.f32(t) }
        if let t = b.time, t.count >= 4 { h.slots[Int(s)].time = Lorax.f32(t) }
    }
    func writeProfileTemp(_ s: UInt8, _ f: Double) async -> Bool { await io(); h.slots[Int(s)].temp = f; return true }
    func writeProfileTime(_ s: UInt8, _ secs: Double) async -> Bool { await io(); h.slots[Int(s)].time = secs; return true }
    func start() async -> Bool { await io(); h.start(); return true }
    func stop() async -> Bool { await io(); h.stop(); return true }
    func probeLiveFormat() async {}
    func setLiveTarget(_ f: Double) async -> Bool { await io(); h.setLiveTarget(f); return true }
}
