// Deck Bridge's screen, built to look exactly like Performance Mode's: the same edge strips (SYNC / MT / Q),
// the same decks (tempo fader, jog, CUE and PLAY, IN / OUT / RELOOP, pad modes, 8 pads) and the same mixer
// (a row per knob, CUE, faders, crossfader), in the same colours and shapes. Deck Bridge has no waveforms, so
// the decks get the whole height: the jogs and pads grow to fill it. Everything sends MIDI to rekordbox
// instead of playing here, and rekordbox's lights come back onto the buttons.
import SwiftUI
import CrateboxKit

struct BridgeScreen: View {
    @ObservedObject var bridge: DeckBridge
    @Binding var setup: Bool
    var body: some View {
        let ins = PhoneScreen.windowInsets()
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let band = phone ? max(40, min(ins.left, ins.right)) : 58
        GeometryReader { g in
            HStack(spacing: 0) {
                BridgeEdge(bridge: bridge, deck: bridge.sides[0], side: 0, top: 44, bottom: max(ins.bottom, 6) + 10).frame(width: band)
                VStack(spacing: 4) {
                    BridgeTopBar(bridge: bridge, setup: $setup, narrow: g.size.width - 2 * band < 680).frame(height: 30)
                    GeometryReader { b in
                        let mixW: CGFloat = min(170, max(140, b.size.width * 0.19))
                        HStack(alignment: .top, spacing: 4) {
                            BridgeDeck(bridge: bridge, deck: bridge.sides[0], side: 0)
                            BridgeMixerView(bridge: bridge, a: bridge.sides[0], b: bridge.sides[1]).frame(width: mixW)
                            BridgeDeck(bridge: bridge, deck: bridge.sides[1], side: 1)
                        }
                    }
                    // the home-bar strip: text only, like Performance Mode
                    HStack {
                        Text("\(bridge.sides[0].deck + 1) · rekordbox").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).padding(.horizontal, 10)
                        Spacer()
                        Text("\(bridge.sides[1].deck + 1) · rekordbox").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).padding(.horizontal, 10)
                    }.frame(height: max(ins.bottom, 12))
                }
                .frame(width: max(0, g.size.width - 2 * band))   // a fixed width: too little room clips the middle, never shoves the strips off
                .clipped()
                BridgeEdge(bridge: bridge, deck: bridge.sides[1], side: 1, top: 44, bottom: max(ins.bottom, 6) + 10).frame(width: band)
            }
            .padding(.top, phone ? ins.top : 6)
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
    }
}

/// the bar along the top, like Performance Mode's: mode, link, which rekordbox decks, browse and load, settings
struct BridgeTopBar: View {
    @ObservedObject var bridge: DeckBridge
    @Binding var setup: Bool
    var narrow = false                  // an SE: tighter picker and keys so the bar fits
    var body: some View {
        let key: CGFloat = narrow ? 30 : 34, load: CGFloat = narrow ? 50 : 62
        HStack(spacing: narrow ? 6 : 8) {
            ModeSwitcher(compact: true)
            HStack(spacing: 4) {
                Circle().fill(bridge.heardRecently ? Theme.ok : bridge.confirmed ? Theme.accent : bridge.linked ? Theme.warn : Theme.dim).frame(width: 7, height: 7)
                Text(bridge.heardRecently ? "rekordbox linked" : bridge.confirmed ? "Linked" : bridge.linked ? "Sending" : "Not linked").font(.system(size: 11)).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.raise)).frame(maxWidth: narrow ? 92 : 180)
            .onTapGesture { setup = true }
            Picker("", selection: $bridge.pair) { Text(narrow ? "1·2" : "DECKS 1·2").tag(0); Text(narrow ? "3·4" : "DECKS 3·4").tag(1) }.pickerStyle(.segmented).frame(width: narrow ? 96 : 190)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                BridgeKey(label: "▲", height: 26) { if $0 { bridge.browse(-1) } }.frame(width: key)
                BridgeKey(label: "▼", height: 26) { if $0 { bridge.browse(1) } }.frame(width: key)
                BridgeKey(label: "LOAD \(bridge.sides[0].deck + 1)", height: 26) { if $0 { bridge.load(side: 0) } }.frame(width: load)
                BridgeKey(label: "LOAD \(bridge.sides[1].deck + 1)", height: 26) { if $0 { bridge.load(side: 1) } }.frame(width: load)
                BridgeKey(label: "BACK", height: 26) { bridge.global(.back, on: $0) }.frame(width: narrow ? 44 : 48)
            }
            Button { setup = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
        }
    }
}

