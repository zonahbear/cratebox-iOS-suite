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
    /// rekordbox's pad mode on this deck (as last chosen here), and its pads' lights per mode
    @Published var padBank: DeckBridgeMap.PadBank = .hotCue
    @Published var padLit = [[Bool]](repeating: [Bool](repeating: false, count: 8), count: 4)
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
        // rekordbox lights the pad mode it's in: follow it, so a mode picked on the computer reaches the pads here
        case .hotCueMode, .beatJumpMode, .padFx1Mode, .padFx2Mode:
            if on, let b = DeckBridgeMap.PadBank.allCases.first(where: { $0.mode == c }) { padBank = b }
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
    /// a computer is really there: iOS lists it, or rekordbox has sent something back lately
    var confirmed: Bool { !peers.isEmpty || heardRecently }

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
        // keep the copy in Files → Cratebox → Deck Bridge the same as this build's mapping (an older build's file
        // there lacks rows this build sends)
        _ = writeMapping()
        // incoming connections don't always post a notification: look again every few seconds
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
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
        // Always send into the network session while it's on. A connection the computer starts (rtpMIDI's
        // Connect) doesn't always show up in connections(), and sending with nobody connected is harmless.
        if netDest != 0 { ds.append(netDest); names.append(peers.isEmpty ? "Network session" : "Network: " + peers.joined(separator: ", ")) }
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
        status = !peers.isEmpty || heardRecently ? "Linked: \(names.joined(separator: " · "))"
            : networkOn ? "Sending on the network session \"\(s.networkName.isEmpty ? "this phone" : s.networkName)\". Connect to it from rtpMIDI / Audio MIDI Setup." : linked ? "Sending to \(names.joined(separator: " · "))" : "Not linked"
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
    /// a pad in the deck's current pad mode (SHIFT only does something for hot cues: delete)
    func pad(_ k: Int, side: Int, on: Bool) {
        let d = sides[side]
        send(DeckBridgeMap.pad(k, bank: d.padBank, deck: d.deck, on: on, shift: shift && d.padBank == .hotCue))
    }
    func setPadBank(_ b: DeckBridgeMap.PadBank, side: Int) {
        sides[side].padBank = b
        button(b.mode, side: side, on: true); button(b.mode, side: side, on: false)
    }
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
    // The platter. rekordbox takes no jog wheel from a generic MIDI device, so while it turns it holds down
    // rekordbox's search buttons (the top) or pitch bend buttons (the edge) in the direction it's turning, and
    // lets go when it stops. Quick flicks give short nudges, a steady turn a held search or bend.
    private var jogHeld: [BridgeControl?] = [nil, nil]
    private var jogRelease: [DispatchWorkItem?] = [nil, nil]
    func jog(side: Int, degrees: Double, edge: Bool) {
        let d = sides[side]
        d.jogAngle += degrees
        d.objectWillChange.send()
        guard abs(degrees) > 0.2 else { return }
        let want: BridgeControl = edge ? (degrees > 0 ? .bendUp : .bendDown) : (degrees > 0 ? .searchFwd : .searchRev)
        if jogHeld[side] != want {
            if let h = jogHeld[side] { button(h, side: side, on: false) }
            button(want, side: side, on: true)
            jogHeld[side] = want
        }
        // let go once the platter stops turning (sooner the more sensitive the setting)
        jogRelease[side]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.jogLetGo(side) }
        jogRelease[side] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 / max(0.5, jogSensitivity), execute: w)
    }
    func jogLetGo(_ side: Int) {
        jogRelease[side]?.cancel(); jogRelease[side] = nil
        if let h = jogHeld[side] { button(h, side: side, on: false); jogHeld[side] = nil }
    }
    func jogTouch(side: Int, _ on: Bool) {
        sides[side].jogTouched = on
        if !on { jogLetGo(side) }
    }
    func browse(_ ticks: Int) { send(DeckBridgeMap.relative(.browse, deck: 0, ticks: ticks)) }
    func load(side: Int) { button(.load, side: side, on: true); button(.load, side: side, on: false) }

    // ---- in: rekordbox's lights ----
    private func heard(_ m: [UInt8]) {
        lastHeard = hostSeconds()
        guard let f = DeckBridgeMap.feedback(m) else { return }
        switch f {
        case .button(let c, let deck, let on): sides.first { $0.deck == deck }?.set(c, on)
        case .hotCue(let k, let deck, let on): if let s = sides.first(where: { $0.deck == deck }) { s.hot[k] = on; s.padLit[0][k] = on }
        case .pad(let b, let k, let deck, let on): if let s = sides.first(where: { $0.deck == deck }) { s.padLit[b.rawValue][k] = on }
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
