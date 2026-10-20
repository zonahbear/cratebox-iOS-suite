import SwiftUI
import UIKit
import CrateboxKit

/// iPhone, landscape, edge to edge: the waveforms and decks inside the safe area, and the strips beside the
/// Dynamic Island used for buttons. Each deck's edge strip: ±range / TAP / GRID at the top (beside the
/// waveforms), SYNC / MT / Q at the bottom (below the island). FX and REC sit in the middle of the strip
/// away from the island (they swap sides when the phone is turned round). The home-bar strip shows text only.
struct PhoneScreen: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @Binding var settings: Bool
    @State private var islandLeft = PhoneScreen.islandOnLeft()

    static func islandOnLeft() -> Bool {
        // interface orientation "landscape right" = the top of the phone (the island) on the left
        let s = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (s?.interfaceOrientation ?? .landscapeRight) == .landscapeRight
    }

    static func windowInsets() -> UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }?.safeAreaInsets ?? .zero
    }

    var body: some View {
        let ins = PhoneScreen.windowInsets()
        let band = max(46, min(ins.left, ins.right))
        let l = core.four ? app.midi.side[0] : 0, r = core.four ? app.midi.side[1] : 1
        // the whole screen: a reader that itself ignores the safe area gets the full size
        return GeometryReader { g in HStack(spacing: 0) {
            EdgeStrip(deck: core.decks[l], side: 0, center: !islandLeft, top: 34, bottom: max(ins.bottom, 6)).frame(width: band).zIndex(1)
            VStack(spacing: 4) {
                PhoneTopBar(settings: $settings).frame(height: 30)
                if app.tab == 0 {
                    mix(l, r).overlay { if app.browserShown { BrowserOverlay().transition(.opacity) } }
                } else { LibraryPane() }
                // the home-bar strip: text only, so a swipe home never lands on a control
                HStack {
                    StripInfo(deck: core.decks[l])
                    Spacer()
                    StripInfo(deck: core.decks[r])
                }.frame(height: max(ins.bottom, 12))
            }
            .clipped()          // nothing in the middle may spill over the edge strips
            EdgeStrip(deck: core.decks[r], side: 1, center: islandLeft, top: 34, bottom: max(ins.bottom, 6)).frame(width: band).zIndex(1)
        }
        .padding(.top, ins.top)
        .frame(width: g.size.width, height: g.size.height)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DispatchQueue.main.async { islandLeft = PhoneScreen.islandOnLeft() }
        }
    }

    func mix(_ l: Int, _ r: Int) -> some View {
        VStack(spacing: 4) {
            VStack(spacing: 3) {
                PhoneLane(deck: core.decks[l]); PhoneLane(deck: core.decks[r])
                if core.four {
                    HStack(spacing: 4) { ForEach([0, 1, 2, 3].filter { $0 != l && $0 != r }, id: \.self) { i in PhoneLane(deck: core.decks[i], active: false) } }
                }
            }.frame(minHeight: 80, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 4) {
                PhoneDeck(deck: core.decks[l], side: 0).id(l)
                MixerView(phone: true)
                PhoneDeck(deck: core.decks[r], side: 1).id(r)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// the bar along the top on a phone: controller, MIX / LIBRARY, status, the master section, 4 DECKS, settings
struct PhoneTopBar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @Binding var settings: Bool
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(app.controllerName.isEmpty ? Theme.dim : Theme.ok).frame(width: 7, height: 7)
                Text(app.controllerName.isEmpty ? "No controller" : app.controllerName).font(.system(size: 11)).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.raise))
            Picker("", selection: $app.tab) { Text("MIX").tag(0); Text("LIBRARY").tag(1) }.pickerStyle(.segmented).frame(width: 150)
            Text(app.statusText).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            MixerView(masterBar: true)
            LitButton(label: "4 DECKS", on: core.four, color: Theme.fg) { core.setFour(!core.four); if !core.four { app.midi.resetSides() } }
            Button { settings = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
        }
    }
}

