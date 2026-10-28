import SwiftUI
import CrateboxKit

struct MixerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @EnvironmentObject var fx: FxController
    var compact = false
    var phone = false
    var masterBar = false               // iPhone: just the master section, for the top bar
    var short = false                   // a short iPad (mini): BEAT FX behind a button instead of in the column
    @State private var fxSheet = false
    @Environment(\.phoneMetrics) var m

    var order: [Int] { [[0, 1], [2, 0, 1], [2, 0, 1, 3]][core.deckCount - 2] }

    var body: some View {
        if masterBar { phoneMaster } else if phone { phoneBody } else { fullBody }
    }
    /// iPhone: a club mixer, straight down: each channel's TRIM, HI, MID, LOW, CFX, CUE and fader in a column,
    /// the names between the two (4-deck mode: the channels of the decks each side plays). The master
    /// section (CUE/MST, MST, MASTER, FX) is in the bar along the top.
    var phoneBody: some View {
        let sh = core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]
        let k = m.knob
        let names: [(String, String)] = [("TRIM", "trim"), ("HI", "hi"), ("MID", "mid"), ("LOW", "low"), ("CFX", "cfx")]
        return VStack(spacing: 4) {
            // a row per control: channel 1's knob, the name, channel 2's knob
            VStack(spacing: 1) {
                ForEach(names, id: \.1) { label, key in
                    HStack(spacing: 0) {
                        mixKnob(key, sh[0], k).frame(maxWidth: .infinity)
                        Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: m.mixLabel)
                        mixKnob(key, sh[1], k).frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 0) {
                cueBtn(sh[0]).frame(maxWidth: .infinity)
                Color.clear.frame(width: m.mixLabel, height: 1)
                cueBtn(sh[1]).frame(maxWidth: .infinity)
            }
            HStack(spacing: 0) {
                faderCol(sh[0]).frame(maxWidth: .infinity)
                Color.clear.frame(width: m.mixLabel, height: 1)
                faderCol(sh[1]).frame(maxWidth: .infinity)
            }
            crossfader.frame(height: m.xfH)
        }
        .padding(4)
        .frame(width: m.mixW)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    func mixKnob(_ key: String, _ i: Int, _ k: CGFloat) -> some View {
        let v: Double = key == "trim" ? core.mixer.trim[i] : key == "hi" ? core.mixer.hi[i] : key == "mid" ? core.mixer.mid[i] : key == "low" ? core.mixer.low[i] : core.mixer.cfx[i]
        return Knob(label: "", value: v, color: key == "cfx" ? Theme.loop : Theme.deck[i], size: k, bipolar: true, tap: eqTap(key)) { core.setMixer(key, i, $0) }
    }
    /// with no controller plugged in, a tap on an EQ knob cuts the band or puts it back to the centre
    func eqTap(_ key: String) -> ((Double) -> Double)? {
        ["hi", "mid", "low"].contains(key) && app.controllerName.isEmpty ? MixerCurves.eqTap : nil
    }
    func cueBtn(_ i: Int) -> some View {
        Button { core.togglePfl(i) } label: {
            Text("CUE").font(.system(size: 10, weight: .heavy)).frame(width: 40, height: m.cueH).foregroundStyle(core.mixer.pfl[i] ? Color.black : Theme.deck[i])
                .background(RoundedRectangle(cornerRadius: 4).fill(core.mixer.pfl[i] ? Theme.cue : Theme.raise))
        }.buttonStyle(.plain)
    }
    func faderCol(_ i: Int) -> some View {
        HStack(spacing: 2) {
            MeterView(level: { let r = app.core.lastSnapshot.decks[i]; return Double(max(r.peakL, r.peakR)) }).frame(width: 5, height: m.mixFader)
            VFader(value: core.mixer.fader[i], color: Theme.deck[i], height: m.mixFader) { core.setMixer("fader", i, $0) }
        }
    }
    /// iPhone: the master section, for the bar along the top
    var phoneMaster: some View {
        HStack(spacing: 6) {
            VStack(spacing: 0) {
                Knob(label: "", value: core.mixer.headMix, size: 20, center: 0) { core.mixer.headMix = $0 }
                Text("CUE/MST").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Theme.muted)
            }
            Button { core.toggleMasterCue() } label: {
                Text("MST").font(.system(size: 10, weight: .bold)).fixedSize().padding(.horizontal, 6).frame(height: 24).foregroundStyle(core.mixer.masterCue ? Color.black : Theme.fg)
                    .background(RoundedRectangle(cornerRadius: 4).fill(core.mixer.masterCue ? Theme.cue : Theme.raise))
            }.buttonStyle(.plain)
            if app.midi.hasAction("master") || app.controllerName.isEmpty {
                VStack(spacing: 0) {
                    Knob(label: "", value: core.mixer.master, size: 20, center: 0.8) { core.mixer.master = $0 }
                    Text("MASTER").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Theme.muted)
                }
            } else {
                // the controller's MASTER LEVEL works in its own hardware (it sends nothing), so it's the master
                Button { core.mixer.master = 0.8; app.status("Master volume: the MASTER LEVEL knob on the \(app.controllerName). Cratebox's own master stays at its default level.", 6) } label: {
                    Text("MASTER\nON \(app.controllerName.contains("FLX4") ? "FLX4" : "CTRL")").font(.system(size: 7, weight: .bold)).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5).frame(height: 26).background(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
                }.buttonStyle(.plain)
            }
            MeterView(level: { let p = app.core.lastSnapshot.masterPeak; return Double(max(p.0, p.1)) }).frame(width: 5, height: 24)
        }
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
            if short {
                LitButton(label: "BEAT FX · \(fx.fx.rawValue.uppercased())", on: fx.on, color: Theme.hot, wide: true) { fxSheet = true }
                    .sheet(isPresented: $fxSheet) { BeatFXView().padding().presentationDetents([.height(220)]) }
            } else { BeatFXView() }
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
            Knob(label: "Trim", value: core.mixer.trim[i], color: c, size: compact ? 24 : 28, bipolar: true) { core.setMixer("trim", i, $0) }
            Knob(label: "Hi", value: core.mixer.hi[i], color: c, size: compact ? 24 : 28, bipolar: true, tap: eqTap("hi")) { core.setMixer("hi", i, $0) }
            Knob(label: "Mid", value: core.mixer.mid[i], color: c, size: compact ? 24 : 28, bipolar: true, tap: eqTap("mid")) { core.setMixer("mid", i, $0) }
            Knob(label: "Low", value: core.mixer.low[i], color: c, size: compact ? 24 : 28, bipolar: true, tap: eqTap("low")) { core.setMixer("low", i, $0) }
            Knob(label: "CFX", value: core.mixer.cfx[i], color: Theme.loop, size: compact ? 24 : 28, bipolar: true) { core.setMixer("cfx", i, $0) }
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
            .faderDrag(core.mixer.xfader, span: g.size.width - 16) { core.mixer.xfader = $0 }
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
                ForEach(core.activeDecks, id: \.self) { c in LitButton(label: "\(c + 1)", on: fx.ch == c, color: Theme.deck[c]) { fx.channel(c) } }
                LitButton(label: "M", on: fx.ch == 4, color: Theme.fg) { fx.channel(4) }
            }
            HStack(spacing: 8) {
                Knob(label: "Level", value: fx.depth, color: Theme.loop, size: 28, center: fx.spec.depth) { fx.setDepth($0) }
                LitButton(label: "FX ON", on: fx.on, color: Theme.hot, wide: true) { fx.setOn(!fx.on) }
            }
        }
    }
}
