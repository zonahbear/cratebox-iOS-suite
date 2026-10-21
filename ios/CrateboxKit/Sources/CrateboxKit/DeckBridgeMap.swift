// Deck Bridge: Cratebox as a touch MIDI controller for rekordbox. This is the message layout it sends and the
// rekordbox mapping file (MIDI → IMPORT) that matches it, so the only manual step in rekordbox is importing
// one file.
//
// The layout follows Pioneer's own 4-deck controllers (the DDJ-1000's numbers, as in rekordbox's
// MidiMappings files): each deck its own MIDI channel (deck 1 = channel 1 … deck 4 = channel 4), the pads on
// channels 8-11, the mixer's global controls and the browser on channel 7, Beat FX on channel 5. Faders and
// knobs are 14-bit (MSB on CC n, LSB on CC n+32). Jog wheels and the browse knob are relative: 64 = no move,
// above = clockwise. rekordbox lights the buttons back (PLAY, CUE, SYNC, loops, hot cue pads) on the same
// numbers, which Deck Bridge reads to light its own.
import Foundation

public enum BridgeControl: String, CaseIterable, Codable {
    // deck buttons (note on the deck's channel)
    case playPause, cue, sync, keylock, quantize, slip, loopIn, loopOut, reloopExit, autoLoop, loopHalf, loopDouble, headphoneCue, hotCueMode, jumpToStart
    case padFx1Mode, beatJumpMode, padFx2Mode
    // deck continuous (14-bit CC on the deck's channel)
    case tempo, trim, eqHigh, eqMid, eqLow, channelFader
    // jog (relative CC / touch note on the deck's channel)
    case jogScratch, jogBend, jogTouch
    // per channel, on the global channel
    case filter, fxAssign, load
    // global
    case crossfader, browse, back, fxDepth, fxOn, fxSelect, fxBeatDown, fxBeatUp, filterSelect
}

public struct BridgeMessage: Equatable { public let bytes: [UInt8] }

public enum DeckBridgeMap {
    static let deckNote: [BridgeControl: UInt8] = [
        .playPause: 0x0B, .cue: 0x0C, .sync: 0x58, .keylock: 0x1A, .quantize: 0x35, .slip: 0x40, .loopIn: 0x10, .loopOut: 0x11,
        .reloopExit: 0x4D, .autoLoop: 0x14, .loopHalf: 0x12, .loopDouble: 0x13, .headphoneCue: 0x54, .hotCueMode: 0x1B, .jumpToStart: 0x48,
        .padFx1Mode: 0x1E, .beatJumpMode: 0x20, .padFx2Mode: 0x6B,
    ]
    static let deckCC: [BridgeControl: UInt8] = [.tempo: 0x00, .trim: 0x04, .eqHigh: 0x07, .eqMid: 0x0B, .eqLow: 0x0F, .channelFader: 0x13]
    static let jogCC: [BridgeControl: UInt8] = [.jogScratch: 0x22, .jogBend: 0x23]
    static let jogTouchNote: UInt8 = 0x36
    static let padChannel0: UInt8 = 7            // deck 1's pads on channel 8 (status 0x97)
    static let globalChannel: UInt8 = 6          // channel 7
    static let fxChannel: UInt8 = 4              // channel 5

    public static func clamp14(_ v: Double) -> Int { max(0, min(16383, Int((v * 16383).rounded()))) }

