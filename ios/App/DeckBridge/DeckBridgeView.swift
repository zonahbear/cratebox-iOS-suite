// Deck Bridge's screen: landscape, two decks around a mixer, every control big enough for a thumb.
// Left deck: jog, CUE / PLAY, pads, loops, tempo on the outside edge. Right deck mirrored. Middle: each
// channel's trim, EQ, filter, CUE and fader, the crossfader, Beat FX.
import SwiftUI
import CoreAudioKit
import CrateboxKit

struct DeckBridgeView: View {
    @ObservedObject var bridge: DeckBridge
    @State private var setup = false
    var body: some View {
        VStack(spacing: 4) {
            ModeBar(title: "DECK BRIDGE", subtitle: "rekordbox decks \(bridge.sides[0].deck + 1) and \(bridge.sides[1].deck + 1)") {
                linkPill
                Picker("", selection: $bridge.pair) { Text("1 · 2").tag(0); Text("3 · 4").tag(1) }.pickerStyle(.segmented).frame(width: 110)
                LitButton(label: "SHIFT", on: bridge.shift, color: Theme.accent) { bridge.shift.toggle() }
                Button { setup = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.buttonStyle(.plain)
            }
            GeometryReader { g in
                let mixW = min(230, max(170, g.size.width * 0.24))
                HStack(spacing: 6) {
                    BridgeDeckPanel(bridge: bridge, deck: bridge.sides[0], side: 0)
                    BridgeMixer(bridge: bridge, a: bridge.sides[0], b: bridge.sides[1]).frame(width: mixW)
                    BridgeDeckPanel(bridge: bridge, deck: bridge.sides[1], side: 1)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 4)
        }
        .background(Theme.bg)
        .sheet(isPresented: $setup) { DeckBridgeSetup(bridge: bridge) }
        .onAppear { if !CommandLine.arguments.contains("-bridge") && !bridge.linked && bridge.sentCount == 0 && !UserDefaults.standard.bool(forKey: "cb.bridge.setupSeen") { UserDefaults.standard.set(true, forKey: "cb.bridge.setupSeen"); setup = true } }
    }
    var linkPill: some View {
        HStack(spacing: 5) {
            Circle().fill(bridge.heardRecently ? Theme.ok : bridge.confirmed ? Theme.accent : bridge.linked ? Theme.warn : Theme.dim).frame(width: 7, height: 7)
            Text(bridge.heardRecently ? "rekordbox linked" : bridge.confirmed ? "Linked" : bridge.linked ? "Sending" : "Not linked").font(.system(size: 11)).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 26).background(Capsule().fill(Theme.raise))
        .onTapGesture { setup = true }
    }
}

/// a momentary button: press and release go to rekordbox; lit by rekordbox's own light
struct BridgeKey: View {
    let label: String
    var lit = false
    var color: Color = Theme.accent
    var height: CGFloat = 34
    var big = false
    let press: (Bool) -> Void
    @State private var down = false
    var body: some View {
        Text(label).font(.system(size: big ? 15 : 11, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .foregroundStyle(lit ? Color.black : (down ? color : Theme.fg))
            .background(RoundedRectangle(cornerRadius: 7).fill(lit ? color : Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(down ? color : Theme.line2, lineWidth: down ? 2 : 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; press(true); UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
                .onEnded { _ in down = false; press(false) })
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

struct BridgeDeckPanel: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var deck: BridgeDeckState
    let side: Int
    var color: Color { Theme.deck[deck.deck] }
    var body: some View {
        GeometryReader { g in
            let tempoW: CGFloat = 40
            let jog = max(110, min(g.size.height * 0.58, (g.size.width - tempoW) * 0.5))
            HStack(spacing: 6) {
                if side == 0 { tempo.frame(width: tempoW) }
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("\(deck.deck + 1)").font(.system(size: 18, weight: .heavy)).foregroundStyle(Color.black).frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(color))
                        key("SYNC", .sync); key("MT", .keylock); key("Q", .quantize); key("SLIP", .slip)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        VStack(spacing: 6) {
                            BridgeJog(bridge: bridge, deck: deck, side: side, color: color).frame(width: jog, height: jog)
                            HStack(spacing: 6) {
                                BridgeKey(label: "CUE", lit: deck.cueLit, color: Theme.cue, height: 46, big: true) { on in
                                    bridge.button(bridge.shift ? .jumpToStart : .cue, side: side, on: on)
                                }
                                BridgeKey(label: "▶︎ ‖", lit: deck.playing, color: Theme.ok, height: 46, big: true) { bridge.button(.playPause, side: side, on: $0) }
                            }.frame(width: jog)
                        }
                        VStack(spacing: 6) {
                            pads
                            loops
                        }
                    }
                }
                if side == 1 { tempo.frame(width: tempoW) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
    }
    func key(_ l: String, _ c: BridgeControl) -> some View {
        BridgeKey(label: l, lit: deck.lit(c), color: c == .sync ? Theme.accent : Theme.fg, height: 28) { bridge.button(c, side: side, on: $0) }
    }
    var pads: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(bridge.shift ? "HOT CUE · DELETE" : "HOT CUE").font(.system(size: 9, weight: .bold)).foregroundStyle(bridge.shift ? Theme.hot : Theme.muted)
                Spacer()
                Button { bridge.button(.hotCueMode, side: side, on: true); bridge.button(.hotCueMode, side: side, on: false) } label: {
                    Text("MODE").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain)
            }
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { c in
                        let k = r * 4 + c
                        BridgeKey(label: String(UnicodeScalar(65 + k)!), lit: deck.hot[k], color: Theme.hot, height: 40, big: true) { bridge.hotCue(k, side: side, on: $0) }
                    }
                }
            }
        }
    }
    var loops: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                BridgeKey(label: "IN", lit: deck.loopIn, color: Theme.loop) { bridge.button(.loopIn, side: side, on: $0) }
                BridgeKey(label: "OUT", lit: deck.loopOut, color: Theme.loop) { bridge.button(.loopOut, side: side, on: $0) }
                BridgeKey(label: "RELOOP", lit: deck.reloop, color: Theme.loop) { bridge.button(.reloopExit, side: side, on: $0) }
            }
            HStack(spacing: 5) {
                BridgeKey(label: "½") { bridge.button(.loopHalf, side: side, on: $0) }
                BridgeKey(label: "4 BEAT", lit: deck.autoLoop, color: Theme.loop) { bridge.button(.autoLoop, side: side, on: $0) }
                BridgeKey(label: "×2") { bridge.button(.loopDouble, side: side, on: $0) }
            }
        }
    }
    var tempo: some View {
        VStack(spacing: 4) {
            Text("TEMPO").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
            Text("−").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
            // like a CDJ: up = slower
            GeometryReader { g in
                VFader(value: 1 - deck.tempo, color: color, height: g.size.height) { bridge.value(.tempo, side: side, 1 - $0) }
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().fill(Theme.line2).frame(height: 1))
            }
            Text("+").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
            Button { bridge.value(.tempo, side: side, 0.5) } label: { Text("0").font(.system(size: 10, weight: .bold)).frame(width: 30, height: 22).background(Capsule().fill(Theme.raise)) }.buttonStyle(.plain)
        }
    }
}