/// one side's edge strip, like Performance Mode's: SHIFT or FX at the top, SYNC / MT / Q at the bottom
struct BridgeEdge: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var deck: BridgeDeckState
    let side: Int
    let top: CGFloat, bottom: CGFloat
    @State private var fx = false
    var color: Color { Theme.deck[deck.deck] }
    var body: some View {
        VStack(spacing: 5) {
            Color.clear.frame(height: top)
            if side == 1 {
                Button { fx = true } label: {
                    VStack(spacing: 2) {
                        Text("FX").font(.system(size: 11, weight: .heavy)).foregroundStyle(bridge.fxOn ? Color.black : Theme.hot)
                        Text("BEAT").font(.system(size: 7, weight: .bold)).foregroundStyle(bridge.fxOn ? Color.black : Theme.muted)
                    }.frame(maxWidth: .infinity, minHeight: 48).background(RoundedRectangle(cornerRadius: 7).fill(bridge.fxOn ? Theme.hot : Theme.raise))
                }.buttonStyle(.plain)
                .popover(isPresented: $fx, arrowEdge: .trailing) { BridgeFXPanel(bridge: bridge).padding(10).presentationCompactAdaptation(.popover) }
            } else {
                BridgeKey(label: "SHIFT", lit: bridge.shift, color: Theme.hot, height: 48) { if $0 { bridge.shift.toggle() } }
            }
            Spacer(minLength: 4)
            edge("SYNC", .sync)
            edge("MT", .keylock)
            edge("Q", .quantize)
            Color.clear.frame(height: bottom)
        }
        .padding(.horizontal, 7)
    }
    func edge(_ s: String, _ c: BridgeControl) -> some View {
        BridgeKey(label: s, lit: deck.lit(c), color: color, height: 32) { bridge.button(c, side: side, on: $0) }
    }
}

struct BridgeFXPanel: View {
    @ObservedObject var bridge: DeckBridge
    var body: some View {
        HStack(spacing: 8) {
            BridgeKey(label: "FX ON", lit: bridge.fxOn, color: Theme.hot, height: 44) { bridge.global(.fxOn, on: $0) }.frame(width: 70)
            BridgeKey(label: "SELECT", height: 44) { bridge.global(.fxSelect, on: $0) }.frame(width: 70)
            BridgeKey(label: "◀ BEAT", height: 44) { bridge.global(.fxBeatDown, on: $0) }.frame(width: 64)
            BridgeKey(label: "BEAT ▶", height: 44) { bridge.global(.fxBeatUp, on: $0) }.frame(width: 64)
            Knob(label: "DEPTH", value: bridge.fxDepth, color: Theme.hot, size: 34) { bridge.setFxDepth($0) }
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { s in
                    BridgeKey(label: "ON \(bridge.sides[s].deck + 1)", lit: bridge.fxAssign[bridge.sides[s].deck], color: Theme.hot, height: 20) { if $0 { bridge.toggleFxAssign(side: s) } }.frame(width: 54)
                }
            }
        }
    }
}