    /// a press (on) or release (off) of a deck button; deck 0-3
    public static func button(_ c: BridgeControl, deck: Int, on: Bool) -> [BridgeMessage] {
        let v: UInt8 = on ? 0x7f : 0x00, d = UInt8(deck & 3)
        if let n = deckNote[c] { return [BridgeMessage(bytes: [0x90 | d, n, v])] }
        switch c {
        case .jogTouch: return [BridgeMessage(bytes: [0x90 | d, jogTouchNote, v])]
        case .fxAssign: return [BridgeMessage(bytes: [0x90 | fxChannel, 0x10 + d, v])]
        case .load: return [BridgeMessage(bytes: [0x90 | globalChannel, 0x46 + d, v])]
        case .back: return [BridgeMessage(bytes: [0x90 | globalChannel, 0x65, v])]
        case .fxOn: return [BridgeMessage(bytes: [0x90 | fxChannel, 0x47, v])]
        case .fxSelect: return [BridgeMessage(bytes: [0x90 | fxChannel, 0x63, v])]
        case .fxBeatDown: return [BridgeMessage(bytes: [0x90 | fxChannel, 0x4A, v])]
        case .fxBeatUp: return [BridgeMessage(bytes: [0x90 | fxChannel, 0x4B, v])]
        case .filterSelect: return [BridgeMessage(bytes: [0x90 | globalChannel, 0x03, v])]
        default: return []
        }
    }
    /// rekordbox's pad modes, in the order Deck Bridge shows them; each mode's pads are 8 notes from its base
    /// (Pioneer's layout: hot cue 0x00, Pad FX 1 0x10, beat jump 0x20, Pad FX 2 0x30; +8 with SHIFT)
    public enum PadBank: Int, CaseIterable { case hotCue = 0, beatJump, padFx1, padFx2
        public var base: UInt8 { [0x00, 0x20, 0x10, 0x30][rawValue] }
        public var mode: BridgeControl { [.hotCueMode, .beatJumpMode, .padFx1Mode, .padFx2Mode][rawValue] }
        public var title: String { ["CUES", "JUMP", "FX1", "FX2"][rawValue] }
    }
    /// pad k (0-7) in a pad mode; shift = the pad's SHIFT function (deletes a hot cue)
    public static func pad(_ k: Int, bank: PadBank, deck: Int, on: Bool, shift: Bool = false) -> [BridgeMessage] {
        [BridgeMessage(bytes: [0x90 | (padChannel0 + UInt8(deck & 3)), bank.base + UInt8((shift ? 0x08 : 0x00) + (k & 7)), on ? 0x7f : 0x00])]
    }
    /// hot cue pad k (0-7); shift = delete
    public static func hotCue(_ k: Int, deck: Int, on: Bool, shift: Bool = false) -> [BridgeMessage] { pad(k, bank: .hotCue, deck: deck, on: on, shift: shift) }
    /// a fader or knob, 0…1
    public static func value(_ c: BridgeControl, deck: Int, _ v: Double) -> [BridgeMessage] {
        let x = clamp14(v), msb = UInt8(x >> 7), lsb = UInt8(x & 0x7f), d = UInt8(deck & 3)
        func pair(_ status: UInt8, _ cc: UInt8) -> [BridgeMessage] { [BridgeMessage(bytes: [status, cc, msb]), BridgeMessage(bytes: [status, cc + 0x20, lsb])] }
        if let cc = deckCC[c] { return pair(0xB0 | d, cc) }
        switch c {
        case .filter: return pair(0xB0 | globalChannel, 0x17 + d)
        case .crossfader: return pair(0xB0 | globalChannel, 0x1F)
        case .fxDepth: return pair(0xB0 | fxChannel, 0x02)
        default: return []
        }
    }
    /// jog / browse movement: ticks (+ clockwise), split into messages of at most ±63
    public static func relative(_ c: BridgeControl, deck: Int, ticks: Int) -> [BridgeMessage] {
        let status: UInt8, cc: UInt8
        if let j = jogCC[c] { status = 0xB0 | UInt8(deck & 3); cc = j }
        else if c == .browse { status = 0xB0 | globalChannel; cc = 0x40 }
        else { return [] }
        var left = ticks, out = [BridgeMessage]()
        while left != 0 {
            let step = max(-63, min(63, left))
            out.append(BridgeMessage(bytes: [status, cc, UInt8(64 + step)]))
            left -= step
        }
        return out
    }

    // ---- what rekordbox sends back (lights) ----
    public enum Feedback: Equatable { case button(BridgeControl, deck: Int, on: Bool), hotCue(Int, deck: Int, on: Bool), pad(PadBank, Int, deck: Int, on: Bool), fx(BridgeControl, on: Bool) }
    public static func feedback(_ m: [UInt8]) -> Feedback? {
        guard m.count >= 3 else { return nil }
        let kind = m[0] & 0xF0, ch = m[0] & 0x0F
        guard kind == 0x90 || kind == 0x80 else { return nil }
        let on = kind == 0x90 && m[2] > 0
        if ch <= 3, let c = deckNote.first(where: { $0.value == m[1] })?.key { return .button(c, deck: Int(ch), on: on) }
        if ch >= padChannel0 && ch <= padChannel0 + 3 {
            if m[1] < 8 { return .hotCue(Int(m[1]), deck: Int(ch - padChannel0), on: on) }
            if m[1] & 0x08 == 0, let b = PadBank.allCases.first(where: { $0.base == m[1] & 0xF0 }) { return .pad(b, Int(m[1] & 7), deck: Int(ch - padChannel0), on: on) }
        }
        if ch == fxChannel && m[1] == 0x47 { return .fx(.fxOn, on: on) }
        return nil
    }