/// The platter: the middle scratches (with touch), the outer ring bends the pitch, like a CDJ
struct BridgeJog: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var deck: BridgeDeckState
    let side: Int
    let color: Color
    @State private var last: Double?
    @State private var edge = false
    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                Circle().fill(Theme.raise).overlay(Circle().stroke(deck.jogTouched ? Theme.accent : Theme.line2, lineWidth: deck.jogTouched ? 3 : 2))
                Circle().fill(Theme.panel).padding(r * 0.2)
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1).padding(r * 0.2))
                Rectangle().fill(color).frame(width: 4, height: r * 0.3).offset(y: -r * 0.62)
                    .rotationEffect(.degrees(deck.jogAngle))
                Text("JOG").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = Double(v.location.x - c.x), dy = Double(v.location.y - c.y)
                    let a = atan2(dy, dx) * 180 / .pi
                    if let l = last {
                        var da = a - l
                        if da > 180 { da -= 360 }
                        if da < -180 { da += 360 }
                        bridge.jog(side: side, degrees: da, edge: edge)
                    } else {
                        // where the finger lands decides: the top scratches (touch), the outer ring bends
                        edge = sqrt(dx * dx + dy * dy) > Double(r) * 0.8
                        if !edge { bridge.jogTouch(side: side, true) }
                    }
                    last = a
                }
                .onEnded { _ in
                    if !edge { bridge.jogTouch(side: side, false) }
                    last = nil
                })
        }
        .accessibilityLabel("Jog wheel, deck \(deck.deck + 1)")
    }
}

