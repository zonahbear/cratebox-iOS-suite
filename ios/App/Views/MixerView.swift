import SwiftUI
import CrateboxKit

struct MixerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var fx: FxController
    var compact = false
    var phone = false
    var masterBar = false               // iPhone: just the master section, for the top bar
    @State private var fxSheet = false

    var order: [Int] { core.four ? [2, 0, 1, 3] : [0, 1] }

    var body: some View {
        if masterBar { phoneMaster } else if phone { phoneBody } else { fullBody }
    }
    /// iPhone: a club mixer, straight down: each channel's TRIM, HI, MID, LOW, CFX, CUE and fader in a column,
    /// the names between the two (4-deck mode: the channels of the decks each side plays). The master
    /// section (CUE/MST, MST, MASTER, FX) is in the bar along the top.
    var phoneBody: some View {
        let shown = core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]
        let k: CGFloat = 27
        return VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 2) {
                phoneStrip(shown[0], k)
                VStack(spacing: 3) {
                    ForEach(["TRIM", "HI", "MID", "LOW", "CFX"], id: \.self) { n in
                        Text(n).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted).frame(height: k)
                    }
                    Text("CUE").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted).frame(height: 22)
                }.frame(width: 26)
                phoneStrip(shown[1], k)
            }
            crossfader.frame(height: 24)
        }
        .padding(5)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    func phoneStrip(_ i: Int, _ k: CGFloat) -> some View {
        let c = Theme.deck[i]
        return VStack(spacing: 3) {
            Knob(label: "", value: core.mixer.trim[i], color: c, size: k) { core.setMixer("trim", i, $0) }
            Knob(label: "", value: core.mixer.hi[i], color: c, size: k) { core.setMixer("hi", i, $0) }
            Knob(label: "", value: core.mixer.mid[i], color: c, size: k) { core.setMixer("mid", i, $0) }
            Knob(label: "", value: core.mixer.low[i], color: c, size: k) { core.setMixer("low", i, $0) }
            Knob(label: "", value: core.mixer.cfx[i], color: Theme.loop, size: k) { core.setMixer("cfx", i, $0) }
            Button { core.togglePfl(i) } label: {
                Text("\(i + 1)").font(.system(size: 10, weight: .heavy)).frame(width: 40, height: 22).foregroundStyle(core.mixer.pfl[i] ? Color.black : c)
                    .background(RoundedRectangle(cornerRadius: 4).fill(core.mixer.pfl[i] ? Theme.cue : Theme.raise))
            }.buttonStyle(.plain)
            HStack(spacing: 2) {
                MeterView(level: { let r = app.core.lastSnapshot.decks[i]; return Double(max(r.peakL, r.peakR)) }).frame(width: 5, height: 62)
                VFader(value: core.mixer.fader[i], color: c, height: 62) { core.setMixer("fader", i, $0) }
            }
        }.frame(maxWidth: .infinity)
    }
    /// iPhone: the master section, for the bar along the top
    var phoneMaster: some View {
        HStack(spacing: 6) {
            Knob(label: "", value: core.mixer.headMix, size: 24, center: 0) { core.mixer.headMix = $0 }
            Button { core.toggleMasterCue() } label: {
                Text("MST CUE").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).frame(height: 24).foregroundStyle(core.mixer.masterCue ? Color.black : Theme.fg)
                    .background(RoundedRectangle(cornerRadius: 4).fill(core.mixer.masterCue ? Theme.cue : Theme.raise))
            }.buttonStyle(.plain)
            Knob(label: "", value: core.mixer.master, size: 24, center: 0.8) { core.mixer.master = $0 }
            MeterView(level: { let p = app.core.lastSnapshot.masterPeak; return Double(max(p.0, p.1)) }).frame(width: 5, height: 24)
            Button { fxSheet = true } label: {
                Text("FX").font(.system(size: 10, weight: .bold)).frame(width: 32, height: 24).foregroundStyle(fx.on ? Color.black : Theme.fg)
                    .background(RoundedRectangle(cornerRadius: 4).fill(fx.on ? Theme.hot : Theme.raise))
            }.buttonStyle(.plain)
        }
        .sheet(isPresented: $fxSheet) { BeatFXView().padding().presentationDetents([.height(220)]) }
    }
    var fullBody: some View {
        VStack(spacing: 8) {
            if core.four { layers }
            HStack(alignment: .top, spacing: 6) {
                ForEach(order, id: \.self) { i in strip(i) }
            }
            HStack(spacing: 10) {
                Knob(label: "Cue/Mst", value: core.mixer.headMix, size: 28, center: 0) { core.mixer.headMix = $0 }
                LitButton(label: "MST", on: core.mixer.masterCue, color: Theme.cue) { core.toggleMasterCue() }
                Knob(label: "Master", value: core.mixer.master, size: 28, center: 0.8) { core.mixer.master = $0 }
                MeterView(level: { let p = app.core.lastSnapshot.masterPeak; return Double(max(p.0, p.1)) }).frame(width: 8, height: 40)
            }
            crossfader
            BeatFXView()
        }
        .padding(8)
        .frame(width: core.four ? 300 : 210)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    var layers: some View {
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { d in
                let on = app.midi.side[d % 2] == d
                Button { app.midi.setSide(d % 2, d); app.objectWillChange.send() } label: {
                    Text("\(d + 1)").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(on ? Color.black : Theme.deck[d])
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.deck[d] : Theme.raise))
                }.buttonStyle(.plain)
            }
        }
    }

    func strip(_ i: Int) -> some View {
        let c = Theme.deck[i]
        return VStack(spacing: 5) {
            Knob(label: "Trim", value: core.mixer.trim[i], color: c, size: compact ? 24 : 28) { core.setMixer("trim", i, $0) }
            Knob(label: "Hi", value: core.mixer.hi[i], color: c, size: compact ? 24 : 28) { core.setMixer("hi", i, $0) }
            Knob(label: "Mid", value: core.mixer.mid[i], color: c, size: compact ? 24 : 28) { core.setMixer("mid", i, $0) }
            Knob(label: "Low", value: core.mixer.low[i], color: c, size: compact ? 24 : 28) { core.setMixer("low", i, $0) }
            Knob(label: "CFX", value: core.mixer.cfx[i], color: Theme.loop, size: compact ? 24 : 28) { core.setMixer("cfx", i, $0) }
            LitButton(label: "CUE", on: core.mixer.pfl[i], color: Theme.cue) { core.togglePfl(i) }
            HStack(spacing: 2) {
                MeterView(level: { let r = app.core.lastSnapshot.decks[i]; return Double(max(r.peakL, r.peakR)) }).frame(width: 6, height: compact ? 90 : 110)
                VFader(value: core.mixer.fader[i], color: c, height: compact ? 90 : 110) { core.setMixer("fader", i, $0) }
            }
            Text("CH \(i + 1)").font(.system(size: 9)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity)
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
}

/// A peak meter (dB scale, -48...0)
struct MeterView: View {
    let level: () -> Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            Canvas { ctx, size in
                let p = level(), db = p <= 0 ? -60 : 20 * log10(p)
                let v = max(0, min(1, (db + 48) / 48))
                let H = Double(size.height)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height)), with: .color(Theme.raise))
                let col: Color = db > -1 ? Theme.hot : db > -9 ? Theme.cue : Theme.ok
                ctx.fill(Path(CGRect(x: 0, y: H * (1 - v), width: Double(size.width), height: H * v)), with: .color(col))
            }
        }
    }
}

