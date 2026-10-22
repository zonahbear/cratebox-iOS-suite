// TrueCurve mini, the runner: pick a curve, press Start, go back to the decks. A port of the web app's TC
// panel logic (TrueCurve's runCurve without the chart): back up profile slot 4, write the curve's start
// temperature, preheat, then steer the live target ~5 times a second with the predictive driver, and put
// the slot back after. Safety rules kept from TrueCurve: 600°F cutoff, targets clamped 350–590°F, and on a
// lost link the device finishes its own cycle. Runs on the main actor as small awaits; it never touches the
// audio engine, so playback carries on while the device heats.
import CoreBluetooth
import QuartzCore
import UIKit
import CrateboxKit

@MainActor
final class HeatController: NSObject, ObservableObject {
    static let shared = HeatController()
    enum Phase { case idle, prep, preheat, running }
    struct Found: Identifiable { let id: UUID; let name: String; let p: CBPeripheral }

    @Published private(set) var dev: HeatDevice?
    @Published private(set) var phase = Phase.idle
    /// the HEAT button's text and the panel's device line, only republished when they change
    @Published private(set) var label = "HEAT"
    @Published private(set) var devText = "No device"
    @Published private(set) var msg = ""
    @Published var name: String { didSet { UserDefaults.standard.set(name, forKey: "cb.tc.last") } }
    /// curves pasted from TrueCurve ({name: {points, smooth}}, same JSON as its tc_curves)
    @Published private(set) var saved: [String: TrueCurve.CurveDef]
    @Published private(set) var found: [Found] = []
    /// other named Bluetooth devices nearby, offered when no Puffco is recognised (a renamed device, say)
    @Published private(set) var others: [Found] = []
    @Published private(set) var scanning = false
    var running: Bool { phase != .idle }
    var connected: Bool { dev != nil }
    var panelOpen = false
    var onStatus: ((String) -> Void)?

    private var live: Double?, target: Double?, t: Double?, end = 0.0, battery: Int?
    private var abort = false
    private var central: CBCentralManager?
    private var ble: PuffcoBle?
    private var idleTask: Task<Void, Never>?
    private var scanStop: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    override init() {
        saved = (UserDefaults.standard.data(forKey: "cb.tc.curves")).flatMap { try? JSONDecoder().decode([String: TrueCurve.CurveDef].self, from: $0) } ?? [:]
        name = UserDefaults.standard.string(forKey: "cb.tc.last") ?? TrueCurve.defaultName
        super.init()
        if !curveNames.contains(name) { name = TrueCurve.defaultName }
    }

    /// presets (unless a pasted curve has the same name), then the pasted ones
    var presetNames: [String] { TrueCurve.presets.map { $0.name }.filter { saved[$0] == nil } }
    var savedNames: [String] { saved.keys.sorted() }
    var curveNames: [String] { presetNames + savedNames }
    func curveDef(_ n: String) -> TrueCurve.CurveDef {
        if let c = saved[n], c.points.count >= 2 { return c }
        return TrueCurve.preset(n) ?? TrueCurve.preset(TrueCurve.defaultName)!
    }

    private func say(_ m: String) { msg = m; render() }
    private func f0(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "--" }
    private func render() {
        let l: String
        switch phase {
        case .idle: l = "HEAT"
        case .prep: l = "HEAT…"
        case .preheat: l = "HEAT \(f0(live))° ↑\(f0(target))"
        case .running: l = "HEAT \(f0(live))° \(Int(t ?? 0))/\(Int(end.rounded()))s"
        }
        if l != label { label = l }
        let bat = battery.map { " · \($0)%" } ?? ""
        let d = dev.map { "\($0.name)\(bat) · bowl \(f0(live))°F" } ?? "No device"
        if d != devText { devText = d }
    }

    // ---- connecting ----

