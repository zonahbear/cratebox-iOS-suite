// Deck Bridge: Cratebox as a touch controller for rekordbox's decks 3 and 4 (or 1 and 2).
//
// Transport: CoreMIDI's own, nothing extra on the phone.
//  · Network (Wi-Fi / Ethernet): iOS's RTP-MIDI network session. A Mac sees it in Audio MIDI Setup →
//    MIDI Network Setup (built in); a Windows PC with the free rtpMIDI driver (Tobias Erichsen). rekordbox then
//    sees it as a MIDI device like any other.
//  · USB cable to a Mac: Audio MIDI Setup's iOS device (IDAM, "Enable") shows up as a MIDI port.
//  · Bluetooth LE MIDI: the phone advertises itself; a Mac pairs it in Audio MIDI Setup → Bluetooth.
// Messages go out on every one of those that's connected; rekordbox's lights come back the same way.
// The message layout and the rekordbox mapping file are CrateboxKit.DeckBridgeMap.
import CoreMIDI
import Foundation
import QuartzCore
import SwiftUI
import CrateboxKit

final class BridgeDeckState: ObservableObject {
    let deck: Int                       // rekordbox's deck, 0-3
    @Published var playing = false
    @Published var cueLit = false
    @Published var sync = false
    @Published var keylock = false
    @Published var quantize = false
    @Published var slip = false
    @Published var loopIn = false
    @Published var loopOut = false
    @Published var reloop = false
    @Published var autoLoop = false
    @Published var headphoneCue = false
    @Published var hot = [Bool](repeating: false, count: 8)
    // what the touch controls are at (rekordbox doesn't send faders back)
    @Published var tempo = 0.5
    @Published var trim = 0.5
    @Published var hi = 0.5
    @Published var mid = 0.5
    @Published var low = 0.5
    @Published var fader = 1.0
    @Published var filter = 0.5
    @Published var jogTouched = false
    var jogAngle = 0.0                  // drawn rotation of the platter
    init(deck: Int) { self.deck = deck }
    func lit(_ c: BridgeControl) -> Bool {
        switch c {
        case .playPause: return playing
        case .cue: return cueLit
        case .sync: return sync
        case .keylock: return keylock
        case .quantize: return quantize
        case .slip: return slip
        case .loopIn: return loopIn
        case .loopOut: return loopOut
        case .reloopExit: return reloop
        case .autoLoop: return autoLoop
        case .headphoneCue: return headphoneCue
        default: return false
        }
    }
    func set(_ c: BridgeControl, _ on: Bool) {
        switch c {
        case .playPause: playing = on
        case .cue: cueLit = on
        case .sync: sync = on
        case .keylock: keylock = on
        case .quantize: quantize = on
        case .slip: slip = on
        case .loopIn: loopIn = on
        case .loopOut: loopOut = on
        case .reloopExit: reloop = on
        case .autoLoop: autoLoop = on
        case .headphoneCue: headphoneCue = on
        default: break
        }
    }
}

final class DeckBridge: ObservableObject {
    // ---- which rekordbox decks the two sides drive ----
    @Published var pair: Int = UserDefaults.standard.object(forKey: "cb.bridge.pair") as? Int ?? 1 {       // 1 = decks 3/4, 0 = decks 1/2
        didSet { UserDefaults.standard.set(pair, forKey: "cb.bridge.pair"); sides = DeckBridge.makeSides(pair) }
    }
    @Published private(set) var sides: [BridgeDeckState]
    static func makeSides(_ pair: Int) -> [BridgeDeckState] { [BridgeDeckState(deck: pair * 2), BridgeDeckState(deck: pair * 2 + 1)] }
    @Published var shift = false
    @Published var xfader = 0.5
    @Published var fxDepth = 0.5
    @Published var fxOn = false
    @Published var fxAssign = [false, false, false, false]
    @Published var invertTempo = UserDefaults.standard.bool(forKey: "cb.bridge.invertTempo") { didSet { UserDefaults.standard.set(invertTempo, forKey: "cb.bridge.invertTempo") } }
    @Published var jogSensitivity = UserDefaults.standard.object(forKey: "cb.bridge.jogSens") as? Double ?? 1.0 { didSet { UserDefaults.standard.set(jogSensitivity, forKey: "cb.bridge.jogSens") } }