/// one deck's edge strip
struct EdgeStrip: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var fx: FxController
    @ObservedObject var deck: DeckModel
    let side: Int
    let center: Bool              // this strip is away from the island: FX and REC go in its middle
    let top: CGFloat, bottom: CGFloat
    @State private var fxSheet = false
    @State private var tools = false
    var color: Color { Theme.deck[deck.i] }
    var body: some View {
        VStack(spacing: 5) {
            Color.clear.frame(height: top)
            // tempo range, TAP and GRID, under one button: a small panel that stays open while you tap
            Button { tools = true } label: {
                VStack(spacing: 1) {
                    Text("±\(deck.range == 100 ? "W" : String(Int(deck.range)))").font(.system(size: 11, weight: .heavy))
                    Text("TAP · GRID").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.6)
                }.frame(maxWidth: .infinity, minHeight: 44).background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise))
            }.buttonStyle(.plain)
            .popover(isPresented: $tools, arrowEdge: side == 0 ? .leading : .trailing) {
                HStack(spacing: 8) {
                    LitButton(label: "RANGE ±\(deck.range == 100 ? "W" : String(Int(deck.range)))") { deck.cycleRange() }
                    Button { deck.tap() } label: {
                        Text("TAP").font(.system(size: 15, weight: .heavy)).frame(width: 84, height: 56).background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.85))).foregroundStyle(Color.black)
                    }.buttonStyle(.plain)
                    LitButton(label: "BEAT GRID…") { tools = false; app.gridDeck = deck.i }
                    LitButton(label: "TEMPO 0") { deck.setPitch(0) }
                }
                .padding(10)
                .presentationCompactAdaptation(.popover)
            }
            Spacer(minLength: 4)
            if center {
                Button { fxSheet = true } label: {
                    VStack(spacing: 2) {
                        Text("FX").font(.system(size: 11, weight: .heavy)).foregroundStyle(fx.on ? Color.black : Theme.hot)
                        Text(fx.fx.rawValue.uppercased()).font(.system(size: 7, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(fx.on ? Color.black : Theme.muted)
                    }.frame(maxWidth: .infinity, minHeight: 48).background(RoundedRectangle(cornerRadius: 7).fill(fx.on ? Theme.hot : Theme.raise))
                }.buttonStyle(.plain)
                .sheet(isPresented: $fxSheet) { BeatFXView().padding().presentationDetents([.height(220)]) }
                EdgeRec(rec: app.recorder)
                Spacer(minLength: 4)
            }
            edge("SYNC", deck.sync, color) { deck.setSync(!deck.sync) }
            edge("MT", deck.mt, color) { deck.setMT(!deck.mt) }
            edge("Q", deck.quant, color) { deck.quant.toggle() }
            Color.clear.frame(height: bottom)
        }
        .padding(.horizontal, 5)
    }
    func edge(_ s: String, _ on: Bool, _ c: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? Color.black : Theme.fg)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? c : Theme.raise))
        }.buttonStyle(.plain)
    }
}
struct EdgeRec: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var rec: Recorder
    var body: some View {
        Button { rec.recording ? rec.stop(app.audio.engine) : rec.start(app.audio.engine) } label: {
            VStack(spacing: 2) {
                Circle().fill(rec.recording ? Color.white : Theme.hot).frame(width: 12, height: 12)
                Text(rec.recording ? String(format: "%d:%02d", Int(rec.seconds) / 60, Int(rec.seconds) % 60) : "REC").font(.system(size: 9, weight: .bold, design: .monospaced))
            }.frame(maxWidth: .infinity, minHeight: 48).background(RoundedRectangle(cornerRadius: 7).fill(rec.recording ? Theme.hot : Theme.raise))
        }.buttonStyle(.plain)
    }
}

/// elapsed time, loop and sync, in the home-bar strip
struct StripInfo: View {
    @ObservedObject var deck: DeckModel
    var body: some View {
        let parts = ["\(deck.i + 1)", deck.loaded ? clock(deck.now()) : "–", deck.loop.on ? "loop \(fracText(deck.loopBeats()))" : nil, deck.sync ? "synced" : nil].compactMap { $0 }
        Text(parts.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).padding(.horizontal, 10)
    }
}

