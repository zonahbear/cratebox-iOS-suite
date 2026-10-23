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
                    ForEach([15.0, 25, 40, 60, 80], id: \.self) { Text("\(Int($0))°F drop").tag($0) }
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
                if heat.isSim {
                    // press and hold: a pretend draw
                    Text(hitting ? "Hitting…" : "Hold to hit (simulator)").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hitting ? Theme.hot : Theme.raise))
                        .onLongPressGesture(minimumDuration: 30, maximumDistance: 60, perform: {}, onPressingChanged: { p in hitting = p; heat.simHit(p ? 1 : 0) })
                }
            }
            Text("Beat FX → PUFF (shows while a Puffco is connected). A harder hit drops the bowl temperature further, and the warble gets deeper and faster. LEVEL caps it.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
