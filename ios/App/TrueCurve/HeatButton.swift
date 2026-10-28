import SwiftUI
import CrateboxKit

/// TrueCurve mini in the top bar: HEAT opens a small panel (device, curve, Start); once a curve starts the
/// panel closes and the button itself lights up and shows the bowl temperature and the time into the curve.
/// Only this view watches HeatController, so its ~5 updates a second don't redraw the decks.
struct HeatButton: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var heat = HeatController.shared
    @State private var open = false
    var body: some View {
        let lit = heat.phase == .preheat || heat.phase == .running || heat.phase == .hold
        Button { open = true } label: {
            Text(heat.label + " ▾").font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1)
                .frame(minHeight: 30).padding(.horizontal, 8)
                .foregroundStyle(lit ? Color.black : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 6).fill(lit ? Theme.cue : Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(lit ? Theme.cue : Theme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("TrueCurve heat: \(heat.label)")
        .popover(isPresented: $open, arrowEdge: .top) {
            HeatPanel { open = false }.presentationCompactAdaptation(.popover)
        }
        .onAppear {
            let a = app
            heat.onStatus = { [weak a] s in a?.status(s, 5) }
            // PUFF in Beat FX: on offer while a Puffco is connected, played by HOLD's temperature drop
            heat.onConnected = { [weak a] c in a?.core.fx.puffReady = c }
            heat.onPuff = { [weak a] v in a?.core.fx.setPuff(v) }
            // GLOW: the lantern follows the master level; the Beat FX LEVEL/DEPTH knob is its knob too
            heat.glowInput = { [weak a] in
                guard let a else { return (0, 0.5) }
                let p = a.core.lastSnapshot.masterPeak
                return (Double(max(p.0, p.1)), a.core.fx.depth)
            }
            heat.demo()
        }
    }
}

struct HeatPanel: View {
    @ObservedObject var heat = HeatController.shared
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("TrueCurve").font(.system(size: 15, weight: .bold))
                Text("heat curves for Peak Pro / Proxy").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 6) {
                Text(heat.devText).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if heat.connected {
                    Button("Disconnect") { heat.disconnect() }
                } else {
                    Button(heat.scanning ? "Looking…" : "Connect…") { heat.scan() }.disabled(heat.scanning)
                    Button("Simulator") { heat.useSimulator() }
                }
            }.buttonStyle(.bordered).controlSize(.small)
            if !heat.connected && !heat.found.isEmpty {
                ForEach(heat.found) { f in
                    Button { heat.pick(f) } label: { Label(f.name, systemImage: "flame").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if !heat.connected && heat.found.isEmpty && !heat.others.isEmpty && !heat.scanning {
                Text("Other devices nearby").font(.system(size: 11)).foregroundStyle(Theme.muted)
                ScrollView { VStack(spacing: 4) { ForEach(heat.others) { f in
                    Button { heat.pick(f) } label: { Text(f.name).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered).controlSize(.small)
                } } }.frame(maxHeight: 120)
            }
            HStack {
                Text("Curve").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Picker("Curve", selection: $heat.name) {
                    Section("Presets") { ForEach(heat.presetNames, id: \.self) { Text($0).tag($0) } }
                    if !heat.savedNames.isEmpty { Section("From TrueCurve") { ForEach(heat.savedNames, id: \.self) { Text($0).tag($0) } } }
                }.pickerStyle(.menu).disabled(heat.running)
                Spacer(minLength: 0)
            }
            Button {
                let starting = !heat.running
                heat.toggle()
                if starting && heat.running { close() }      // straight back to the decks
            } label: {
                Text(heat.running ? "Stop" : "Start curve").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).tint(heat.running ? Theme.hot : Theme.cue).foregroundStyle(Color.black)
            .disabled(!heat.connected || heat.phase == .prep || heat.phase == .hold)
            PuffHold(heat: heat, close: close)
            GlowRow(heat: heat)
            if !heat.msg.isEmpty { Text(heat.msg).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            Button("Paste curves from TrueCurve") { heat.paste() }.buttonStyle(.bordered).controlSize(.small)
            Text("Uses profile slot 4 while it runs and puts it back after. Close this and keep mixing: the button shows the bowl temperature.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 310)
        .onAppear { heat.panelOpen = true }
        .onDisappear { heat.panelOpen = false }
    }
}

/// HOLD for PUFF: one temperature, no curve; a draw drops the bowl temperature and Beat FX PUFF warbles with it
struct PuffHold: View {
    @ObservedObject var heat: HeatController
    let close: () -> Void
    @State private var hitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Stepper(value: $heat.holdF, in: TrueCurve.minF...TrueCurve.maxF, step: 5) {
                    Text("Hold \(Int(heat.holdF))°F").font(.system(size: 12)).monospacedDigit()
                }.disabled(heat.running)
            }
            HStack(spacing: 6) {
                Text("Full warble at").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Picker("Full warble at", selection: $heat.puffFull) {
                    Text("Auto").tag(0.0)
                    ForEach([4.0, 8, 15, 25, 40], id: \.self) { Text("\(Int($0))°F drop").tag($0) }
                }.pickerStyle(.menu).disabled(heat.running)
                Spacer(minLength: 0)
            }
            Button {
                let starting = !heat.running
                heat.toggleHold()
                if starting && heat.running { close() }
            } label: {
                Text(heat.phase == .hold ? "Stop HOLD" : "HOLD for PUFF").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).tint(heat.phase == .hold ? Theme.hot : Theme.loop).foregroundStyle(Color.black)
            .disabled(!heat.connected || heat.phase == .prep || (heat.running && heat.phase != .hold))
            if heat.phase == .hold {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.raise)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.hot).frame(width: g.size.width * heat.puff)
                    }
                }.frame(height: 8).accessibilityLabel("Hit strength \(Int(heat.puff * 100)) percent")
                if !heat.puffInfo.isEmpty { Text(heat.puffInfo).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted) }
                if heat.isSim {
                    // press and hold: a pretend draw
                    Text(hitting ? "Hitting…" : "Hold to hit (simulator)").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hitting ? Theme.hot : Theme.raise))
                        .onLongPressGesture(minimumDuration: 30, maximumDistance: 60, perform: {}, onPressingChanged: { p in hitting = p; heat.simHit(p ? 1 : 0) })
                }
            }
            Text("Beat FX → PUFF (shows while a Puffco is connected). It plays like a theremin: a harder hit drops the bowl temperature further, and the voice glides higher (up to two octaves) and louder over a tape warble. LEVEL caps it.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// GLOW: the Puffco's lantern as a slow rainbow that breathes with the music; the FX knob sets one thing about it
struct GlowRow: View {
    @ObservedObject var heat: HeatController
    var body: some View {
        HStack(spacing: 6) {
            Toggle("GLOW", isOn: $heat.glowOn).font(.system(size: 12, weight: .bold)).fixedSize()
                .accessibilityHint("The Puffco's lantern drifts through the rainbow and brightens with the music. Paused during a heat run")
            Text("FX knob sets").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Picker("FX knob sets", selection: $heat.glowKnob) {
                ForEach(TrueCurve.Glow.Knob.allCases, id: \.self) { k in Text(GlowRow.name(k)).tag(k) }
            }.pickerStyle(.menu).controlSize(.small)
            Spacer(minLength: 0)
            if heat.glowOn && heat.connected {
                let c = heat.glowShown
                Circle().fill(Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255))
                    .frame(width: 14, height: 14).overlay(Circle().stroke(Theme.line2, lineWidth: 1))
            }
        }
    }
    static func name(_ k: TrueCurve.Glow.Knob) -> String {
        switch k {
        case .intensity: return "brightness"
        case .speed: return "speed"
        case .sensitivity: return "sensitivity"
        case .off: return "nothing"
        }
    }
}
