// Deck Bridge's screen (the layout itself is BridgeScreen.swift, built like Performance Mode's), its momentary
// keys and jog, and the setup sheet: linking, the rekordbox mapping, deck options, the learn helper.
import SwiftUI
import CoreAudioKit
import CrateboxKit

struct DeckBridgeView: View {
    @ObservedObject var bridge: DeckBridge
    @State private var setup = false
    var body: some View {
        BridgeScreen(bridge: bridge, setup: $setup)
            .sheet(isPresented: $setup) { DeckBridgeSetup(bridge: bridge) }
            .onAppear { if !CommandLine.arguments.contains("-bridge") && !bridge.linked && bridge.sentCount == 0 && !UserDefaults.standard.bool(forKey: "cb.bridge.setupSeen") { UserDefaults.standard.set(true, forKey: "cb.bridge.setupSeen"); setup = true } }
    }
}

/// a momentary button: press and release go to rekordbox; lit by rekordbox's own light
struct BridgeKey: View {
    let label: String
    var lit = false
    var color: Color = Theme.accent
    var height: CGFloat = 34
    var big = false
    var radius: CGFloat = 7
    var fontSize: CGFloat? = nil
    var plain = false                   // a pad: no outline, like Performance Mode's pads
    var textColor: Color? = nil
    let press: (Bool) -> Void
    @State private var down = false
    var body: some View {
        Text(label).font(.system(size: fontSize ?? (big ? 15 : 11), weight: plain ? .semibold : .bold)).lineLimit(1).minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .foregroundStyle(lit ? Color.black : (textColor ?? Theme.fg))
            .background(RoundedRectangle(cornerRadius: radius).fill(lit ? color : Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(down ? color : (plain ? Color.clear : Theme.line2), lineWidth: down ? 2 : (plain ? 0 : 1)))
            .opacity(down && !lit ? 0.85 : 1)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; press(true); UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
                .onEnded { _ in down = false; press(false) })
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
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
                // the same platter as Performance Mode's JogView
                Circle().fill(Theme.raise).overlay(Circle().stroke(deck.jogTouched ? color : Theme.line2, lineWidth: 2))
                Circle().fill(Theme.panel).padding(g.size.width * 0.18)
                Rectangle().fill(color).frame(width: 3, height: g.size.width * 0.18).offset(y: -g.size.width * 0.38)
                    .rotationEffect(.degrees(deck.jogAngle))
                Text("\(deck.deck + 1)").font(.system(size: max(14, g.size.width * 0.12), weight: .heavy)).foregroundStyle(color.opacity(0.8))
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