/// a deck, like Performance Mode's PhoneDeck: the same parts and shapes, sized to the space
struct BridgeDeck: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var deck: BridgeDeckState
    let side: Int
    var color: Color { Theme.deck[deck.deck] }
    static let tempoW: CGFloat = 40, capW: CGFloat = 70, loopH: CGFloat = 34, tabsH: CGFloat = 22
    /// the jog takes the width left after the tempo fader and CUE / PLAY (and leaves room for two rows of pads)
    static func jogSize(_ W: CGFloat, _ H: CGFloat) -> CGFloat {
        let byWidth: CGFloat = W - tempoW - capW - 20
        let byHeight: CGFloat = H - loopH - tabsH - 88 - 20
        return max(72, min(byWidth, byHeight))
    }
    var body: some View {
        GeometryReader { g in
            let W: CGFloat = g.size.width - 12
            let H: CGFloat = g.size.height - 12
            let jog: CGFloat = BridgeDeck.jogSize(W, H)
            let rest: CGFloat = H - jog - BridgeDeck.loopH - BridgeDeck.tabsH - 24
            let padH: CGFloat = max(36, rest / 2)
            VStack(spacing: 5) {
                topBlock(jog)
                tabsRow
                padsGrid(padH)
            }
            .padding(6)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.7), lineWidth: 1))
        }
    }
    /// tempo fader (full height of jog and loops), the jog with CUE / PLAY beside it, IN / OUT / RELOOP under them
    func topBlock(_ jog: CGFloat) -> some View {
        let fullH: CGFloat = jog + 5 + BridgeDeck.loopH
        let colW: CGFloat = jog + 6 + BridgeDeck.capW
        return HStack(alignment: .top, spacing: 0) {
            if side == 0 { tempoFader(fullH); Spacer(minLength: 10) }
            VStack(spacing: 5) {
                jogRow(jog)
                loopRow.frame(width: colW)
            }.frame(width: colW)
            if side == 1 { Spacer(minLength: 10); tempoFader(fullH) }
        }
    }
    func tempoFader(_ h: CGFloat) -> some View {
        BridgeTempo(bridge: bridge, deck: deck, side: side).frame(width: BridgeDeck.tempoW, height: h)
    }
    func jogRow(_ jog: CGFloat) -> some View {
        HStack(spacing: 6) {
            if side == 1 { transport(jog) }
            BridgeJog(bridge: bridge, deck: deck, side: side, color: color).frame(width: jog, height: jog)
            if side == 0 { transport(jog) }
        }
    }
    var loopRow: some View {
        HStack(spacing: 4) {
            loopKey("IN", deck.loopIn, .loopIn, BridgeDeck.loopH)
            loopKey("OUT", deck.loopOut, .loopOut, BridgeDeck.loopH)
            loopKey(deck.reloop ? "EXIT" : "RELOOP", deck.reloop, .reloopExit, BridgeDeck.loopH)
        }
    }
    var tabsRow: some View {
        HStack(spacing: 4) {
            ForEach(DeckBridgeMap.PadBank.allCases, id: \.self) { b in tab(b) }
        }
    }
    func tab(_ b: DeckBridgeMap.PadBank) -> some View {
        let on = deck.padBank == b
        return Button { bridge.setPadBank(b, side: side) } label: {
            Text(b.title).font(.system(size: 11, weight: .bold)).frame(maxWidth: .infinity, minHeight: BridgeDeck.tabsH)
                .foregroundStyle(on ? Theme.fg : Theme.muted)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.line2 : Theme.raise))
        }.buttonStyle(.plain)
    }
    func padsGrid(_ h: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) { ForEach(0..<4, id: \.self) { p in pad(p, h) } }
            HStack(spacing: 4) { ForEach(4..<8, id: \.self) { p in pad(p, h) } }
        }
    }
    func transport(_ jog: CGFloat) -> some View {
        let h = max(44, (jog - 6) / 2)
        return VStack(spacing: 6) {
            BridgeCapsule(lit: deck.cueLit, stroke: Theme.cue, height: h, press: { bridge.button(bridge.shift ? .jumpToStart : .cue, side: side, on: $0) }) {
                Text("CUE").font(.system(size: 13, weight: .bold))
            }
            BridgeCapsule(lit: deck.playing, stroke: Theme.ok, height: h, press: { bridge.button(.playPause, side: side, on: $0) }) {
                Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 17))
            }
        }.frame(width: 70)
    }
    func loopCol(_ jog: CGFloat) -> some View {
        let h = min(44, max(30, (jog - 8) / 3))
        return VStack(spacing: 4) {
            loopKey("IN", deck.loopIn, .loopIn, h)
            loopKey("OUT", deck.loopOut, .loopOut, h)
            loopKey(deck.reloop ? "EXIT" : "RELOOP", deck.reloop, .reloopExit, h)
        }.frame(width: 70)
    }
    func loopKey(_ s: String, _ on: Bool, _ c: BridgeControl, _ h: CGFloat) -> some View {
        BridgeKey(label: s, lit: on, color: Theme.loop, height: h, radius: 7, fontSize: 12) { bridge.button(c, side: side, on: $0) }
    }
    func pad(_ p: Int, _ h: CGFloat) -> some View {
        let b = deck.padBank
        let on = deck.padLit[b.rawValue][p]
        let c: Color = b == .hotCue ? Theme.hot : color
        let label: String = {
            switch b {
            case .hotCue: return String(UnicodeScalar(65 + p)!)
            case .beatJump: return ["◀1", "1▶", "◀2", "2▶", "◀4", "4▶", "◀8", "8▶"][p]
            case .padFx1, .padFx2: return "FX \(p + 1)"
            }
        }()
        return BridgeKey(label: label, lit: on, color: c, height: h, radius: 6, fontSize: 11, plain: true) { bridge.pad(p, side: side, on: $0) }
    }
}

/// CUE / PLAY, the Performance Mode capsules
struct BridgeCapsule<Label: View>: View {
    var lit = false
    let stroke: Color
    var height: CGFloat = 44
    let press: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var down = false
    var body: some View {
        label().frame(width: 70, height: height)
            .foregroundStyle(Theme.fg)
            .background(Capsule().fill(lit || down ? stroke.opacity(0.25) : Theme.raise))
            .overlay(Capsule().stroke(stroke, lineWidth: 2))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; press(true) } }
                .onEnded { _ in down = false; press(false) })
    }
}