    // ---- transport ----
    @Published var networkOn = UserDefaults.standard.object(forKey: "cb.bridge.net") as? Bool ?? true { didSet { UserDefaults.standard.set(networkOn, forKey: "cb.bridge.net"); applyNetwork() } }
    @Published private(set) var peers: [String] = []              // network session connections
    @Published private(set) var destinations: [String] = []       // where messages go
    @Published private(set) var lastHeard = 0.0                   // host time of the last message from rekordbox
    @Published private(set) var sentCount = 0
    @Published var status = ""
    var heardRecently: Bool { lastHeard > 0 && hostSeconds() - lastHeard < 30 }
    var linked: Bool { !destinations.isEmpty }

    private var client = MIDIClientRef(), inPort = MIDIPortRef(), outPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var started = false
    private var dests: [MIDIEndpointRef] = []

    init() { sides = DeckBridge.makeSides(UserDefaults.standard.object(forKey: "cb.bridge.pair") as? Int ?? 1) }

    func setActive(_ on: Bool) {
        if on { start() }
        // the network session stays up while the app runs (rekordbox keeps its connection); nothing to stop
    }

    func start() {
        guard !started else { refresh(); return }
        started = true
        MIDIClientCreateWithBlock("Cratebox Deck Bridge" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged || note.pointee.messageID == .msgObjectAdded || note.pointee.messageID == .msgObjectRemoved {
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "bridge in" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            let msgs = MIDIHost.decode(list)
            if msgs.isEmpty { return }
            DispatchQueue.main.async { for m in msgs { self?.heard(m) } }
        }
        MIDIOutputPortCreate(client, "bridge out" as CFString, &outPort)
        // a source other apps on this device can listen to (and that a USB-connected Mac sees through IDAM)
        MIDISourceCreateWithProtocol(client, "Cratebox Deck Bridge" as CFString, ._1_0, &virtualSource)
        NotificationCenter.default.addObserver(forName: Notification.Name(MIDINetworkNotificationSessionDidChange), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: Notification.Name(MIDINetworkNotificationContactsDidChange), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        applyNetwork()
        refresh()
    }

    func applyNetwork() {
        let s = MIDINetworkSession.default()
        s.isEnabled = networkOn
        s.connectionPolicy = networkOn ? .anyone : .noOne
        refresh()
    }

    /// what's out there: the network session's endpoints, a Mac over USB, Bluetooth MIDI peers
    func refresh() {
        guard started else { return }
        let s = MIDINetworkSession.default()
        peers = s.connections().map { $0.host.name }
        var ds = [MIDIEndpointRef](), names = [String]()
        let netDest = s.isEnabled ? s.destinationEndpoint() : 0
        if netDest != 0 && !peers.isEmpty { ds.append(netDest); names.append("Network: " + peers.joined(separator: ", ")) }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i)
            if d == netDest { continue }
            let n = MIDIHost.name(d)
            // a Mac over the USB cable (IDAM), or a Bluetooth MIDI connection; not the controller Performance Mode uses
            if n.range(of: "IDAM|Bluetooth|MIDI Host|rekordbox", options: [.regularExpression, .caseInsensitive]) != nil { ds.append(d); names.append(n) }
        }
        dests = ds; destinations = names
        // listen to the same places
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i), n = MIDIHost.name(src)
            if (s.isEnabled && src == s.sourceEndpoint()) || n.range(of: "IDAM|Bluetooth|MIDI Host|rekordbox", options: [.regularExpression, .caseInsensitive]) != nil {
                MIDIPortConnectSource(inPort, src, nil)
            }
        }
        status = linked ? "Linked: \(names.joined(separator: " · "))" : networkOn ? "Waiting for rekordbox's computer to connect (\(s.networkName.isEmpty ? "this phone" : s.networkName))" : "Not linked"
    }

    // ---- out ----
    func send(_ ms: [BridgeMessage]) {
        guard started else { return }
        for m in ms {
            var list = MIDIPacketList()
            let p = MIDIPacketListInit(&list)
            _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, p, 0, m.bytes.count, m.bytes)
            for d in dests { MIDISend(outPort, d, &list) }
            if virtualSource != 0 { MIDIReceived(virtualSource, &list) }
        }
        sentCount += ms.count
    }
    func button(_ c: BridgeControl, side: Int, on: Bool) { send(DeckBridgeMap.button(c, deck: sides[side].deck, on: on)) }
    func global(_ c: BridgeControl, on: Bool) { send(DeckBridgeMap.button(c, deck: 0, on: on)) }
    func hotCue(_ k: Int, side: Int, on: Bool) { send(DeckBridgeMap.hotCue(k, deck: sides[side].deck, on: on, shift: shift)) }
    func value(_ c: BridgeControl, side: Int, _ v: Double) {
        let d = sides[side]
        switch c {
        case .tempo: d.tempo = v
        case .trim: d.trim = v
        case .eqHigh: d.hi = v
        case .eqMid: d.mid = v
        case .eqLow: d.low = v
        case .channelFader: d.fader = v
        case .filter: d.filter = v
        default: break
        }
        send(DeckBridgeMap.value(c, deck: d.deck, c == .tempo && invertTempo ? 1 - v : v))
    }
    func setXfader(_ v: Double) { xfader = v; send(DeckBridgeMap.value(.crossfader, deck: 0, v)) }
    func setFxDepth(_ v: Double) { fxDepth = v; send(DeckBridgeMap.value(.fxDepth, deck: 0, v)) }
    func toggleFxAssign(side: Int) {
        let d = sides[side].deck
        fxAssign[d].toggle()
        send(DeckBridgeMap.button(.fxAssign, deck: d, on: true)); send(DeckBridgeMap.button(.fxAssign, deck: d, on: false))
    }
    // jog: turns in degrees → relative ticks (about 2 per degree at 1×, like a hardware platter)
    private var jogRemainder = [0.0, 0.0]
    func jog(side: Int, degrees: Double, edge: Bool) {
        let d = sides[side]
        d.jogAngle += degrees
        let ticks = degrees * 2 * jogSensitivity + jogRemainder[side]
        let whole = Int(ticks.rounded(.towardZero))
        jogRemainder[side] = ticks - Double(whole)
        if whole != 0 { send(DeckBridgeMap.relative(edge ? .jogBend : .jogScratch, deck: d.deck, ticks: whole)) }
        d.objectWillChange.send()
    }
    func jogTouch(side: Int, _ on: Bool) {
        sides[side].jogTouched = on
        jogRemainder[side] = 0
        button(.jogTouch, side: side, on: on)
    }
    func browse(_ ticks: Int) { send(DeckBridgeMap.relative(.browse, deck: 0, ticks: ticks)) }
    func load(side: Int) { button(.load, side: side, on: true); button(.load, side: side, on: false) }

    // ---- in: rekordbox's lights ----
    private func heard(_ m: [UInt8]) {
        lastHeard = hostSeconds()
        guard let f = DeckBridgeMap.feedback(m) else { return }
        switch f {
        case .button(let c, let deck, let on): sides.first { $0.deck == deck }?.set(c, on)
        case .hotCue(let k, let deck, let on): if let s = sides.first(where: { $0.deck == deck }) { s.hot[k] = on }
        case .fx(_, let on): fxOn = on
        }
    }

    // ---- the mapping file, for rekordbox's MIDI → IMPORT ----
    static var folder: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Deck Bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func writeMapping() -> URL? {
        let u = DeckBridge.folder.appendingPathComponent("Cratebox Deck Bridge.midi.csv")
        do { try DeckBridgeMap.rekordboxCSV().write(to: u, atomically: true, encoding: .utf8); return u } catch { status = "Couldn't write the mapping file: \(error.localizedDescription)"; return nil }
    }
}
