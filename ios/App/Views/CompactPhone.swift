import SwiftUI
import UIKit
import CrateboxKit

/// Touch mode (was the compact layout), for playing on the glass with no controller: an SE (no island, so edge
/// strips only cost width), a phone with Display Zoom on (an SE becomes 568 × 320 pt), or any phone with
/// Settings → Look → Touch mode. No edge strips: each deck shows one face at a time, PLAY (the platter over CUE,
/// PLAY, SYNC, tempo on the outside) or PADS (pad mode, loop, 8 pads), so its buttons can be full size (44 pt,
/// Apple's minimum touch target). The deck's ⋯ holds range, TAP, GRID, MT and Q; the top bar's ⋯ holds WAVE,
/// DECKS, BEAT FX, REC, TRIM and CFX, and Settings. The mixer is a big HI / MID / LOW column per channel beside
/// its fader (a tap cuts a centred knob, or puts a turned one back), with the crossfader under them; no
/// headphone CUE, since that's a controller's job.
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
        // sizes from docs/device-sizes.md: 568 × 320 (SE, Display Zoom) → 47 pt EQ knobs, 667 × 375 (SE) → 57
        let face: CGFloat = size.height < 340 ? 160 : size.height < 400 ? 190 : 210
        let k = CompactMetrics.knob(face: face)
        let mixW = 2 * k + 98
        let c = CompactMetrics(deckW: ((w - mixW - 8) / 2).rounded(.down), mixW: mixW, face: face, knob: k)
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
                                    HStack(spacing: 4) { ForEach(core.activeDecks.filter { $0 != l && $0 != r }, id: \.self) { i in PhoneLane(deck: core.decks[i], active: false) } }
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
    let deckW: CGFloat, mixW: CGFloat, face: CGFloat, knob: CGFloat
    let header: CGFloat = 32, btn: CGFloat = 44, faderW: CGFloat = 22
    /// the platter: the face above the CUE / PLAY / SYNC row, beside the tempo fader
    var jog: CGFloat { max(64, min(face - btn - 4, deckW - 12 - faderW - 4)) }
    var deckH: CGFloat { header + 5 + face + 12 }
    /// the mixer's EQ knobs: three stacked in what's left above the crossfader (44 pt), at most 60 pt
    var eqH: CGFloat { deckH - 12 - btn - 4 }
    static func knob(face: CGFloat) -> CGFloat { min(60, ((32 + 5 + face - 44 - 4 - 8) / 3).rounded(.down)) }
}