    /// look for a Puffco; the one used last time connects by itself, others are listed to pick from.
    /// The Bluetooth permission prompt comes up here, the first time, not at launch.
    func scan() {
        found = []; others = []
        scanning = true
        say("Looking for your Puffco… (wake it up if it's asleep)")
        if let c = central { stateChanged(c) }
        else { central = CBCentralManager(delegate: self, queue: .main) }   // scans once it says it's on
    }
    private func startScan(_ c: CBCentralManager) {
        // a Puffco already connected to the phone (the Puffco app, or iOS holding the bond) stops advertising, so
        // a scan never sees it; iOS shares that connection with any app that asks for it by service
        for p in c.retrieveConnectedPeripherals(withServices: PuffcoBle.services) { add(p, name: p.name ?? "Puffco", puffco: true) }
        // name filters are unreliable on Apple platforms, so scan everything and filter here
        c.scanForPeripherals(withServices: nil, options: nil)
        scanStop?.cancel()
        scanStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.scanning else { return }
            self.stopScan()
            if self.dev == nil && self.ble == nil {
                self.say(!self.found.isEmpty ? "Pick your device." : self.others.isEmpty ? "No Bluetooth devices found. Is Bluetooth on, and the Puffco awake?"
                    : "No Puffco recognised. If yours has its own name, pick it from the list below.")
            }
        }
    }
    private func stopScan() { central?.stopScan(); scanning = false }

    func pick(_ f: Found) {
        guard let c = central, ble == nil else { return }
        stopScan()
        let b = PuffcoBle(central: c, peripheral: f.p, name: f.name)
        ble = b
        connect(b)
    }
    func useSimulator() { stopScan(); connect(SimPuffco()) }
    func disconnect() { dev?.disconnect() }

    private func connect(_ d: HeatDevice) {
        say(d is SimPuffco ? "Starting the simulator…" : "Connecting to \(d.name)… (accept the pairing prompt if one comes up)")
        d.onDisconnect = { [weak self] in
            guard let self else { return }
            if self.running { self.abort = true }
            self.dev = nil; self.ble = nil
            self.say(self.running ? "Connection lost mid-curve; the device finishes its own cycle at its last temperature." : "Disconnected.")
        }
        Task {
            do {
                try await d.connect()
                dev = d
                if d is PuffcoBle { defaults.set(d.id, forKey: "cb.tc.device") }
                found = []
                say("Connected to \(d.name).")
                idle()
            } catch {
                ble = nil
                say("Couldn't connect: \(error.localizedDescription)")
            }
        }
    }

    /// bowl temperature and battery while no curve runs (less often when the panel is closed)
    private func idle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            var n = 0
            while let self, let d = self.dev, d.connected, !Task.isCancelled {
                if !self.running {
                    self.live = await d.readTemp()
                    if n % 30 == 0 { self.battery = await d.readBattery() }
                    self.render()
                }
                n += 1
                try? await Task.sleep(for: .seconds(self.panelOpen ? 1 : 3))
            }
        }
    }

    // ---- running a curve ----

    /// Start (then straight back to the decks: the HEAT button carries the temperature) or Stop
    func toggle() {
        if running { abort = true; say("Stopping…") }
        else if dev != nil { phase = .prep; render(); let n = name; Task { await run(n) } }
    }

    private func modelKey(_ d: HeatDevice) -> String { "cb.tc.model." + d.id }

    private func run(_ name: String) async {
        guard let dev else { phase = .idle; render(); return }
        let def = curveDef(name)
        guard let curve = TrueCurve.Curve(def.points, smooth: def.smooth) else { phase = .idle; say("That curve has no length."); return }
        let slot = TrueCurve.slot, mk = modelKey(dev)
        let model = defaults.data(forKey: mk).flatMap { try? JSONDecoder().decode(TrueCurve.HeaterModel.self, from: $0) } ?? TrueCurve.HeaterModel()
        var drv = TrueCurve.Driver(curve, model), learner = TrueCurve.Learner(model)
        var backup: SlotBackup?, origSlot: UInt8?, completed = false, errSum = 0.0, errN = 0
        abort = false; phase = .prep; t = nil; end = curve.end; target = curve.at(0)
        say("Setting up \"\(name)\"…")
        let now = { CACurrentMediaTime() }
        func heating(_ s: Int?) -> Bool { s.map { TrueCurve.heating.contains($0) } ?? false }

        func body() async throws {
            if heating(await dev.readState()) { _ = await dev.stop(); try? await Task.sleep(for: .milliseconds(1500)) }
            origSlot = await dev.readActiveSlot()
            backup = await dev.backupSlot(slot)
            let startF = curve.at(0).rounded()
            guard await dev.writeProfileTemp(slot, startF) else { throw HeatError.msg("the device refused the start temperature") }
            _ = await dev.writeProfileTime(slot, min(120, (curve.end + 10).rounded(.up)))
            _ = await dev.setActiveSlot(slot)
            guard await dev.start() else { throw HeatError.msg("the device didn't accept the start command") }
            phase = .preheat; target = startF
            say("Preheating to \(Int(startF))°F. Back to the decks; it'll run on its own.")
            let p0 = now()
            while !abort {
                live = await dev.readTemp()
                let st = await dev.readState(), tp = now() - p0, y = live
                render()
                if let y, y >= TrueCurve.cutoffF { throw HeatError.msg("overheat cutoff at \(y)°F") }
                // some firmware (Proxy) says "heating" long before the bowl is hot, so the temperature has to agree too
                if let y, y >= startF - 8 || (heating(st) && st != 7 && y >= startF - 30) { break }
                if tp > 6 && !heating(st) { throw HeatError.msg("the device stopped heating during preheat (at \(f0(y))°F)") }
                if tp > 70 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if abort { return }
            await dev.probeLiveFormat()
            phase = .running
            say("Running \"\(name)\".")
            let t0 = now()
            var last = t0, sent = startF, sentAt = 0.0, tick = 0
            while !abort {
                let tn = now(), t = tn - t0, dt = tn - last
                last = tn
                if t >= curve.end { completed = true; break }
                let y = await dev.readTemp()
                if tick % 3 == 0 {
                    let st = await dev.readState()
                    if t > 2 && !heating(st) { say("The device ended its heat cycle \(Int(t.rounded())) s in."); break }
                }
                tick += 1
                if let y, y >= TrueCurve.cutoffF { throw HeatError.msg("overheat cutoff at \(y)°F") }
                let u = (drv.command(t, y, dt) * 10).rounded() / 10, diff = abs(u - sent)
                if diff >= 1.5 || (diff >= 0.5 && tn - sentAt > 1.5), await dev.setLiveTarget(u) { sent = u; sentAt = tn }
                learner.add(t, y, sent)
                let r = curve.at(t)
                self.t = t; live = y; target = r
                if let y, t > 1 { errSum += abs(y - r); errN += 1 }
                render()
                try? await Task.sleep(for: .milliseconds(Int(max(0, 0.2 - (now() - tn)) * 1000)))
            }
        }

        do { try await body() } catch { say("Stopped: \(error.localizedDescription)") }
        if dev.connected {
            _ = await dev.stop()
            if let backup { await dev.restoreSlot(slot, backup) }
            if let origSlot { _ = await dev.setActiveSlot(origSlot) }
        }
        if errN > 10 {
            say("\(completed ? "Done" : "Stopped"): \"\(name)\", \(String(format: "%.1f", errSum / Double(errN)))°F average off the curve.")
            if learner.n > 15 {
                var m = learner.m
                m.dead = model.dead; m.runs = model.runs + 1
                if let data = try? JSONEncoder().encode(m) { defaults.set(data, forKey: mk) }
            }
        } else if abort && self.dev != nil { say("Stopped.") }
        phase = .idle; t = nil; target = nil
        render()
        onStatus?(completed ? "Heat curve \"\(name)\" done" : "Heat curve \"\(name)\" stopped")
    }

    /// paste the JSON from TrueCurve's "Copy curves for Cratebox"
    func paste() {
        guard let txt = UIPasteboard.general.string, !txt.isEmpty else { say("Nothing to paste: in TrueCurve, press Copy curves for Cratebox first."); return }
        guard let got = TrueCurve.parseCurves(txt) else { say("That isn't TrueCurve's curve list."); return }
        guard !got.isEmpty else { say("No curves found in that text."); return }
        saved.merge(got) { _, new in new }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "cb.tc.curves") }
        say("Added \(got.count) curve\(got.count > 1 ? "s" : "").")
    }

    /// CI screenshots (`-demo -heat`): the simulator running the default curve
    func demo() {
        guard CommandLine.arguments.contains("-heat"), dev == nil else { return }
        useSimulator()
        Task { try? await Task.sleep(for: .seconds(1)); name = TrueCurve.defaultName; toggle() }
    }
}

