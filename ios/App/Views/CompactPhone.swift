import SwiftUI
import UIKit
import CrateboxKit

/// The compact phone layout: an SE (no island, so edge strips only cost width), a phone with Display Zoom on
/// (an SE becomes 568 × 320 pt), or any phone with Settings → Look → Compact layout. No edge strips: each deck
/// shows one face at a time, PLAY (platter, CUE, PLAY, SYNC, tempo) or PADS (pad mode, loop, 8 pads), so its
/// buttons can be full size (44 pt, Apple's minimum touch target). The deck's ⋯ holds range, TAP, GRID, MT
/// and Q; the top bar's ⋯ holds WAVE, 4 DECKS, BEAT FX, REC and Settings. The mixer keeps CUE, the faders and
/// the crossfader on screen; TRIM, EQ and CFX open from its EQ button.
struct CompactScreen: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @Binding var settings: Bool
    let size: CGSize
    let insets: UIEdgeInsets

    var body: some View {
        let ins = insets
        let side = max(8, ins.left, ins.right)          // clear of an island when the setting forces this layout
        let w = size.width - 2 * side
        let mixW: CGFloat = w < 600 ? 100 : 120
        let face: CGFloat = size.height >= 400 ? 170 : 140
        let c = CompactMetrics(deckW: ((w - mixW - 8) / 2).rounded(.down), mixW: mixW, face: face)
        let l = core.four ? app.midi.side[0] : 0, r = core.four ? app.midi.side[1] : 1
        return VStack(spacing: 4) {
            CompactTopBar(settings: $settings).frame(height: 36).zIndex(1)     // EJECT's 44 pt touch area overhangs it
            if app.tab == 0 {
                Group {
                    if app.waveMode { WaveStack() } else {
                        VStack(spacing: 4) {
                            VStack(spacing: 3) {
                                PhoneLane(deck: core.decks[l]); PhoneLane(deck: core.decks[r])
                                if core.four {
                                    HStack(spacing: 4) { ForEach([0, 1, 2, 3].filter { $0 != l && $0 != r }, id: \.self) { i in PhoneLane(deck: core.decks[i], active: false) } }
                                }
                            }.frame(minHeight: 40, maxHeight: .infinity)
                            HStack(alignment: .top, spacing: 4) {
                                CompactDeck(deck: core.decks[l], side: 0, c: c).id(l)
                                CompactMixer(c: c)
                                CompactDeck(deck: core.decks[r], side: 1, c: c).id(r)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.overlay { if app.browserShown { BrowserOverlay().transition(.opacity) } }
            } else { LibraryPane() }
            // the home-bar strip: text only, so a swipe home never lands on a control
            HStack {
                StripInfo(deck: core.decks[l])
                Spacer()
                StripInfo(deck: core.decks[r])
            }.frame(height: max(ins.bottom, 12))
        }
        .padding(.top, ins.top + 4)
        .padding(.horizontal, side)
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

struct CompactMetrics {
    let deckW: CGFloat, mixW: CGFloat, face: CGFloat
    let header: CGFloat = 32, btn: CGFloat = 44, capW: CGFloat = 64, faderW: CGFloat = 26
    /// the platter: what's left of the deck beside the tempo fader and the CUE / PLAY / SYNC column
    var jog: CGFloat { max(64, min(face, deckW - 12 - faderW - capW - 16)) }
    var deckH: CGFloat { header + 5 + face + 12 }
}

/// the top bar: mode, MIX / LIBRARY, status, MASTER, and ⋯ for the rest
struct CompactTopBar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var fx: FxController
    @EnvironmentObject var rec: Recorder
    @Binding var settings: Bool
    @State private var fxSheet = false
    var body: some View {
        HStack(spacing: 6) {
            ModeSwitcher(compact: true)
            Picker("", selection: $app.tab) { Text("MIX").tag(0); Text("LIBRARY").tag(1) }.pickerStyle(.segmented).frame(width: 132)
            Text(rec.recording ? String(format: "● REC %d:%02d", Int(rec.seconds) / 60, Int(rec.seconds) % 60) : app.statusText)
                .font(.system(size: 11, weight: rec.recording ? .bold : .regular)).foregroundStyle(rec.recording ? Theme.hot : Theme.muted)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            HeatButton()
            MasterButton()
            EjectButton()
            Menu {
                Toggle("Waveforms (WAVE)", isOn: Binding(get: { app.waveMode }, set: { v in withAnimation(.easeInOut(duration: 0.2)) { app.waveMode = v } }))
                Toggle("4 decks", isOn: Binding(get: { core.four }, set: { core.setFour($0); if !$0 { app.midi.resetSides() } }))
                Button { fxSheet = true } label: { Label("Beat FX: \(fx.fx.rawValue)\(fx.on ? " (on)" : "")", systemImage: "sparkles") }
                Button { rec.recording ? rec.stop(app.audio.engine) : rec.start(app.audio.engine) } label: {
                    Label(rec.recording ? "Stop recording" : "Record the mix", systemImage: rec.recording ? "stop.circle" : "record.circle")
                }
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise))
                    .overlay(alignment: .topTrailing) { if rec.recording || fx.on { Circle().fill(Theme.hot).frame(width: 8, height: 8).offset(x: 2, y: -2) } }
                    .accessibilityLabel("More")
            }
            .sheet(isPresented: $fxSheet) { BeatFXView().padding().presentationDetents([.height(220)]) }
        }
    }
}

/// one deck: a header (deck, PLAY / PADS, ⋯) over one face
struct CompactDeck: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var deck: DeckModel
    let side: Int
    let c: CompactMetrics
    @State private var pads = false
    @State private var tools = false
    var color: Color { Theme.deck[deck.i] }
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                if app.core.four {
                    // 4 decks: the number swaps this side between its two decks (1 ⇄ 3, 2 ⇄ 4)
                    Button { let o = deck.i < 2 ? deck.i + 2 : deck.i - 2; app.midi.setSide(side, o); app.objectWillChange.send() } label: {
                        Text("\(deck.i + 1)⇄\(deck.i < 2 ? deck.i + 3 : deck.i - 1)").font(.system(size: 12, weight: .heavy)).frame(width: 44, height: c.header)
                            .foregroundStyle(Color.black).background(RoundedRectangle(cornerRadius: 6).fill(color))
                    }.buttonStyle(.plain)
                }
                face("PLAY", !pads) { pads = false }
                face("PADS", pads) { pads = true }
                Button { tools = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).frame(width: 40, height: c.header)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
                }.buttonStyle(.plain).accessibilityLabel("Deck \(deck.i + 1) tools")
                .popover(isPresented: $tools, arrowEdge: .top) { toolPanel.presentationCompactAdaptation(.popover) }
            }
            Group { if pads { padFace } else { playFace } }.frame(height: c.face)
        }
        .padding(6)
        .frame(width: c.deckW)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.core.four ? color.opacity(0.7) : Theme.line, lineWidth: 1))
        .onAppear { if side == 1 && CommandLine.arguments.contains("-pads") { pads = true } }   // CI screenshots of the PADS face
    }
    func face(_ s: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 12, weight: .heavy)).frame(maxWidth: .infinity, minHeight: c.header)
                .foregroundStyle(on ? Color.black : Theme.muted)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : Theme.raise))
        }.buttonStyle(.plain)
    }
    /// tempo fader on the outside, the platter, CUE / PLAY / SYNC on the inside
    var playFace: some View {
        HStack(spacing: 4) {
            if side == 0 { TempoFader(deck: deck).frame(width: c.faderW) }
            else { transport }
            Spacer(minLength: 0)
            JogView(deck: deck, color: color).frame(width: c.jog, height: c.jog)
            Spacer(minLength: 0)
            if side == 0 { transport }
            else { TempoFader(deck: deck).frame(width: c.faderW) }
        }
    }
    var transport: some View {
        VStack(spacing: 4) {
            HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                Text("CUE").font(.system(size: 13, weight: .bold)).frame(width: c.capW, height: c.btn)
                    .background(Capsule().fill(Theme.raise)).overlay(Capsule().stroke(Theme.cue, lineWidth: 2))
            }
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(width: c.capW, height: c.btn)
                    .background(Capsule().fill(deck.playing ? Theme.ok.opacity(0.25) : Theme.raise)).overlay(Capsule().stroke(Theme.ok, lineWidth: 2))
            }.buttonStyle(.plain)
            Button { deck.setSync(!deck.sync) } label: {
                Text("SYNC").font(.system(size: 12, weight: .bold)).frame(width: c.capW, height: c.btn)
                    .foregroundStyle(deck.sync ? Color.black : Theme.fg)
                    .background(RoundedRectangle(cornerRadius: 8).fill(deck.sync ? color : Theme.raise))
            }.buttonStyle(.plain)
        }
    }
    /// the pad mode (a menu), IN / OUT / RELOOP, then the 8 pads
    var padFace: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Menu {
                    ForEach([(PadMode.hotcue, "Hot cues"), (.beatloop, "Beat loop"), (.beatjump, "Beat jump"), (.padfx, "Pad FX 1"), (.padfx2, "Pad FX 2")], id: \.1) { mode, s in
                        Button { deck.padMode = mode } label: { if deck.padMode == mode { Label(s, systemImage: "checkmark") } else { Text(s) } }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(modeName).font(.system(size: 11, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }.foregroundStyle(Theme.fg).frame(maxWidth: .infinity, minHeight: c.btn).background(RoundedRectangle(cornerRadius: 7).fill(Theme.line2))
                }
                loopBtn("IN", deck.loop.a != nil && deck.loop.b == nil) { deck.loopIn() }
                loopBtn("OUT", deck.loop.on) { deck.loopOut() }
                loopBtn(deck.loop.on ? "EXIT" : "RELOOP", deck.loop.b != nil) { deck.reloopExit() }
            }
            let ph = (c.face - c.btn - 8) / 2
            HStack(spacing: 4) { ForEach(0..<4, id: \.self) { p in PadCell(deck: deck, p: p, height: ph) } }
            HStack(spacing: 4) { ForEach(4..<8, id: \.self) { p in PadCell(deck: deck, p: p, height: ph) } }
        }
    }
    var modeName: String {
        switch deck.padMode { case .hotcue: return "CUES"; case .beatloop: return "LOOP"; case .beatjump: return "JUMP"; case .padfx: return "FX1"; case .padfx2: return "FX2" }
    }
    func loopBtn(_ s: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: c.btn)
                .foregroundStyle(on ? Color.white : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.loop : Theme.raise))
        }.buttonStyle(.plain)
    }
    /// the deck's ⋯: tempo range, TAP, beat grid, tempo reset, MT and Q, all 44 pt
    var toolPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tool("RANGE ±\(deck.range == 100 ? "W" : String(Int(deck.range)))", false) { deck.cycleRange() }
                Button { deck.tap() } label: {
                    Text("TAP").font(.system(size: 15, weight: .heavy)).frame(width: 84, height: 44).background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.85))).foregroundStyle(Color.black)
                }.buttonStyle(.plain)
                tool("TEMPO 0", false) { deck.setPitch(0) }
            }
            HStack(spacing: 8) {
                tool("MT", deck.mt) { deck.setMT(!deck.mt) }
                tool("Q", deck.quant) { deck.quant.toggle() }
                tool("BEAT GRID…", false) { tools = false; app.gridDeck = deck.i }
            }
        }.padding(10)
    }
    func tool(_ s: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 12, weight: .bold)).lineLimit(1).padding(.horizontal, 10).frame(minWidth: 84, minHeight: 44)
                .foregroundStyle(on ? Color.black : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? color : Theme.raise))
        }.buttonStyle(.plain)
    }
}

