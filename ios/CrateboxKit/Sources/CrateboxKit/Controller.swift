// Controllers: Pioneer DJ / AlphaTheta profiles, the table-driven MIDI engine, LEDs, deck layers with soft
// takeover, MIDI learn. A port of the web app's controller code (cratebox.html, "Controllers"): same
// mappings (the FLX4 one checked on the hardware, the rest from Mixxx's community mappings), same actions.
import Foundation

/// [status, data1, action, deck (-1 = global), lsb data1 for 14-bit controls (0 = none)]
public struct MapEntry: Codable, Hashable {
    public var status: Int, data1: Int, action: String, deck: Int, lsb: Int
    public init(_ s: Int, _ d: Int, _ a: String, _ deck: Int, _ lsb: Int) { status = s; data1 = d; action = a; self.deck = deck; self.lsb = lsb }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        status = try c.decode(Int.self); data1 = try c.decode(Int.self); action = try c.decode(String.self); deck = try c.decode(Int.self); lsb = try c.decode(Int.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer(); try c.encode(status); try c.encode(data1); try c.encode(action); try c.encode(deck); try c.encode(lsb)
    }
}

public struct ControllerProfile {
    public enum Source: String { case tested, mixxx, family, learn }
    public let id: String, name: String
    let match: NSRegularExpression?
    public let src: Source
    let makeMap: () -> [MapEntry]
    public let keepAlive: [UInt8]?, initMsg: [UInt8]?
    public let vu: Bool, leds: Bool
    public var map: [MapEntry] { makeMap() }
    func matches(_ s: String) -> Bool { match?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
}

public enum Profiles {
    static let mixxx: [String: [MapEntry]] = {
        guard let url = Bundle.module.url(forResource: "Resources/mixxx_maps", withExtension: "json"),
              let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: [MapEntry]].self, from: d) else { return [:] }
        return m
    }()
    /// The rekordbox-era DDJ layout (DDJ-400, FLX2/4/6/10, 800, 1000...), written out from the FLX4.
    public static func ddjRekordboxMap(_ deckChs: [Int] = [0, 1], _ padChs: [[Int]] = [[0x97, 0x98], [0x99, 0x9a]]) -> [MapEntry] {
        var m = [MapEntry]()
        for (k, ch) in deckChs.enumerated() {
            let d = k % 2, n = 0x90 + ch, c = 0xb0 + ch
            let notes: [(Int, String)] = [(0x0b, "play"), (0x0e, "playCue"), (0x0c, "cue"), (0x48, "start"), (0x58, "sync"), (0x5c, "syncOn"),
                (0x60, "range"), (0x36, "touch"), (0x67, "touch"), (0x10, "loopIn"), (0x11, "loopOut"), (0x4d, "reloop"),
                (0x50, "reloopStop"), (0x4c, "loopHalf"), (0x4e, "loopDouble"), (0x51, "callPrev"), (0x53, "callNext"),
                (0x3e, "jump:-4"), (0x3d, "jump:4"), (0x54, "pfl"), (0x68, "quant"), (0x3f, "ignore"),
                (0x1b, "mode:hotcue"), (0x6d, "mode:beatloop"), (0x20, "mode:beatjump"), (0x1e, "mode:padfx"),
                (0x6b, "mode:padfx2"), (0x22, "mode:sampler"), (0x69, "mode:keyboard"), (0x6f, "mode:keyshift")]
            for (no, a) in notes { m.append(MapEntry(n, no, a, d, 0)) }
            for (no, a) in [(0x22, "jogTop"), (0x23, "jogTop"), (0x21, "jogSide"), (0x29, "jogSearch"), (0x02, "ignore")] { m.append(MapEntry(c, no, a, d, 0)) }
            for (no, a) in [(0x00, "tempo"), (0x13, "fader"), (0x04, "trim"), (0x07, "hi"), (0x0b, "mid"), (0x0f, "low")] { m.append(MapEntry(c, no, a, d, no + 0x20)) }
        }
        for (k, pc) in padChs.enumerated() {
            let d = k % 2, pn = pc[0], ps = pc[1]
            for p in 0..<8 {
                m.append(MapEntry(pn, p, "hot:\(p)", d, 0)); m.append(MapEntry(ps, p, "hotClear:\(p)", d, 0))
                m.append(MapEntry(pn, 0x60 + p, "loop:\(LOOP_SIZES[p])", d, 0)); m.append(MapEntry(ps, 0x60 + p, "loop:\(LOOP_SIZES[p])", d, 0))
                m.append(MapEntry(pn, 0x20 + p, "jump:\(JUMPS[p])", d, 0))
                m.append(MapEntry(pn, 0x10 + p, "pfx:\(p)", d, 0)); m.append(MapEntry(ps, 0x10 + p, "pfx:\(p)", d, 0))
                m.append(MapEntry(pn, 0x50 + p, "pfx2:\(p)", d, 0)); m.append(MapEntry(ps, 0x50 + p, "pfx2:\(p)", d, 0))
            }
        }
        // LOAD 1 / 2, and with SHIFT (0x48 / 0x49): straight onto decks 3 / 4
        m += [MapEntry(0x96, 0x46, "load", 0, 0), MapEntry(0x96, 0x47, "load", 1, 0), MapEntry(0x96, 0x48, "loadShift", 0, 0), MapEntry(0x96, 0x49, "loadShift", 1, 0),
              MapEntry(0x96, 0x41, "browsePress", -1, 0), MapEntry(0x96, 0x42, "browseShift", -1, 0),
              MapEntry(0xb6, 0x40, "browse", -1, 0), MapEntry(0xb6, 0x64, "zoom", -1, 0),
              MapEntry(0xb6, 0x1f, "xfader", -1, 0x3f), MapEntry(0xb6, 0x17, "cfx", 0, 0x37), MapEntry(0xb6, 0x18, "cfx", 1, 0x38), MapEntry(0xb6, 0x0c, "headMix", -1, 0x2c),
              MapEntry(0x94, 0x63, "fxSelect", -1, 0), MapEntry(0x94, 0x64, "fxSelectPrev", -1, 0), MapEntry(0x94, 0x4a, "fxBeatDown", -1, 0), MapEntry(0x94, 0x4b, "fxBeatUp", -1, 0),
              MapEntry(0x94, 0x10, "fxCh:0", -1, 0), MapEntry(0x95, 0x11, "fxCh:1", -1, 0), MapEntry(0x94, 0x47, "fxOn", -1, 0), MapEntry(0x95, 0x47, "fxOn", -1, 0),
              MapEntry(0x94, 0x43, "fxOff", -1, 0), MapEntry(0x95, 0x43, "fxOff", -1, 0), MapEntry(0xb4, 0x02, "fxDepth", -1, 0x22)]
        for st in [0x94, 0x95] { for no in 0..<128 { m.append(MapEntry(st, no, "unsupported:Beat FX", -1, 0)) } }
        return m
    }
    /// Mixxx maps only cover channels 1-2 for some units: copy them onto 3-4 for four-deck hardware
    static func withDecks34(_ map: [MapEntry]) -> [MapEntry] {
        var out = map
        let have = Set(map.map { $0.status * 256 + $0.data1 })
        for e in map {
            let t = e.status & 0xf0, ch = e.status & 0x0f
            if (t == 0x90 || t == 0xb0) && ch <= 1 {
                let st = e.status + 2
                if !have.contains(st * 256 + e.data1) { out.append(MapEntry(st, e.data1, e.action, e.deck, e.lsb)) }
            }
        }
        return out
    }
    public static let FLX4_KEEPALIVE: [UInt8] = [0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x04, 0x05, 0x00, 0x50, 0x02, 0xf7]
    static func re(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static func mx(_ k: String) -> [MapEntry] { mixxx[k] ?? [] }
    public static let all: [ControllerProfile] = [
        ControllerProfile(id: "ddj-flx4", name: "Pioneer DDJ-FLX4", match: re("FLX-?4"), src: .tested, makeMap: { ddjRekordboxMap() }, keepAlive: FLX4_KEEPALIVE, initMsg: nil, vu: true, leds: true),
        ControllerProfile(id: "ddj-400", name: "Pioneer DDJ-400", match: re("DDJ-?400"), src: .mixxx, makeMap: { mx("ddj-400") + ddjRekordboxMap() }, keepAlive: nil,
                          initMsg: [0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x02, 0x06, 0x00, 0x03, 0x01, 0xf7], vu: true, leds: true),
        ControllerProfile(id: "ddj-200", name: "Pioneer DDJ-200", match: re("DDJ-?200"), src: .mixxx, makeMap: { mx("ddj-200") }, keepAlive: nil,
                          initMsg: [0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x02, 0x0a, 0x00, 0x03, 0x01, 0xf7], vu: false, leds: true),
        ControllerProfile(id: "ddj-sb3", name: "Pioneer DDJ-SB3", match: re("DDJ-?SB3"), src: .mixxx, makeMap: { mx("ddj-sb3") }, keepAlive: nil, initMsg: [0xf0, 0x00, 0x20, 0x7f, 0x03, 0x01, 0xf7], vu: false, leds: true),
        ControllerProfile(id: "ddj-sb2", name: "Pioneer DDJ-SB2", match: re("DDJ-?SB2"), src: .mixxx, makeMap: { mx("ddj-sb2") }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
        ControllerProfile(id: "ddj-sb", name: "Pioneer DDJ-SB", match: re("DDJ-?SB\\b"), src: .mixxx, makeMap: { withDecks34(mx("ddj-sb")) }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
        ControllerProfile(id: "ddj-sx2", name: "Pioneer DDJ-SX2 / SX3", match: re("DDJ-?SX[23]"), src: .mixxx, makeMap: { mx("ddj-sx2") }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
        ControllerProfile(id: "ddj-sx", name: "Pioneer DDJ-SX", match: re("DDJ-?SX\\b"), src: .mixxx, makeMap: { mx("ddj-sx") }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
        ControllerProfile(id: "xdj-rx", name: "Pioneer XDJ-RX", match: re("XDJ-?RX\\b(?!2|3)"), src: .mixxx, makeMap: { mx("xdj-rx") }, keepAlive: nil, initMsg: nil, vu: false, leds: false),
        ControllerProfile(id: "cdj-2000", name: "Pioneer CDJ-2000 / NXS / NXS2 (MIDI mode)", match: re("CDJ-?2000"), src: .mixxx, makeMap: { withDecks34(mx("cdj-2000")) }, keepAlive: nil, initMsg: nil, vu: false, leds: false),
        ControllerProfile(id: "cdj-850", name: "Pioneer CDJ-850 / 900 (MIDI mode)", match: re("CDJ-?(850|900)"), src: .mixxx, makeMap: { withDecks34(mx("cdj-850")) }, keepAlive: nil, initMsg: nil, vu: false, leds: false),
        ControllerProfile(id: "cdj-350", name: "Pioneer CDJ-350 (MIDI mode)", match: re("CDJ-?350"), src: .mixxx, makeMap: { withDecks34(mx("cdj-350")) }, keepAlive: nil, initMsg: nil, vu: false, leds: false),
        ControllerProfile(id: "ddj-rekordbox", name: "Pioneer DDJ / XDJ, rekordbox series (FLX2, FLX6, FLX10, 800, 1000, GRV6, RB, RR, RX, RZ...)", match: re("DDJ|FLX|XDJ|OPUS|GRV|AlphaTheta"), src: .family,
                          makeMap: { ddjRekordboxMap([0, 1, 2, 3], [[0x97, 0x98], [0x99, 0x9a], [0x9b, 0x9c], [0x9d, 0x9e]]) }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
        ControllerProfile(id: "ddj-serato", name: "Pioneer DDJ, Serato series (SR, SR2, SZ, SZ2, REV1/5/7, 1000SRT, XP)", match: re("DDJ-?(SR|SZ|REV|XP|1000SRT)"), src: .family, makeMap: { mx("ddj-sx") }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
        ControllerProfile(id: "cdj", name: "Pioneer CDJ / XDJ player (MIDI mode)", match: re("CDJ|XDJ-?(1000|700)"), src: .family, makeMap: { withDecks34(mx("cdj-2000")) }, keepAlive: nil, initMsg: nil, vu: false, leds: false),
        ControllerProfile(id: "learn", name: "Other controller (map it with MIDI learn)", match: nil, src: .learn, makeMap: { [] }, keepAlive: nil, initMsg: nil, vu: false, leds: true),
    ]
    public static let srcNote: [ControllerProfile.Source: String] = [
        .tested: "Mapping checked on the hardware.",
        .mixxx: "Mapping from Mixxx's community mapping for this model. Not tested here: if a control is wrong, fix it with Learn.",
        .family: "This model uses the shared Pioneer layout for its product line. The main controls should work; fix anything wrong with Learn.",
        .learn: "No built-in mapping: use Learn to assign controls.",
    ]
    public static let pioneerish = re("DDJ|FLX|CDJ|XDJ|DJM|OPUS|GRV|Pioneer|AlphaTheta")!
    public static func profile(for port: String) -> ControllerProfile {
        all.first { $0.src != .family && $0.src != .learn && $0.matches(port) }
            ?? all.filter { $0.src == .family }.reversed().first { $0.matches(port) }
            ?? all.first { $0.id == "learn" }!
    }
    public static func byId(_ id: String) -> ControllerProfile? { all.first { $0.id == id } }
}

/// What the controller drives (the app's Core plus the library and screen).
public protocol ControlTarget: AnyObject {
    var fourDecks: Bool { get }
    /// 2, 3 or 4 (3: the right side stays on deck 2)
    var deckCount: Int { get }
    func absValue(_ name: String, deck: Int) -> Double?
    func setAbs(_ name: String, deck: Int, _ v: Double)
    func press(_ name: String, arg: String, deck: Int, on: Bool)
    func relative(_ name: String, deck: Int, ticks: Int)
    /// LED state for an action (nil = leave it)
    func led(_ name: String, arg: String, deck: Int, blink: Bool) -> Int?
    func vu(deck: Int) -> Double
    func controllerStatus(_ s: String)
}

public extension ControlTarget { var deckCount: Int { fourDecks ? 4 : 2 } }

let ABS_ACTIONS: Set<String> = ["tempo", "fader", "trim", "hi", "mid", "low", "cfx", "xfader", "headMix", "master", "fxDepth", "micVol"]
let REL_ACTIONS: Set<String> = ["jogTop", "jogSide", "jogSearch", "browse", "zoom"]
let LED_RE = try! NSRegularExpression(pattern: "^(play|cue|sync|pfl|loopIn|loopOut|reloop|keylock|quant|mode:|hot:|loop:|pfx:|pfx2:|fxOn|layer)")
let PICKUP = ["tempo", "fader", "trim", "hi", "mid", "low", "cfx"]
public let LEARN_LABEL: [String: String] = ["play": "Play", "cue": "Cue", "sync": "Sync", "loopIn": "Loop in", "loopOut": "Loop out", "reloop": "Reloop/exit",
    "tempo": "Tempo fader", "jog": "Jog wheel", "pfl": "Headphone cue", "masterCue": "Master cue", "fxOn": "Beat FX on/off", "fxSelect": "Beat FX select",
    "fxBeatDown": "Beat FX beat ◀", "fxBeatUp": "Beat FX beat ▶", "fxDepth": "Beat FX level/depth", "fader": "Channel fader", "trim": "Trim", "hi": "EQ high",
    "mid": "EQ mid", "low": "EQ low", "cfx": "Filter (CFX)", "xfader": "Crossfader", "headMix": "Cue/master mix", "master": "Master level",
    "browse": "Browse knob", "browsePress": "Browse knob press", "load": "Load", "loadShift": "Load on deck 3 / 4", "keylock": "Master tempo", "quant": "Quantize", "jogSide": "Jog side (nudge)", "layer": "Deck layer (1⇄3 / 2⇄4)", "micVol": "Watch mic volume"]

public final class MIDIEngine {
    public weak var target: ControlTarget?
    public private(set) var profile: ControllerProfile?
    public private(set) var learned: [MapEntry] = []
    var table = [Int: MapEntry](), lsbTable = [Int: MapEntry](), msb = [MapEntry: Int]()
    /// whether the current mapping has a control for this action (the FLX4 has no MASTER LEVEL message)
    public func hasAction(_ a: String) -> Bool { table.values.contains { $0.action == a } }
    var ledEntries = [MapEntry]()
    var ledCache = [Int: Int]()
    /// which deck each side of the controller plays (deck layers, 4-deck mode)
    public private(set) var side = [0, 1]
    var pickup = [String: Double?]()
    var fxLever = [Int: Bool]()
    /// sends bytes to the controller
    public var send: ([UInt8]) -> Void = { _ in }
    public var loadLearned: (String) -> [MapEntry] = { _ in [] }
    public var saveLearned: (String, [MapEntry]) -> Void = { _, _ in }
    public var onSide: (() -> Void)?
    public var onFxLever: ((Int?) -> Void)?
    /// learn: the on-screen control waiting for a controller message
    public struct LearnTarget { public var action: String; public var deck: Int; var touch: MapEntry?; var turn: MapEntry? }
    public var learning: LearnTarget?
    public var learnMode = false
    public var learnHint: (String) -> Void = { _ in }
    public var capture: ((Int, Int) -> Void)?

    public init() {}
    static func key(_ st: Int, _ d1: Int) -> Int { (((st & 0xf0) == 0x80 ? 0x90 | (st & 0x0f) : st) << 8) | d1 }

    @discardableResult public func use(_ p: ControllerProfile) -> ControllerProfile {
        profile = p
        learned = loadLearned(p.id)
        table.removeAll(); lsbTable.removeAll(); msb.removeAll(); ledCache.removeAll()
        // learned entries win; earlier entries in a profile win over later ones
        for e in learned + p.map {
            let k = MIDIEngine.key(e.status, e.data1)
            if table[k] == nil { table[k] = e }
            if e.lsb != 0 { let lk = MIDIEngine.key(e.status, e.lsb); if lsbTable[lk] == nil { lsbTable[lk] = e } }
        }
        ledEntries = !p.leds && learned.isEmpty ? [] : table.values.filter { ($0.status & 0xf0) == 0x90 && LED_RE.firstMatch(in: $0.action, range: NSRange($0.action.startIndex..., in: $0.action)) != nil }
        return p
    }
    /// the controller just connected: wake it up
    public func connected() {
        if let i = profile?.initMsg { send(i) }
        if let k = profile?.keepAlive { send(k) }
    }
    /// the FLX4 drops into demo-light mode unless the software checks in every so often (call every 200 ms)
    public func keepAliveTick() { if let k = profile?.keepAlive { send(k) } }

    public func receive(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        let st = Int(data[0]), d1 = Int(data[1]), d2 = data.count > 2 ? Int(data[2]) : 0
        let type = st & 0xf0
        if type != 0x90 && type != 0x80 && type != 0xb0 { return }
        if let c = capture, type == 0x90 && d2 > 0 { c(st, d1); return }
        if learnMode { learnCapture(st, d1, d2); return }
        let k = MIDIEngine.key(st, d1)
        if let e = table[k] { run(e, type, d2, false); return }
        if let l = lsbTable[k], type == 0xb0 { run(l, type, d2, true) }
    }

    func hwDeck(_ d: Int) -> Int { (target?.fourDecks ?? false) && (d == 0 || d == 1) ? side[d] : d }

    func run(_ e: MapEntry, _ type: Int, _ v: Int, _ isLsb: Bool) {
        guard let t = target else { return }
        let a = e.action
        let name: String, arg: String
        if let c = a.firstIndex(of: ":") { name = String(a[..<c]); arg = String(a[a.index(after: c)...]) } else { name = a; arg = "" }
        // layer buttons name a side; SHIFT+LOAD names deck 3 / 4 whatever the layers are on
        let deck = name == "layer" ? e.deck : name == "loadShift" ? e.deck + 2 : hwDeck(e.deck)
        if type == 0xb0 && ABS_ACTIONS.contains(name) {
            let val: Double
            if e.lsb == 0 { val = Double(v) / 127 }
            else if !isLsb { msb[e] = v; val = Double(v) / 127 }      // apply the MSB straight away, refine on the LSB
            else { val = Double(((msb[e] ?? 0) << 7) | v) / 16383 }
            if !pickedUp(name, deck, val) { return }
            t.setAbs(name, deck: deck, val); return
        }
        if REL_ACTIONS.contains(name) {
            if type != 0xb0 { return }
            let ticks = name.hasPrefix("jog") ? v - 64 : (v < 64 ? v : v - 128)   // jogs: centre 64; knobs: 1 / 127
            t.relative(name, deck: deck, ticks: ticks); return
        }
        let on = type == 0x90 ? v > 0 : type == 0x80 ? false : v > 63
        switch name {
        case "layer": if on && t.fourDecks { toggleSide(deck) }
        // the FLX4's CH SELECT lever: CH1 / CH2 send 7F while there, 00 when it leaves; neither = MASTER
        case "fxCh":
            fxLever[Int(arg) ?? 0] = on
            onFxLever?(fxLever[0] == true ? hwDeck(0) : fxLever[1] == true ? hwDeck(1) : nil)
        default: t.press(name, arg: arg, deck: deck, on: on)
        }
    }

    // ---- deck layers and soft takeover ----
    func pickedUp(_ name: String, _ deck: Int, _ val: Double) -> Bool {
        let k = "\(name)/\(deck)"
        guard let p = pickup[k] else { return true }
        let cur = target?.absValue(name, deck: deck)
        // close enough, or the hardware moved across the deck's setting since the last message
        if cur == nil || abs(val - cur!) < 0.02 || (p != nil && (p! - cur!) * (val - cur!) <= 0) { pickup[k] = nil; return true }
        pickup[k] = .some(val)
        return false
    }
    public func setSide(_ s: Int, _ deck: Int) {
        if deck == side[s] || deck >= (target?.deckCount ?? 2) { return }
        target?.press("touch", arg: "", deck: side[s], on: false)          // let go of the platter on the deck being left
        side[s] = deck
        for n in PICKUP { pickup["\(n)/\(deck)"] = .some(nil) }
        if fxLever[s] == true { onFxLever?(deck) }
        onSide?()
        if profile != nil { target?.controllerStatus("Controller \(s == 1 ? "right" : "left") side: deck \(deck + 1). Faders and knobs take over once they reach deck \(deck + 1)'s settings.") }
    }
    public func toggleSide(_ s: Int) { setSide(s, side[s] == s ? s + 2 : s) }
    public func resetSides() { side = [0, 1]; onSide?() }

    // ---- LEDs: Pioneer hardware lights a button when it receives its own note back ----
    public func updateLeds(blink: Bool) {
        guard let t = target else { return }
        func led(_ st: Int, _ no: Int, _ v: Int) {
            let k = st * 256 + no
            if ledCache[k] == v { return }
            ledCache[k] = v
            send([UInt8(st), UInt8(no), UInt8(v)])
        }
        for e in ledEntries {
            let a = e.action
            if a == "fxOn" { if let v = t.led("fxOn", arg: "", deck: -1, blink: blink) { led(e.status, e.data1, v) }; continue }
            // a layer button's light stays off: on the FLX4, SMART CFX's and SMART FADER's lights switch the
            // controller's own Smart CFX / Smart Fader on, which then moves the EQ and BEAT FX by itself
            if a == "layer" { led(e.status, e.data1, 0); continue }
            if e.deck < 0 { continue }
            let name: String, arg: String
            if let c = a.firstIndex(of: ":") { name = String(a[..<c]); arg = String(a[a.index(after: c)...]) } else { name = a; arg = "" }
            if let v = t.led(name, arg: arg, deck: hwDeck(e.deck), blink: blink) { led(e.status, e.data1, v) }
        }
        if profile?.vu == true { for i in [0, 1] { led(0xb0 + i, 0x02, Int(jsRound(t.vu(deck: hwDeck(i)) * 127))) } }
    }

    // ---- MIDI learn ----
    public func startLearn() { if profile == nil { use(Profiles.byId("learn")!) }; learnMode = true; learning = nil; learnHint("Tap a control on screen, then move or press it on the controller.") }
    public func stopLearn() { learnMode = false; learning = nil }
    public func learnPick(action: String, deck: Int) {
        learning = LearnTarget(action: action, deck: deck)
        let who = (deck >= 0 ? "Deck \(deck + 1) " : "") + (LEARN_LABEL[action] ?? (action.hasPrefix("hot:") ? "Pad \((Int(action.dropFirst(4)) ?? 0) + 1)" : action))
        learnHint(action == "jog" ? "\(who): touch the top of the platter, then turn it." : "\(who): now move or press it on the controller.")
    }
    func learnCapture(_ st: Int, _ d1: Int, _ d2: Int) {
        guard var t = learning, let p = profile else { return }
        let type = st & 0xf0, s = type == 0x80 ? 0x90 | (st & 0x0f) : st
        if type == 0x80 || (type == 0x90 && d2 == 0) { return }
        var entries = [MapEntry]()
        if t.action == "jog" {
            if type == 0x90 { t.touch = MapEntry(s, d1, "touch", t.deck, 0) } else { t.turn = MapEntry(s, d1, "jogTop", t.deck, 0) }
            learning = t
            guard let a = t.touch, let b = t.turn else { learnHint(t.touch != nil ? "Got the touch. Now turn the platter." : "Got the turn. Now touch the top of the platter."); return }
            entries = [a, b]
        } else if ABS_ACTIONS.contains(t.action) {
            if type != 0xb0 { learnHint("That sent a button press. Move a knob or fader instead."); return }
            entries = [MapEntry(s, d1, t.action, t.deck, d1 < 0x20 ? d1 + 0x20 : 0)]      // Pioneer 14-bit pairs: fine part on CC + 32
        } else if t.action == "browse" {
            if type != 0xb0 { learnHint("Turn the knob rather than pressing it."); return }
            entries = [MapEntry(s, d1, "browse", -1, 0)]
        } else { entries = [MapEntry(s, d1, t.action, t.deck, 0)] }
        let keys = Set(entries.map { MIDIEngine.key($0.status, $0.data1) }), targets = Set(entries.map { "\($0.action)/\($0.deck)" })
        // one control does one thing: drop older learns on the same message or for the same on-screen control
        learned = learned.filter { !keys.contains(MIDIEngine.key($0.status, $0.data1)) && !targets.contains("\($0.action)/\($0.deck)") }
        learned += entries
        saveLearned(p.id, learned)
        use(p)
        learning = nil
        learnHint("Mapped \(entries.map { String(format: "%02X %02X", $0.status, $0.data1) }.joined(separator: " + ")). Tap the next control, or Done.")
    }
    public func clearLearned() { guard let p = profile else { return }; saveLearned(p.id, []); use(p) }
    /// SMART CFX / SMART FADER (or two spare buttons) as layer buttons: press each once
    public func setupLayerButtons(done: @escaping () -> Void) {
        guard let p = profile else { target?.controllerStatus("Connect the controller first"); return }
        let flx = p.id.lowercased().contains("flx")
        let steps: [(Int, String, String)] = [(0, flx ? "SMART CFX" : "a spare button for the left side", "1 and 3"), (1, flx ? "SMART FADER" : "a spare button for the right side", "2 and 4")]
        var k = 0
        let ask = { [weak self] (pre: String) in self?.target?.controllerStatus("\(pre)Press \(steps[k].1) on the controller: it will switch the \(k == 1 ? "right" : "left") side between decks \(steps[k].2).") }
        capture = { [weak self] st, d1 in
            guard let self else { return }
            if let have = self.table[MIDIEngine.key(st, d1)], have.action != "layer", !have.action.hasPrefix("unsupported") {
                ask("That button already does \"\(LEARN_LABEL[have.action] ?? have.action)\". "); return
            }
            let s = steps[k].0
            self.learned = self.learned.filter { !($0.status == st && $0.data1 == d1) && !($0.action == "layer" && $0.deck == s) }
            self.learned.append(MapEntry(st, d1, "layer", s, 0))
            self.saveLearned(p.id, self.learned)
            self.use(p)
            k += 1
            if k < steps.count { ask(""); return }
            self.capture = nil
            self.target?.controllerStatus("Done: \(steps[0].1) switches the left side 1 ⇄ 3, \(steps[1].1) the right side 2 ⇄ 4 (in 4-deck mode).")
            done()
        }
        ask("")
    }
    public var mappedCount: Int { learned.count }
}