/// a deck on the phone: tempo fader on the outside, jog, CUE and PLAY, IN / OUT / RELOOP, pad modes, 8 pads
struct PhoneDeck: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var deck: DeckModel
    let side: Int
    var color: Color { Theme.deck[deck.i] }
    var body: some View {
        VStack(spacing: 5) {
            if app.core.four {
                HStack(spacing: 4) {
                    ForEach([deck.i % 2, deck.i % 2 + 2], id: \.self) { d in
                        let on = d == deck.i
                        Button { app.midi.setSide(d % 2, d); app.objectWillChange.send() } label: {
                            Text("DECK \(d + 1)").font(.system(size: 10, weight: .bold)).frame(maxWidth: .infinity, minHeight: 18)
                                .foregroundStyle(on ? Color.black : Theme.deck[d])
                                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.deck[d] : Theme.raise))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 0) {
                if side == 0 { TempoFader(deck: deck).frame(width: 30); Spacer(minLength: 10) }
                else { loopCol; Spacer(minLength: 6); transport; Spacer(minLength: 6) }
                JogView(deck: deck, color: color).frame(width: 112, height: 112)
                if side == 0 { Spacer(minLength: 6); transport; Spacer(minLength: 6); loopCol }
                else { Spacer(minLength: 10); TempoFader(deck: deck).frame(width: 30) }
            }.frame(height: 116)
            HStack(spacing: 4) {
                ForEach([(PadMode.hotcue, "CUES"), (.beatloop, "LOOP"), (.beatjump, "JUMP"), (.padfx, "FX1"), (.padfx2, "FX2")], id: \.1) { m, s in
                    Button { deck.padMode = m } label: {
                        Text(s).font(.system(size: 11, weight: .bold)).frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(deck.padMode == m ? Theme.fg : Theme.muted)
                            .background(RoundedRectangle(cornerRadius: 6).fill(deck.padMode == m ? Theme.line2 : Theme.raise))
                    }.buttonStyle(.plain)
                }
            }
            VStack(spacing: 4) {
                HStack(spacing: 4) { ForEach(0..<4, id: \.self) { p in PadCell(deck: deck, p: p, height: app.core.four ? 34 : 38) } }
                HStack(spacing: 4) { ForEach(4..<8, id: \.self) { p in PadCell(deck: deck, p: p, height: app.core.four ? 34 : 38) } }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.core.four ? color.opacity(0.7) : Theme.line, lineWidth: 1))
    }
    var transport: some View {
        VStack(spacing: 6) {
            HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                Text("CUE").font(.system(size: 13, weight: .bold)).frame(width: 70, height: 50)
                    .background(Capsule().fill(Theme.raise)).overlay(Capsule().stroke(Theme.cue, lineWidth: 2))
            }
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(width: 70, height: 50)
                    .background(Capsule().fill(deck.playing ? Theme.ok.opacity(0.25) : Theme.raise)).overlay(Capsule().stroke(Theme.ok, lineWidth: 2))
            }.buttonStyle(.plain)
        }
    }
    var loopCol: some View {
        VStack(spacing: 4) {
            loopBtn("IN", deck.loop.a != nil && deck.loop.b == nil) { deck.loopIn() }
            loopBtn("OUT", deck.loop.on) { deck.loopOut() }
            loopBtn(deck.loop.on ? "EXIT" : "RELOOP", deck.loop.b != nil) { deck.reloopExit() }
        }.frame(width: 70)
    }
    func loopBtn(_ s: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(on ? Color.white : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.loop : Theme.raise))
        }.buttonStyle(.plain)
    }
}

/// a hardware-style tempo fader: wide cap with a line in the deck colour, a scale with the centre marked,
/// the pitch % on top. Up is slower, down is faster (like the FLX4). Double-tap: back to 0.
struct TempoFader: View {
    @ObservedObject var deck: DeckModel
    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "%+.1f", (deck.rate() - 1) * 100)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            GeometryReader { g in
                let h = g.size.height, w = g.size.width, v = (deck.pitch + 1) / 2   // 0 top (slower) ... 1 bottom (faster)
                ZStack(alignment: .top) {
                    ForEach(0...8, id: \.self) { k in
                        Rectangle().fill(k == 4 ? Theme.muted : Theme.line2).frame(width: k == 4 ? w - 4 : w - 12, height: 1)
                            .offset(y: 9 + (h - 18) * CGFloat(k) / 8)
                    }
                    RoundedRectangle(cornerRadius: 2).fill(Theme.bg).frame(width: 4, height: h - 18).offset(y: 9)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Theme.line2, Theme.raise], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.dim, lineWidth: 1))
                        .overlay(Rectangle().fill(Theme.deck[deck.i]).frame(height: 2).padding(.horizontal, 3))
                        .frame(width: w, height: 18)
                        .offset(y: CGFloat(v) * (h - 18))
                }
                .frame(width: w, height: h, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    let y = min(max(0, d.location.y - 9), h - 18)
                    deck.setPitch(Double(y / (h - 18)) * 2 - 1)
                })
                .onTapGesture(count: 2) { deck.setPitch(0) }
            }
        }
    }
}