/// the slim mixer: EQ (a sheet with TRIM, HI, MID, LOW, CFX), the two channel CUEs, faders and crossfader
struct CompactMixer: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    let c: CompactMetrics
    @State private var eq = false
    var body: some View {
        let sh = core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]
        let fader = c.deckH - c.header - c.btn - 30 - 12 - 3 * 4
        return VStack(spacing: 4) {
            Button { eq = true } label: {
                Text("EQ · TRIM · CFX").font(.system(size: 10, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity, minHeight: c.header)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
            }.buttonStyle(.plain)
            .sheet(isPresented: $eq) { CompactEQ(channels: sh).presentationDetents([.height(250)]) }
            HStack(spacing: 4) { ForEach(sh, id: \.self) { i in cue(i) } }
            HStack(spacing: 0) {
                ForEach(sh, id: \.self) { i in
                    HStack(spacing: 2) {
                        MeterView(level: { let r = app.core.lastSnapshot.decks[i]; return Double(max(r.peakL, r.peakR)) }).frame(width: 5, height: fader)
                        VFader(value: core.mixer.fader[i], color: Theme.deck[i], height: fader) { core.setMixer("fader", i, $0) }
                    }.frame(maxWidth: .infinity)
                }
            }
            crossfader
        }
        .padding(6)
        .frame(width: c.mixW, height: c.deckH)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    var crossfader: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raise).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Theme.fg).frame(width: 16, height: 26)
                    .offset(x: CGFloat(core.mixer.xfader) * (g.size.width - 16))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                core.mixer.xfader = min(1, max(0, Double((d.location.x - 8) / (g.size.width - 16))))
            })
            .onTapGesture(count: 2) { core.mixer.xfader = 0.5 }
        }.frame(height: 30)
    }
    func cue(_ i: Int) -> some View {
        Button { core.togglePfl(i) } label: {
            Text("CUE").font(.system(size: 11, weight: .heavy)).frame(maxWidth: .infinity, minHeight: c.btn).foregroundStyle(core.mixer.pfl[i] ? Color.black : Theme.deck[i])
                .background(RoundedRectangle(cornerRadius: 6).fill(core.mixer.pfl[i] ? Theme.cue : Theme.raise))
        }.buttonStyle(.plain)
    }
}