struct BridgeMixer: View {
    @ObservedObject var bridge: DeckBridge
    @ObservedObject var a: BridgeDeckState
    @ObservedObject var b: BridgeDeckState
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                channel(a, 0)
                VStack(spacing: 6) {
                    Text("FX").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.hot)
                    Knob(label: "DEPTH", value: bridge.fxDepth, color: Theme.hot, size: 34) { bridge.setFxDepth($0) }
                    BridgeKey(label: "ON", lit: bridge.fxOn, color: Theme.hot, height: 28) { bridge.global(.fxOn, on: $0) }
                    BridgeKey(label: "SELECT", height: 24) { bridge.global(.fxSelect, on: $0) }
                    HStack(spacing: 3) {
                        BridgeKey(label: "◀", height: 24) { bridge.global(.fxBeatDown, on: $0) }
                        BridgeKey(label: "▶", height: 24) { bridge.global(.fxBeatUp, on: $0) }
                    }
                    Spacer(minLength: 0)
                    Text("BROWSE").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                    HStack(spacing: 3) {
                        BridgeKey(label: "▲", height: 26) { if $0 { bridge.browse(-1) } }
                        BridgeKey(label: "▼", height: 26) { if $0 { bridge.browse(1) } }
                    }
                    BridgeKey(label: "BACK", height: 22) { bridge.global(.back, on: $0) }
                }.frame(width: 62)
                channel(b, 1)
            }
            HFader(value: bridge.xfader) { bridge.setXfader($0) }.frame(height: 30)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    func channel(_ d: BridgeDeckState, _ side: Int) -> some View {
        VStack(spacing: 4) {
            BridgeKey(label: "LOAD", height: 22) { if $0 { bridge.load(side: side) } }
            Knob(label: "TRIM", value: d.trim, size: 26, bipolar: true) { bridge.value(.trim, side: side, $0) }
            Knob(label: "HI", value: d.hi, size: 26, bipolar: true) { bridge.value(.eqHigh, side: side, $0) }
            Knob(label: "MID", value: d.mid, size: 26, bipolar: true) { bridge.value(.eqMid, side: side, $0) }
            Knob(label: "LOW", value: d.low, size: 26, bipolar: true) { bridge.value(.eqLow, side: side, $0) }
            Knob(label: "FILTER", value: d.filter, color: Theme.accent, size: 26, bipolar: true) { bridge.value(.filter, side: side, $0) }
            HStack(spacing: 3) {
                BridgeKey(label: "CUE", lit: d.headphoneCue, color: Theme.cue, height: 22) { bridge.button(.headphoneCue, side: side, on: $0) }
                BridgeKey(label: "FX", lit: bridge.fxAssign[d.deck], color: Theme.hot, height: 22) { if $0 { bridge.toggleFxAssign(side: side) } }
            }
            GeometryReader { g in VFader(value: d.fader, color: Theme.deck[d.deck], height: g.size.height) { bridge.value(.channelFader, side: side, $0) }.frame(maxWidth: .infinity) }
                .frame(minHeight: 60)
        }
        .frame(maxWidth: .infinity)
    }
}

/// a horizontal fader (the crossfader); double-tap centres it
struct HFader: View {
    let value: Double
    let set: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raise).frame(height: 6)
                Rectangle().fill(Theme.line2).frame(width: 1, height: 14).offset(x: w / 2)
                RoundedRectangle(cornerRadius: 3).fill(Theme.fg).frame(width: 16, height: 26).offset(x: CGFloat(value) * (w - 16))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in set(min(1, max(0, Double((d.location.x - 8) / max(1, w - 16))))) })
            .onTapGesture(count: 2) { set(0.5) }
        }
        .accessibilityLabel("Crossfader")
    }
}

