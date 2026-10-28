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
    @AppStorage("cb.compact") private var compactPref = false

    /// the compact layout is the only one on a phone without an island (SE: the strips only cost width) or a
    /// screen too small for the full one (Display Zoom); Settings → Look can turn it on anywhere else
    static func autoCompact(size: CGSize, insets ins: UIEdgeInsets) -> Bool {
        let band = max(40, min(ins.left, ins.right))
        return max(ins.left, ins.right) < 30 || size.width - 2 * band < 640 || size.height - ins.top < 360
    }
    /// the same check for the current window (Settings), or the -screen frame in CI
    static func autoCompactNow() -> Bool {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
        let s = ScreenOverride.size ?? w?.bounds.size ?? .zero
        return autoCompact(size: CGSize(width: max(s.width, s.height), height: min(s.width, s.height)), insets: windowInsets())
    }

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
        // the strips use the island's inset; a phone without one (SE) gets narrower strips
        let band = max(40, min(ins.left, ins.right))
        let l = core.four ? app.midi.side[0] : 0, r = core.four ? app.midi.side[1] : 1
        // the whole screen: a reader that itself ignores the safe area gets the full size
        return GeometryReader { g in
        let m = PhoneMetrics.make(width: g.size.width - 2 * band, height: g.size.height - ins.top)
        if compactPref || PhoneScreen.autoCompact(size: g.size, insets: ins) {
            CompactScreen(settings: $settings, size: g.size, insets: ins)
        } else {
        HStack(spacing: 0) {
            EdgeStrip(deck: core.decks[l], side: 0, center: !islandLeft, top: 44, bottom: max(ins.bottom, 6) + 10).frame(width: band).zIndex(1)
            VStack(spacing: 4) {
                PhoneTopBar(settings: $settings).frame(height: 30).zIndex(1)     // EJECT's 44 pt touch area overhangs it
                if app.tab == 0 {
                    Group { if app.waveMode { WaveStack() } else { mix(l, r, m) } }.overlay { if app.browserShown { BrowserOverlay().transition(.opacity) } }
                } else { LibraryPane() }
                // the home-bar strip: text only, so a swipe home never lands on a control
                HStack {
                    StripInfo(deck: core.decks[l])
                    Spacer()
                    StripInfo(deck: core.decks[r])
                }.frame(height: max(ins.bottom, 12))
            }
            .frame(width: max(0, g.size.width - 2 * band))
            .clipped()          // a fixed width: nothing in the middle may spill over or push away the edge strips
            EdgeStrip(deck: core.decks[r], side: 1, center: islandLeft, top: 44, bottom: max(ins.bottom, 6) + 10).frame(width: band).zIndex(1)
        }
        .padding(.top, ins.top)
        .frame(width: g.size.width, height: g.size.height)
        .environment(\.phoneMetrics, m)
        }
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        // locked in: no status bar or home bar, and swipes from any edge (home, notifications, Control
        // Center) need a second swipe, so a hand on the edge mid-mix doesn't leave the app
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DispatchQueue.main.async { islandLeft = PhoneScreen.islandOnLeft() }
        }
    }

    func mix(_ l: Int, _ r: Int, _ m: PhoneMetrics) -> some View {
        VStack(spacing: 4) {
            VStack(spacing: 3) {
                PhoneLane(deck: core.decks[l]); PhoneLane(deck: core.decks[r])
                if core.four {
                    HStack(spacing: 4) { ForEach([0, 1, 2, 3].filter { $0 != l && $0 != r }, id: \.self) { i in PhoneLane(deck: core.decks[i], active: false) } }
                }
            }.frame(minHeight: m.wavesMin, maxHeight: .infinity)
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
    @Environment(\.phoneMetrics) var m
    var body: some View {
        HStack(spacing: m.narrowBar ? 6 : 8) {
            ModeSwitcher(compact: true)
            HStack(spacing: 4) {
                Circle().fill(app.controllerName.isEmpty ? Theme.dim : Theme.ok).frame(width: 7, height: 7)
                Text(app.controllerName.isEmpty ? "No controller" : app.controllerName).font(.system(size: 11)).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.raise)).frame(maxWidth: m.narrowBar ? 96 : 180)
            Picker("", selection: $app.tab) { Text("MIX").tag(0); Text("LIBRARY").tag(1) }.pickerStyle(.segmented).frame(width: m.narrowBar ? 132 : 150)
            Text(app.statusText).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            // a narrow phone: CUE/MST, MST and MASTER in a popover behind one button
            if m.narrowBar { MasterButton() } else { MixerView(masterBar: true) }
            HeatButton()
            LitButton(label: "WAVE", on: app.waveMode, color: Theme.accent) { withAnimation(.easeInOut(duration: 0.2)) { app.waveMode.toggle() } }
            LitButton(label: "4 DECKS", on: core.four, color: Theme.fg) { core.setFour(!core.four); if !core.four { app.midi.resetSides() } }
            DriveEjectButton()
            // drawn at 16 pt, touched at about 44 × 44 (HIG minimum) without making the bar any wider
            Button { settings = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
                .contentShape(Rectangle().inset(by: -14))
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
    @Environment(\.phoneMetrics) var metrics
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
        .padding(.horizontal, metrics.narrowStrip ? 4 : 7)
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
    @Environment(\.phoneMetrics) var m
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
                                .contentShape(Rectangle().inset(by: -6))      // an 18 pt chip, touched at 30 pt
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 0) {
                if side == 0 { TempoFader(deck: deck).frame(width: m.fader); Spacer(minLength: m.outer) }
                else { loopCol; Spacer(minLength: m.gap); transport; Spacer(minLength: m.gap) }
                JogView(deck: deck, color: color).frame(width: m.jog, height: m.jog)
                if side == 0 { Spacer(minLength: m.gap); transport; Spacer(minLength: m.gap); loopCol }
                else { Spacer(minLength: m.outer); TempoFader(deck: deck).frame(width: m.fader) }
            }.frame(height: m.deckRow)
            HStack(spacing: 4) {
                ForEach([(PadMode.hotcue, "CUES"), (.beatloop, "LOOP"), (.beatjump, "JUMP"), (.padfx, "FX1"), (.padfx2, "FX2")], id: \.1) { mode, s in
                    Button { deck.padMode = mode } label: {
                        Text(s).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: m.tabH)
                            .foregroundStyle(deck.padMode == mode ? Theme.fg : Theme.muted)
                            .background(RoundedRectangle(cornerRadius: 6).fill(deck.padMode == mode ? Theme.line2 : Theme.raise))
                    }.buttonStyle(.plain)
                }
            }
            VStack(spacing: 4) {
                HStack(spacing: 4) { ForEach(0..<4, id: \.self) { p in PadCell(deck: deck, p: p, height: app.core.four ? m.pad - 3 : m.pad) } }
                HStack(spacing: 4) { ForEach(4..<8, id: \.self) { p in PadCell(deck: deck, p: p, height: app.core.four ? m.pad - 3 : m.pad) } }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.core.four ? color.opacity(0.7) : Theme.line, lineWidth: 1))
    }
    var transport: some View {
        VStack(spacing: 6) {
            HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                Text("CUE").font(.system(size: 13, weight: .bold)).frame(width: m.cap, height: m.capH)
                    .background(Capsule().fill(Theme.raise)).overlay(Capsule().stroke(Theme.cue, lineWidth: 2))
            }
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(width: m.cap, height: m.capH)
                    .background(Capsule().fill(deck.playing ? Theme.ok.opacity(0.25) : Theme.raise)).overlay(Capsule().stroke(Theme.ok, lineWidth: 2))
            }.buttonStyle(.plain)
        }
    }
    var loopCol: some View {
        VStack(spacing: 4) {
            loopBtn("IN", deck.loop.a != nil && deck.loop.b == nil) { deck.loopIn() }
            loopBtn("OUT", deck.loop.on) { deck.loopOut() }
            loopBtn(deck.loop.on ? "EXIT" : "RELOOP", deck.loop.b != nil) { deck.reloopExit() }
        }.frame(width: m.cap)
    }
    func loopBtn(_ s: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: m.loopH)
                .foregroundStyle(on ? Color.black : Theme.fg)
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
                .faderDrag(v, span: h - 18, vertical: true) { deck.setPitch($0 * 2 - 1) }
                .onTapGesture(count: 2) { deck.setPitch(0) }
            }
        }
    }
}