/// TRIM, HI, MID, LOW and CFX for the two channels on screen, big enough to turn with a thumb
struct CompactEQ: View {
    @EnvironmentObject var core: Core
    let channels: [Int]
    var body: some View {
        VStack(spacing: 14) {
            ForEach(channels, id: \.self) { i in
                HStack(spacing: 18) {
                    Text("\(i + 1)").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.deck[i]).frame(width: 24)
                    Knob(label: "TRIM", value: core.mixer.trim[i], color: Theme.deck[i], size: 40, bipolar: true) { core.setMixer("trim", i, $0) }
                    Knob(label: "HI", value: core.mixer.hi[i], color: Theme.deck[i], size: 40, bipolar: true) { core.setMixer("hi", i, $0) }
                    Knob(label: "MID", value: core.mixer.mid[i], color: Theme.deck[i], size: 40, bipolar: true) { core.setMixer("mid", i, $0) }
                    Knob(label: "LOW", value: core.mixer.low[i], color: Theme.deck[i], size: 40, bipolar: true) { core.setMixer("low", i, $0) }
                    Knob(label: "CFX", value: core.mixer.cfx[i], color: Theme.loop, size: 40, bipolar: true) { core.setMixer("cfx", i, $0) }
                }
            }
        }.padding()
    }
}