/// BEAT FX: effect, BEAT ◀ ▶, channel (1 2 [3 4] MASTER), LEVEL/DEPTH, ON
struct BeatFXView: View {
    @EnvironmentObject var core: Core
    @EnvironmentObject var fx: FxController
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(0..<FX_LIST.count, id: \.self) { k in Button(FX_LIST[k].0.rawValue) { fx.select(FX_LIST[k].0) } }
                } label: {
                    Text(fx.fx.rawValue).font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
                }
                if fx.spec.beats != nil {
                    LitButton(label: "◀") { fx.beatStep(-1) }
                    Text(fracText(fx.beat)).font(.system(size: 12, design: .monospaced)).frame(width: 34)
                    LitButton(label: "▶") { fx.beatStep(1) }
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<(core.four ? 4 : 2), id: \.self) { c in LitButton(label: "\(c + 1)", on: fx.ch == c, color: Theme.deck[c]) { fx.channel(c) } }
                LitButton(label: "M", on: fx.ch == 4, color: Theme.fg) { fx.channel(4) }
            }
            HStack(spacing: 8) {
                Knob(label: "Level", value: fx.depth, color: Theme.loop, size: 28, center: fx.spec.depth) { fx.setDepth($0) }
                LitButton(label: "FX ON", on: fx.on, color: Theme.hot, wide: true) { fx.setOn(!fx.on) }
            }
        }
    }
}