/// The phone layout's sizes, worked out from the room between the edge strips (docs/device-sizes.md: from the 16e,
/// 844 − 2 × 47 = 750 pt, to the 16/17 Pro Max, 956 − 2 × 62 = 832 pt; the SE gets the compact layout instead). The
/// defaults are the Pro Max sizes the layout was drawn at.
/// Compact (under 640 pt, the SE): smaller fader, mixer and pads. The jog and the CUE / PLAY and loop columns
/// share what's left of each deck's width in both.
struct PhoneMetrics {
    var narrowBar = false                // top bar: the master section goes in a popover
    var narrowStrip = false
    var fader: CGFloat = 30, outer: CGFloat = 10, gap: CGFloat = 6
    var jog: CGFloat = 100, cap: CGFloat = 70, capH: CGFloat = 44, loopH: CGFloat = 30
    var tabH: CGFloat = 22, pad: CGFloat = 33
    var mixW: CGFloat = 140, knob: CGFloat = 22, mixLabel: CGFloat = 30, cueH: CGFloat = 22, mixFader: CGFloat = 70, xfH: CGFloat = 18
    var wavesMin: CGFloat = 120
    /// the jog / transport / loops row: the tallest of the three
    var deckRow: CGFloat { max(jog, 2 * capH + 6, 3 * loopH + 8) + 2 }