/// Linking, the rekordbox mapping, deck options, and a learn helper for anything rekordbox doesn't take from the file
struct DeckBridgeSetup: View {
    @ObservedObject var bridge: DeckBridge
    @Environment(\.dismiss) var dismiss
    @State private var shared: URL?
    @State private var bluetooth = false
    let learnable: [(String, BridgeControl)] = [("PLAY", .playPause), ("CUE", .cue), ("SYNC", .sync), ("Loop in", .loopIn), ("Loop out", .loopOut),
                                                 ("Jog touch", .jogTouch), ("Channel fader", .channelFader), ("Tempo", .tempo), ("Filter", .filter)]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Network MIDI (Wi-Fi)", isOn: $bridge.networkOn)
                    LabeledContent("Status", value: bridge.status)
                    Button("Bluetooth MIDI…") { bluetooth = true }
                } header: { Text("Link to the computer running rekordbox") } footer: {
                    Text("Windows: install rtpMIDI (tobias-erichsen.de) first: without it Windows can't see this phone, over Wi-Fi or a cable. In rtpMIDI add an enabled session, then select this phone under Directory and press Connect. For a cable, plug in and turn on Personal Hotspot; rtpMIDI connects over it the same way. Mac: nothing to install. Audio MIDI Setup → Window → Show MIDI Studio → Network: find this phone under Directory and press Connect (or with a cable: Show Audio Devices → Enable under the iPhone).")
                }
                Section {
                    Button("Share the rekordbox mapping file…") { shared = bridge.writeMapping() }
                } header: { Text("rekordbox") } footer: {
                    Text("In rekordbox (Performance mode): MIDI (top right) → pick the network session / Deck Bridge in the device list → IMPORT → the file. Done: decks \(bridge.sides[0].deck + 1) and \(bridge.sides[1].deck + 1) follow this screen. The file is also in Files → On My iPhone → Cratebox → Deck Bridge. If rekordbox doesn't take a row from the file (jog wheels on some versions), use the learn helper below with MIDI LEARN.")
                }
                Section("Decks") {
                    Picker("Controls rekordbox decks", selection: $bridge.pair) { Text("1 and 2").tag(0); Text("3 and 4").tag(1) }
                    Toggle("Tempo fader: up = faster", isOn: $bridge.invertTempo)
                    Picker("Jog sensitivity", selection: $bridge.jogSensitivity) { ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { Text("\(String($0))×").tag($0) } }
                }
                Section {
                    ForEach(0..<2, id: \.self) { s in
                        ForEach(learnable.indices, id: \.self) { i in
                            let l = learnable[i]
                            Button("Send \(l.0), deck \(bridge.sides[s].deck + 1)") {
                                switch l.1 {
                                case .channelFader, .tempo, .filter: bridge.value(l.1, side: s, 1); bridge.value(l.1, side: s, 0.5)
                                default: bridge.button(l.1, side: s, on: true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { bridge.button(l.1, side: s, on: false) }
                                }
                            }
                        }
                    }
                    Button("Send jog (scratch), deck \(bridge.sides[0].deck + 1)") { bridge.jogTouch(side: 0, true); bridge.jog(side: 0, degrees: 20, edge: false); bridge.jogTouch(side: 0, false) }
                } header: { Text("Learn helper") } footer: { Text("In rekordbox's MIDI window press LEARN on a function, then tap Send here. Messages sent: \(bridge.sentCount).") }
            }
            .navigationTitle("Deck Bridge setup")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: Binding(get: { shared.map { Shared(url: $0) } }, set: { shared = $0?.url })) { s in ShareSheet(items: [s.url]) }
            .sheet(isPresented: $bluetooth) { BluetoothMIDIPeripheral().ignoresSafeArea() }
        }
    }
}

/// iOS's own Bluetooth LE MIDI advertising screen
struct BluetoothMIDIPeripheral: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CABTMIDILocalPeripheralViewController()
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        return nav
    }
    func updateUIViewController(_ c: UINavigationController, context: Context) {}
}