extension HeatController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated { stateChanged(c) }
    }
    fileprivate func stateChanged(_ c: CBCentralManager) {
        guard scanning else { return }
        switch c.state {
        case .poweredOn: startScan(c)
        case .unauthorized: stopScan(); say("Cratebox Suite isn't allowed to use Bluetooth: turn it on in Settings → Privacy & Security → Bluetooth.")
        case .poweredOff: stopScan(); say("Bluetooth is off.")
        case .unsupported: stopScan(); say("This device has no Bluetooth LE.")
        default: break
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // like the web app's filters: the Lorax service, a Puffco name, or Puffco's Bluetooth company id (0x0c03)
        let mfr = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let looksPuffco = svcs.contains { [Lorax.service, Lorax.serviceLegacy].contains($0.uuidString.lowercased()) }
            || ["peak", "proxy", "puff", "pivot"].contains { name.lowercased().hasPrefix($0) }
            || (mfr.map { $0.count >= 2 && $0[$0.startIndex] == 0x03 && $0[$0.startIndex + 1] == 0x0c } ?? false)
        MainActor.assumeIsolated { add(p, name: name, puffco: looksPuffco) }
    }
    fileprivate func add(_ p: CBPeripheral, name: String, puffco: Bool) {
        guard scanning, !found.contains(where: { $0.id == p.identifier }) else { return }
        let f = Found(id: p.identifier, name: name.isEmpty ? "Puffco" : name, p: p)
        if !puffco {
            if !name.isEmpty && others.count < 12 && !others.contains(where: { $0.id == p.identifier }) { others.append(f) }
            return
        }
        others.removeAll { $0.id == p.identifier }
        found.append(f)
        if p.identifier.uuidString == defaults.string(forKey: "cb.tc.device") || p.state == .connected { pick(f) }
        else if found.count == 1 { say("Found \(f.name). Tap it to connect.") }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { if ble?.p == p { ble?.didConnect() } }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if ble?.p == p { ble?.didFail(error) } }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if ble?.p == p { ble?.lost() } }
    }
}