/// the tempo fader, drawn like Performance Mode's (ticks, the cap with the deck's colour line); up = slower
struct BridgeTempo: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var deck: BridgeDeckState
    let side: Int
    var body: some View {
        VStack(spacing: 2) {
            Text(abs(deck.tempo - 0.5) < 0.005 ? "0.0" : String(format: "%+.1f", (deck.tempo - 0.5) * 2 * 6)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            GeometryReader { g in
                let h = g.size.height, w = g.size.width, v = deck.tempo
                ZStack(alignment: .top) {
                    ForEach(0...8, id: \.self) { k in
                        Rectangle().fill(k == 4 ? Theme.muted : Theme.line2).frame(width: k == 4 ? w - 4 : w - 12, height: 1)
                            .offset(y: 9 + (h - 18) * CGFloat(k) / 8)
                    }
                    RoundedRectangle(cornerRadius: 2).fill(Theme.bg).frame(width: 4, height: h - 18).offset(y: 9)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Theme.line2, Theme.raise], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.dim, lineWidth: 1))
                        .overlay(Rectangle().fill(Theme.deck[deck.deck]).frame(height: 2).padding(.horizontal, 3))
                        .frame(width: w, height: 18)
                        .offset(y: CGFloat(v) * (h - 18))
                }
                .frame(width: w, height: h, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    let y = min(max(0, d.location.y - 9), h - 18)
                    bridge.value(.tempo, side: side, Double(y / (h - 18)))
                })
                .onTapGesture(count: 2) { bridge.value(.tempo, side: side, 0.5) }
            }
        }
    }
}

/// the mixer, like Performance Mode's phone mixer: a row per knob (channel A, the name, channel B), CUE, faders, crossfader
struct BridgeMixerView: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var a: BridgeDeckState
    @ObservedObject var b: BridgeDeckState
    var body: some View {
        GeometryReader { g in
            let H = g.size.height - 8
            let k = max(22, min(34, (H * 0.5) / 5 - 4))
            let fader = max(70, H - (k + 6) * 5 - 22 - 30 - 16)
            VStack(spacing: 4) {
                VStack(spacing: 1) {
                    row("TRIM", .trim, k, { $0.trim })
                    row("HI", .eqHigh, k, { $0.hi })
                    row("MID", .eqMid, k, { $0.mid })
                    row("LOW", .eqLow, k, { $0.low })
                    row("CFX", .filter, k, { $0.filter }, cfx: true)
                }
                HStack(spacing: 0) {
                    cueBtn(a, 0).frame(maxWidth: .infinity)
                    Color.clear.frame(width: 30, height: 1)
                    cueBtn(b, 1).frame(maxWidth: .infinity)
                }
                HStack(spacing: 0) {
                    VFader(value: a.fader, color: Theme.deck[a.deck], height: fader) { bridge.value(.channelFader, side: 0, $0) }.frame(maxWidth: .infinity)
                    Color.clear.frame(width: 30, height: 1)
                    VFader(value: b.fader, color: Theme.deck[b.deck], height: fader) { bridge.value(.channelFader, side: 1, $0) }.frame(maxWidth: .infinity)
                }
                crossfader
            }
            .padding(4)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        }
    }
    func row(_ label: String, _ c: BridgeControl, _ k: CGFloat, _ get: (BridgeDeckState) -> Double, cfx: Bool = false) -> some View {
        HStack(spacing: 0) {
            Knob(label: "", value: get(a), color: cfx ? Theme.loop : Theme.deck[a.deck], size: k, bipolar: true) { bridge.value(c, side: 0, $0) }.frame(maxWidth: .infinity)
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 30)
            Knob(label: "", value: get(b), color: cfx ? Theme.loop : Theme.deck[b.deck], size: k, bipolar: true) { bridge.value(c, side: 1, $0) }.frame(maxWidth: .infinity)
        }
    }
    func cueBtn(_ d: BridgeDeckState, _ side: Int) -> some View {
        BridgeKey(label: "CUE", lit: d.headphoneCue, color: Theme.cue, height: 22, radius: 4, fontSize: 10, textColor: Theme.deck[d.deck]) { bridge.button(.headphoneCue, side: side, on: $0) }.frame(width: 40)
    }
    var crossfader: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raise).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Theme.fg).frame(width: 16, height: 26)
                    .offset(x: CGFloat(bridge.xfader) * (g.size.width - 16))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                bridge.setXfader(min(1, max(0, Double((d.location.x - 8) / (g.size.width - 16)))))
            })
            .onTapGesture(count: 2) { bridge.setXfader(0.5) }
        }.frame(height: 30)
    }
}