    static func make(width w: CGFloat, height h: CGFloat) -> PhoneMetrics {
        var m = PhoneMetrics()
        if w < 640 || h < 340 {
            m.fader = 24; m.outer = 6; m.gap = 4; m.capH = 38; m.loopH = 26; m.tabH = 20; m.pad = 28
            m.mixW = 120; m.knob = 18; m.mixLabel = 26; m.cueH = 20; m.mixFader = 48; m.xfH = 16; m.wavesMin = 70
        } else {
            // the mixer no taller than the decks (it was 236 pt against their 209)
            m.knob = 20; m.mixFader = 56; m.wavesMin = 76
        }
        let room = (w - m.mixW - 8) / 2                                     // each deck's share of the row
        let budget = room - 12 - m.fader - m.outer - 2 * m.gap               // jog + CUE/PLAY + loops
        m.jog = min(100, max(64, (budget * 0.42).rounded(.down)))
        m.cap = min(70, max(46, ((budget - m.jog) / 2).rounded(.down)))
        m.narrowBar = w < 680
        m.narrowStrip = w < 640
        return m
    }
}
private struct PhoneMetricsKey: EnvironmentKey { static let defaultValue = PhoneMetrics() }
extension EnvironmentValues {
    var phoneMetrics: PhoneMetrics {
        get { self[PhoneMetricsKey.self] }
        set { self[PhoneMetricsKey.self] = newValue }
    }
}

/// a narrow phone's top bar: MASTER opens the master section (CUE/MST, MST, MASTER) as a popover
struct MasterButton: View {
    @EnvironmentObject var core: Core
    @State private var open = false
    var body: some View {
        LitButton(label: "MASTER", on: core.mixer.masterCue, color: Theme.cue) { open = true }
            .popover(isPresented: $open, arrowEdge: .top) {
                MixerView(masterBar: true).padding(12).presentationCompactAdaptation(.popover)
            }
    }
}