/// CI only: `-screen 568x320` draws the app in a frame that size (an SE with Display Zoom, which the simulator
/// can't turn on), and `-metrics YES` writes the device's real screen size, scale and safe area to
/// Documents/metrics.txt
enum ScreenOverride {
    static let size: CGSize? = {
        guard let s = UserDefaults.standard.string(forKey: "screen") else { return nil }
        let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }()
    static func writeMetrics() {
        guard UserDefaults.standard.bool(forKey: "metrics") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let env = ProcessInfo.processInfo.environment
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let win = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
            let sc = scene?.screen ?? UIScreen.main
            let i = win?.safeAreaInsets ?? .zero
            func f(_ v: CGFloat) -> String { String(format: "%g", Double(v)) }
            let size = win?.bounds.size ?? .zero
            let lines = [
                "device=\(env["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name)",
                "model=\(env["SIMULATOR_MODEL_IDENTIFIER"] ?? "?") os=\(UIDevice.current.systemVersion)",
                "points=\(f(sc.bounds.width))x\(f(sc.bounds.height)) scale=\(f(sc.scale)) native=\(f(sc.nativeBounds.width))x\(f(sc.nativeBounds.height)) nativeScale=\(f(sc.nativeScale))",
                "window=\(f(size.width))x\(f(size.height)) orientation=\(scene.map { $0.interfaceOrientation.rawValue } ?? 0)",
                "safe top=\(f(i.top)) left=\(f(i.left)) bottom=\(f(i.bottom)) right=\(f(i.right))",
                "layout=\(UIDevice.current.userInterfaceIdiom == .phone ? (PhoneScreen.autoCompactNow() ? "compact" : "standard") : "ipad")",
            ]
            let text = lines.joined(separator: "\n") + "\n"
            NSLog("METRICS %@", lines.joined(separator: " | "))
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? text.write(to: d.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}

/// wraps the app in the -screen frame, if there is one
struct ScreenFrame: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if let s = ScreenOverride.size {
            ZStack { Color.black.ignoresSafeArea(); content.frame(width: s.width, height: s.height).clipped() }
        } else { content }
    }
}