/// the top bar: mode, MIX / LIBRARY, status, MASTER, and ⋯ for the rest
struct CompactTopBar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var fx: FxController
    @EnvironmentObject var rec: Recorder
    @Binding var settings: Bool
    @State private var fxSheet = false
    @State private var trimSheet = false
    var body: some View {
        HStack(spacing: 6) {
            ModeSwitcher(compact: true)
            Picker("", selection: $app.tab) { Text("MIX").tag(0); Text("LIBRARY").tag(1) }.pickerStyle(.segmented).frame(width: 132)
            Text(rec.recording ? String(format: "● REC %d:%02d", Int(rec.seconds) / 60, Int(rec.seconds) % 60) : app.statusText)
                .font(.system(size: 11, weight: rec.recording ? .bold : .regular)).foregroundStyle(rec.recording ? Theme.hot : Theme.muted)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            HeatButton()
            MasterButton()
            DriveEjectButton()
            Menu {
                Toggle("Waveforms (WAVE)", isOn: Binding(get: { app.waveMode }, set: { v in withAnimation(.easeInOut(duration: 0.2)) { app.waveMode = v } }))
                Picker("Decks", selection: Binding(get: { core.deckCount }, set: { app.setDecks($0) })) {
                    Text("2 decks").tag(2); Text("3 decks").tag(3); Text("4 decks").tag(4)
                }
                Button { fxSheet = true } label: { Label("Beat FX: \(fx.fx.rawValue)\(fx.on ? " (on)" : "")", systemImage: "sparkles") }
                Button { rec.recording ? rec.stop(app.audio.engine) : rec.start(app.audio.engine) } label: {
                    Label(rec.recording ? "Stop recording" : "Record the mix", systemImage: rec.recording ? "stop.circle" : "record.circle")
                }
                Button { trimSheet = true } label: { Label("Trim & filter…", systemImage: "slider.horizontal.3") }
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise))
                    .overlay(alignment: .topTrailing) { if rec.recording || fx.on { Circle().fill(Theme.hot).frame(width: 8, height: 8).offset(x: 2, y: -2) } }
                    .accessibilityLabel("More")
            }
            .sheet(isPresented: $fxSheet) { BeatFXView().padding().presentationDetents([.height(220)]) }
            .sheet(isPresented: $trimSheet) {
                CompactEQ(channels: core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]).presentationDetents([.height(220)])
            }
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
        Group {
            if app.scratch.contains(deck.i) {
                ScratchView(deck: deck, side: side, height: c.header + 5 + c.face, colW: 64, stacked: true)
            } else { player }
        }
        .padding(6)
        .frame(width: c.deckW)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.core.four ? color.opacity(0.7) : Theme.line, lineWidth: 1))
        .onAppear { if side == 1 && CommandLine.arguments.contains("-pads") { pads = true } }   // CI screenshots of the PADS face
    }
    var player: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                if app.core.four && (side == 0 || app.core.deckCount == 4) {
                    // 4 decks: the number swaps this side between its two decks (1 ⇄ 3, 2 ⇄ 4); 3 decks: the left side only
                    Button { let o = deck.i < 2 ? deck.i + 2 : deck.i - 2; app.midi.setSide(side, o); app.objectWillChange.send() } label: {
                        Text("\(deck.i + 1)⇄\(deck.i < 2 ? deck.i + 3 : deck.i - 1)").font(.system(size: 12, weight: .heavy)).frame(width: 44, height: c.header)
                            .foregroundStyle(Color.black).background(RoundedRectangle(cornerRadius: 6).fill(color))
                    }.buttonStyle(.plain)
                }
                face("PLAY", !pads) { pads = false }
                face("PADS", pads) { pads = true }
                // SCRATCH: here when there's room (no 1⇄3 button), always in the ⋯ tools
                if !(app.core.four && (side == 0 || app.core.deckCount == 4)) {
                    Button { _ = app.scratch.insert(deck.i) } label: {
                        Text("SCR").font(.system(size: 11, weight: .heavy)).frame(width: 40, height: c.header).foregroundStyle(color)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
                    }.buttonStyle(.plain).accessibilityLabel("Scratch deck \(deck.i + 1)")
                }
                Button { tools = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).frame(width: 40, height: c.header)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
                }.buttonStyle(.plain).accessibilityLabel("Deck \(deck.i + 1) tools")
                .popover(isPresented: $tools, arrowEdge: .top) { toolPanel.presentationCompactAdaptation(.popover) }
            }
            Group { if pads { padFace } else { playFace } }.frame(height: c.face)
        }
    }
    func face(_ s: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: 12, weight: .heavy)).frame(maxWidth: .infinity, minHeight: c.header)
                .foregroundStyle(on ? Color.black : Theme.muted)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : Theme.raise))
        }.buttonStyle(.plain)
    }
    /// tempo fader on the outside; the platter as big as the deck allows, over CUE / PLAY / SYNC
    var playFace: some View {
        HStack(spacing: 4) {
            if side == 0 { TempoFader(deck: deck).frame(width: c.faderW) }
            VStack(spacing: 4) {
                JogView(deck: deck, color: color).frame(width: c.jog, height: c.jog).frame(maxWidth: .infinity, maxHeight: .infinity)
                transport
            }
            if side == 1 { TempoFader(deck: deck).frame(width: c.faderW) }
        }
    }
    var transport: some View {
        HStack(spacing: 4) {
            HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                Text("CUE").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity, minHeight: c.btn, maxHeight: c.btn)
                    .background(Capsule().fill(Theme.raise)).overlay(Capsule().stroke(Theme.cue, lineWidth: 2))
            }
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: c.btn, maxHeight: c.btn)
                    .background(Capsule().fill(deck.playing ? Theme.ok.opacity(0.25) : Theme.raise)).overlay(Capsule().stroke(Theme.ok, lineWidth: 2))
            }.buttonStyle(.plain)
            Button { deck.syncPressed() } label: {
                Text("SYNC").font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity, minHeight: c.btn, maxHeight: c.btn)
                    .foregroundStyle(deck.sync ? Color.black : Theme.fg)
                    .background(RoundedRectangle(cornerRadius: 8).fill(deck.sync ? color : Theme.raise))
            }.buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in deck.makeMaster() })
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
                .foregroundStyle(on ? Color.black : Theme.fg)
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
            HStack(spacing: 8) {
                tool("SCRATCH", false) { tools = false; _ = app.scratch.insert(deck.i) }
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

/// the touch mixer: per channel a HI / MID / LOW column on the outside of its fader (a tap on a centred knob cuts
/// it, a tap on a turned or cut one puts it back at the centre), the crossfader across the bottom. No CUE.
struct CompactMixer: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    let c: CompactMetrics
    var body: some View {
        let sh = core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                eq(sh[0])
                ForEach(sh, id: \.self) { i in
                    HStack(spacing: 2) {
                        MeterView(level: { let r = app.core.lastSnapshot.decks[i]; return Double(max(r.peakL, r.peakR)) }).frame(width: 5, height: c.eqH)
                        VFader(value: core.mixer.fader[i], color: Theme.deck[i], height: c.eqH) { core.setMixer("fader", i, $0) }.frame(width: 30)
                    }.frame(maxWidth: .infinity)
                }
                eq(sh[1])
            }.frame(height: c.eqH)
            crossfader
        }
        .padding(6)
        .frame(width: c.mixW, height: c.deckH)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    func eq(_ i: Int) -> some View {
        VStack(spacing: 0) {
            band(i, "HI", "hi", core.mixer.hi[i]); Spacer(minLength: 0)
            band(i, "MID", "mid", core.mixer.mid[i]); Spacer(minLength: 0)
            band(i, "LOW", "low", core.mixer.low[i])
        }.frame(width: c.knob)
    }
    func band(_ i: Int, _ name: String, _ key: String, _ v: Double) -> some View {
        let cut = v < 0.01
        return Knob(label: "", value: v, color: cut ? Theme.hot : Theme.deck[i], size: c.knob, bipolar: true, tap: MixerCurves.eqTap) { core.setMixer(key, i, $0) }
            .overlay { if cut { Circle().stroke(Theme.hot, lineWidth: 2).allowsHitTesting(false) } }
            .overlay {
                Text(cut ? "CUT" : name).font(.system(size: (c.knob * 0.22).rounded(), weight: .heavy))
                    .foregroundStyle(cut ? Theme.hot : Theme.fg).offset(y: c.knob * 0.2).allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Channel \(i + 1) \(name)\(cut ? ", cut" : "")")
            .accessibilityHint("Tap to cut or put back at the centre, drag up or down to turn")
    }
    var crossfader: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raise).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Theme.fg).frame(width: 18, height: 30)
                    .offset(x: CGFloat(core.mixer.xfader) * (g.size.width - 18))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .faderDrag(core.mixer.xfader, span: g.size.width - 18) { core.mixer.xfader = $0 }
            .onTapGesture(count: 2) { core.mixer.xfader = 0.5 }
        }.frame(height: c.btn)
    }
}

/// TRIM and CFX (the filter) for the two channels on screen, from the top bar's ⋯, big enough for a thumb
struct CompactEQ: View {
    @EnvironmentObject var core: Core
    let channels: [Int]
    var body: some View {
        VStack(spacing: 14) {
            ForEach(channels, id: \.self) { i in
                HStack(spacing: 24) {
                    Text("\(i + 1)").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.deck[i]).frame(width: 24)
                    Knob(label: "TRIM", value: core.mixer.trim[i], color: Theme.deck[i], size: 48, bipolar: true) { core.setMixer("trim", i, $0) }
                    Knob(label: "CFX", value: core.mixer.cfx[i], color: Theme.loop, size: 48, bipolar: true) { core.setMixer("cfx", i, $0) }
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