    // ---- the rekordbox mapping file ----
    struct Row { let name: String, function: String, type: String, input: String, decks: String, output: String, outDecks: String, option: String, comment: String }
    static func hex(_ status: UInt8, _ d1: UInt8) -> String { String(format: "%02X%02X", status, d1) }

    /// rekordbox's MIDI mapping file for Deck Bridge (CSV, CRLF): rekordbox → MIDI → pick "Cratebox Deck
    /// Bridge" (or the network session it shows up as) → IMPORT
    public static func rekordboxCSV(deviceName: String = "Cratebox Deck Bridge") -> String {
        var rows = [Row]()
        let four = "0,1,2,3", pads = "7,8,9,10"
        let deckRows: [(BridgeControl, String, String, String, String)] = [
            (.playPause, "PlayPause", "PlayPause", "Fast;Blink=1000;Priority=50", "Play/Pause"),
            (.cue, "Cue", "Cue", "Fast;Blink=500;Priority=50", "Cue"),
            (.jumpToStart, "JumpToTrackStart", "Cue+Shift", "Fast;Priority=50", "Jump to track start"),
            (.sync, "Sync", "Sync", "Blink=600", "Sync On/Off"),
            (.keylock, "MasterTempo", "MasterTempo", "", "Master Tempo (key lock) On/Off"),
            (.quantize, "Quantize", "Quantize", "", "Quantize On/Off"),
            (.slip, "Slip", "Slip", "", "Slip On/Off"),
            (.loopIn, "LoopIn", "LoopIn", "Fast", "Loop in"),
            (.loopOut, "LoopOut", "LoopOut", "Fast", "Loop out"),
            (.reloopExit, "ReloopExit", "LoopOut+Shift", "Fast", "Reloop/Exit"),
            (.autoLoop, "4BeatLoop", "4BeatLoop", "Fast", "Auto Loop On/Off"),
            (.loopHalf, "LoopHalf", "LoopHalf", "Fast", "Loop 1/2"),
            (.loopDouble, "LoopDouble", "LoopDouble", "Fast", "Loop x2"),
            (.headphoneCue, "HeadphoneCue", "HeadphoneCue", "", "Headphone cue"),
            (.hotCueMode, "HotCue", "HotCueMode", "Fast", "HOT CUE pad mode"),
            (.beatJumpMode, "BeatJump", "BeatJumpMode", "Fast", "BEAT JUMP pad mode"),
            (.padFx1Mode, "PadFx1", "PadFx1Mode", "Fast", "PAD FX 1 pad mode"),
            (.padFx2Mode, "PadFx2", "PadFx2Mode", "Fast", "PAD FX 2 pad mode"),
        ]
        for (c, name, fn, opt, comment) in deckRows {
            let code = hex(0x90, deckNote[c]!)
            rows.append(Row(name: name, function: fn, type: "Button", input: code, decks: four, output: code, outDecks: four, option: opt, comment: comment))
        }
        for k in 0..<8 {
            rows.append(Row(name: "PAD\(k + 1)_HotCue", function: "PAD\(k + 1).HotCue.Call", type: "Pad", input: hex(0x90, UInt8(k)), decks: pads, output: hex(0x90, UInt8(k)), outDecks: pads, option: "Fast", comment: "Hot cue \(k + 1)"))
            rows.append(Row(name: "PAD\(k + 1)_HotCue+Shift", function: "PAD\(k + 1).HotCue.Delete", type: "Pad", input: hex(0x90, UInt8(8 + k)), decks: pads, output: "", outDecks: "", option: "Fast", comment: "Delete hot cue \(k + 1)"))
        }
        for (bank, name, label) in [(PadBank.beatJump, "BeatJump", "Beat jump"), (.padFx1, "PadFx1", "Pad FX 1"), (.padFx2, "PadFx2", "Pad FX 2")] {
            for k in 0..<8 {
                let code = hex(0x90, bank.base + UInt8(k))
                rows.append(Row(name: "PAD\(k + 1)_\(name)", function: "PAD\(k + 1).\(name)", type: "Pad", input: code, decks: pads, output: code, outDecks: pads, option: "Fast", comment: "\(label) pad \(k + 1)"))
            }
        }
        let cc: [(BridgeControl, String, String)] = [(.tempo, "TempoSlider", "Tempo"), (.trim, "Gain", "Trim"), (.eqHigh, "EQHigh", "EQ high"), (.eqMid, "EQMid", "EQ mid"),
                                                     (.eqLow, "EQLow", "EQ low"), (.channelFader, "ChannelFader", "Channel fader")]
        for (c, name, comment) in cc {
            rows.append(Row(name: name, function: name, type: "KnobSliderHiRes", input: hex(0xB0, deckCC[c]!), decks: four, output: "", outDecks: "", option: "Fast", comment: comment))
        }
        rows.append(Row(name: "JogScratch", function: "JogScratch", type: "JogRotate", input: hex(0xB0, 0x22), decks: four, output: "", outDecks: "", option: "", comment: "Jog: scratch (touching)"))
        rows.append(Row(name: "JogPitchBend", function: "JogPitchBend", type: "JogRotate", input: hex(0xB0, 0x23), decks: four, output: "", outDecks: "", option: "", comment: "Jog: pitch bend (edge)"))
        rows.append(Row(name: "JogTouch", function: "JogTouch", type: "JogTouch", input: hex(0x90, jogTouchNote), decks: four, output: "", outDecks: "", option: "", comment: "Jog: touch"))
        for d in 0..<4 {
            rows.append(Row(name: "CFXParameterCH\(d + 1)", function: "CFXParameterCH\(d + 1)", type: "KnobSliderHiRes", input: hex(0xB0 | globalChannel, 0x17 + UInt8(d)), decks: ",,,", output: "", outDecks: "", option: "Fast", comment: "CH\(d + 1) filter (Sound Color FX)"))
            rows.append(Row(name: "FX1Assign.CH\(d + 1)", function: "", type: "Button", input: hex(0x90 | fxChannel, 0x10 + UInt8(d)), decks: ",,,", output: "", outDecks: "", option: "", comment: "Beat FX on CH\(d + 1)"))
        }
        rows.append(Row(name: "CFX4On", function: "CFX4On", type: "Button", input: hex(0x90 | globalChannel, 0x03), decks: ",,,", output: hex(0x90 | globalChannel, 0x03), outDecks: ",,,", option: "Fast", comment: "Sound Color FX: FILTER"))
        rows.append(Row(name: "CrossFader", function: "CrossFader", type: "KnobSliderHiRes", input: hex(0xB0 | globalChannel, 0x1F), decks: ",,,", output: "", outDecks: "", option: "Fast", comment: "Crossfader"))
        rows.append(Row(name: "Browse", function: "Browse", type: "Rotary", input: hex(0xB0 | globalChannel, 0x40), decks: ",,,", output: "", outDecks: "", option: "", comment: "Browse"))
        rows.append(Row(name: "Back", function: "Back", type: "Button", input: hex(0x90 | globalChannel, 0x65), decks: ",,,", output: "", outDecks: "", option: "", comment: "Library back"))
        rows.append(Row(name: "Load", function: "Load", type: "Button", input: "", decks: (0..<4).map { hex(0x90 | globalChannel, 0x46 + UInt8($0)) }.joined(separator: ","),
                        output: "", outDecks: ",,,", option: "", comment: "Load to deck"))
        rows.append(Row(name: "FX1-1", function: "FX1-1", type: "KnobSliderHiRes", input: hex(0xB0 | fxChannel, 0x02), decks: ",,,", output: "", outDecks: "", option: "", comment: "Beat FX depth"))
        rows.append(Row(name: "FX1-1On", function: "FX1-1On", type: "Button", input: hex(0x90 | fxChannel, 0x47), decks: ",,,", output: hex(0x90 | fxChannel, 0x47), outDecks: ",,,", option: "", comment: "Beat FX on/off"))
        rows.append(Row(name: "FX1-1Select", function: "FX1-1Select", type: "Button", input: hex(0x90 | fxChannel, 0x63), decks: ",,,", output: "", outDecks: "", option: "", comment: "Beat FX select"))
        rows.append(Row(name: "FX1BeatDown", function: "FX1BeatDown", type: "Button", input: hex(0x90 | fxChannel, 0x4A), decks: ",,,", output: "", outDecks: "", option: "", comment: "Beat FX beat -"))
        rows.append(Row(name: "FX1BeatUp", function: "FX1BeatUp", type: "Button", input: hex(0x90 | fxChannel, 0x4B), decks: ",,,", output: "", outDecks: "", option: "", comment: "Beat FX beat +"))
        var lines = ["@file,1,\(deviceName)", "#name,function,type,input,deck1,deck2,deck3,deck4,output,deck1,deck2,deck3,deck4,option,comment"]
        for r in rows {
            let outDecks = r.outDecks.isEmpty ? ",,," : r.outDecks
            lines.append([r.name, r.function, r.type, r.input, r.decks, r.output, outDecks, r.option, r.comment].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
