import SwiftUI
import CrateboxKit

/// The master EQ: ON, a preset menu, and ten faders (31 Hz … 16 kHz, ±12 dB, half-dB steps). Double-tap a fader
/// to put that band back at 0. It shapes the whole mix (speakers and recording), after BEAT FX on MASTER.
struct MasterEQView: View {
    @EnvironmentObject var core: Core
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let eq = core.mixer.eq
        GeometryReader { g in
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text("MASTER EQ").font(.system(size: 14, weight: .heavy)).tracking(2)
                    LitButton(label: eq.on ? "ON" : "OFF", on: eq.on, color: Theme.accent) { core.setEQ(on: !eq.on) }
                        .accessibilityLabel("Master EQ \(eq.on ? "on" : "off")")
                    Menu {
                        ForEach(MasterEQ.presets, id: \.name) { p in
                            Button { core.setEQ(preset: p.name) } label: { if eq.preset == p.name { Label(p.name, systemImage: "checkmark") } else { Text(p.name) } }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(eq.preset ?? "Custom").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }.foregroundStyle(Theme.fg).padding(.horizontal, 10).frame(minWidth: 120, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
                    }
                    Spacer(minLength: 4)
                    Button("Done") { dismiss() }
                }
                // what's left of the sheet for the faders, between sensible limits
                let fh = max(90, min(240, g.size.height - 110))
                HStack(spacing: 0) {
                    ForEach(0..<MasterEQ.freqs.count, id: \.self) { b in
                        let db = eq.gains[b]
                        VStack(spacing: 3) {
                            Text(db == 0 ? "0" : String(format: "%+g", db)).font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(db == 0 ? Theme.muted : Theme.fg).lineLimit(1).minimumScaleFactor(0.7)
                            VFader(value: (db + MasterEQ.range) / (2 * MasterEQ.range), color: eq.on ? Theme.accent : Theme.dim, height: fh) {
                                core.setEQ(band: b, db: $0 * 2 * MasterEQ.range - MasterEQ.range)
                            }
                            .background(Rectangle().fill(Theme.line2).frame(height: 1))      // the 0 dB line
                            .onTapGesture(count: 2) { core.setEQ(band: b, db: 0) }
                            .accessibilityElement()
                            .accessibilityLabel("\(MasterEQ.labels[b]) hertz")
                            .accessibilityValue("\(String(format: "%+g", db)) decibels")
                            .accessibilityAdjustableAction { d in core.setEQ(band: b, db: db + (d == .increment ? 1 : -1)) }
                            Text(MasterEQ.labels[b]).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text(eq.on ? "Big boosts push the mix into the limiter: cutting what you don't want usually sounds cleaner." : "Off: the mix goes out untouched.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(12)
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Theme.bg)
        .presentationDetents([.large])
    }
}
