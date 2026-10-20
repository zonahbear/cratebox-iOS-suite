import SwiftUI
import CrateboxKit

func clock(_ t: Double) -> String {
    let s = max(0, t)
    return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int(s * 10) % 10)
}

struct DeckView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var deck: DeckModel
    var compact = false
    var phone = false
    var chips = true                    // phone layout: the DECK 1 / DECK 3 switch (4-deck mode)
    var color: Color { Theme.deck[deck.i] }

    var body: some View {
        if phone { phoneBody } else { fullBody }
    }
    /// iPhone landscape: the deck's controls (its waveform is in the lanes across the top, PhoneLane)
    var phoneBody: some View {
        VStack(spacing: 4) {
            if app.core.four && chips {
                // which deck this side plays: 1 or 3 on the left, 2 or 4 on the right
                HStack(spacing: 4) {
                    ForEach([deck.i % 2, deck.i % 2 + 2], id: \.self) { d in
                        let on = d == deck.i
                        Button { app.midi.setSide(d % 2, d); app.objectWillChange.send() } label: {
                            Text("DECK \(d + 1)").font(.system(size: 11, weight: .bold)).frame(maxWidth: .infinity, minHeight: 20)
                                .foregroundStyle(on ? Color.black : Theme.deck[d])
                                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.deck[d] : Theme.raise))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                if deck.i % 2 == 0 { phoneTempo }
                JogView(deck: deck, color: color).frame(width: app.core.four ? 74 : 84, height: app.core.four ? 74 : 84)
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        LitButton(label: "SYNC", on: deck.sync, color: color) { deck.setSync(!deck.sync) }
                        LitButton(label: "MT", on: deck.mt, color: color) { deck.setMT(!deck.mt) }
                        LitButton(label: "Q", on: deck.quant, color: color) { deck.quant.toggle() }
                    }
                    HStack(spacing: 8) {
                        HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                            Text("CUE").font(.system(size: 13, weight: .bold)).frame(width: 54, height: 40)
                                .background(Capsule().fill(Theme.raise)).overlay(Capsule().stroke(Theme.cue, lineWidth: 2))
                        }
                        Button { deck.togglePlay() } label: {
                            Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 16)).frame(width: 54, height: 40)
                                .background(Capsule().fill(deck.playing ? Theme.ok.opacity(0.25) : Theme.raise)).overlay(Capsule().stroke(Theme.ok, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: .infinity)
                if deck.i % 2 == 1 { phoneTempo }
            }
            // loops, jumps, tap, grid: one row that scrolls sideways
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    LitButton(label: "IN", on: deck.loop.a != nil && deck.loop.b == nil, color: Theme.loop) { deck.loopIn() }
                    LitButton(label: "OUT", on: deck.loop.on, color: Theme.loop) { deck.loopOut() }
                    LitButton(label: deck.loop.on ? "EXIT" : "RELOOP", on: deck.loop.b != nil, color: Theme.loop) { deck.reloopExit() }
                    LitButton(label: "½") { deck.loopScale(0.5) }
                    LitButton(label: "×2") { deck.loopScale(2) }
                    LitButton(label: "◀4") { deck.beatJump(-4) }
                    LitButton(label: "4▶") { deck.beatJump(4) }
                    LitButton(label: "TAP") { deck.tap() }
                    LitButton(label: "GRID") { app.gridDeck = deck.i }
                    LitButton(label: "±\(deck.range == 100 ? "W" : String(Int(deck.range)))") { deck.cycleRange() }
                }
            }
            Picker("", selection: $deck.padMode) {
                Text("CUES").tag(PadMode.hotcue); Text("LOOP").tag(PadMode.beatloop); Text("JUMP").tag(PadMode.beatjump)
                Text("FX1").tag(PadMode.padfx); Text("FX2").tag(PadMode.padfx2)
            }.pickerStyle(.segmented).controlSize(.small)
            HStack(spacing: 3) { ForEach(0..<8, id: \.self) { p in pad(p) } }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.core.four ? color.opacity(0.7) : Theme.line, lineWidth: 1))
    }
    var phoneTempo: some View {
        VFader(value: (deck.pitch + 1) / 2, color: color, height: app.core.four ? 74 : 84, inverted: true) { deck.setPitch($0 * 2 - 1) }
            .onTapGesture(count: 2) { deck.setPitch(0) }
    }
    var fullBody: some View {
        VStack(spacing: 6) {
            header
            WaveformView(deck: deck, color: color).frame(height: compact ? 70 : 96)
            OverviewView(deck: deck, color: color).frame(height: 22)
            HStack(alignment: .top, spacing: 8) {
                if deck.i % 2 == 0 { tempo }
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        JogView(deck: deck, color: color).frame(width: compact ? 96 : 128, height: compact ? 96 : 128)
                        transport
                    }
                    loops
                    pads
                }
                if deck.i % 2 == 1 { tempo }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.core.four && app.midi.side.contains(deck.i) ? color : Theme.line, lineWidth: 1))
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("\(deck.i + 1)").font(.system(size: 22, weight: .bold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(deck.track?.title ?? "No track loaded").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(deck.loading ? "Loading…" : deck.track?.artist ?? "Load from the library, or press LOAD on the controller").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if deck.loaded {
                let k = deck.keyNow()
                if let c = Keys.camelot(k) { Text(c.label).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.keyColor(c.num, c.letter)) }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.2f", deck.effBpm())).font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text(String(format: "%+.2f%%", (deck.rate() - 1) * 100) + " ±\(deck.range == 100 ? "W" : String(Int(deck.range)))").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text("-" + clock(deck.duration - deck.now())).font(.system(size: 14, design: .monospaced))
                    Text(barBeat).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
    var barBeat: String {
        guard deck.ana != nil else { return "" }
        let b = deck.beatAt(deck.now())
        if b < 0 { return "-.-" }
        let n = Int(b.rounded(.down))
        return "\(n / 4 + 1).\(n % 4 + 1)"
    }
    var tempo: some View {
        VStack(spacing: 4) {
            Button { deck.cycleRange() } label: { Text("±\(deck.range == 100 ? "W" : String(Int(deck.range)))").font(.system(size: 10, design: .monospaced)) }.buttonStyle(.plain)
            VFader(value: (deck.pitch + 1) / 2, color: color, height: compact ? 150 : 200, inverted: true) { deck.setPitch($0 * 2 - 1) }
                .onTapGesture(count: 2) { deck.setPitch(0) }
        }
    }
    var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                LitButton(label: "SYNC", on: deck.sync, color: color) { deck.setSync(!deck.sync) }
                LitButton(label: "MT", on: deck.mt, color: color) { deck.setMT(!deck.mt) }
                LitButton(label: "Q", on: deck.quant, color: color) { deck.quant.toggle() }
            }
            HStack(spacing: 6) {
                HoldButton(down: { deck.cueDown() }, up: { deck.cueUp() }) {
                    Text("CUE").font(.system(size: 14, weight: .bold)).frame(width: 56, height: 44)
                        .background(Circle().fill(Theme.raise)).overlay(Circle().stroke(Theme.cue, lineWidth: 2))
                }
                Button { deck.togglePlay() } label: {
                    Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 18)).frame(width: 56, height: 44)
                        .background(Circle().fill(deck.playing ? Theme.ok.opacity(0.25) : Theme.raise)).overlay(Circle().stroke(Theme.ok, lineWidth: 2))
                }.buttonStyle(.plain)
            }
            HStack(spacing: 4) {
                LitButton(label: "TAP") { deck.tap() }
                LitButton(label: "GRID") { app.gridDeck = deck.i }
            }
        }
    }
    var loops: some View {
        HStack(spacing: 4) {
            HoldButton(down: { deck.loopInPress(true) }, up: { deck.loopInPress(false) }) { chip("IN", deck.loop.on || (deck.loop.a != nil && deck.loop.b == nil)) }
            LitButton(label: "OUT", on: deck.loop.on, color: Theme.loop) { deck.loopOut() }
            LitButton(label: deck.loop.on ? "EXIT" : "RELOOP", on: deck.loop.b != nil, color: Theme.loop) { deck.reloopExit() }
            LitButton(label: "½") { deck.loopScale(0.5) }
            LitButton(label: "×2") { deck.loopScale(2) }
            LitButton(label: "◀4") { deck.beatJump(-4) }
            LitButton(label: "4▶") { deck.beatJump(4) }
        }
    }
    func chip(_ s: String, _ on: Bool) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).frame(minHeight: 30).padding(.horizontal, 8)
            .foregroundStyle(on ? Color.black : Theme.fg)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.loop : Theme.raise))
    }
    var pads: some View {
        VStack(spacing: 4) {
            Picker("", selection: $deck.padMode) {
                Text("CUES").tag(PadMode.hotcue); Text("LOOP").tag(PadMode.beatloop); Text("JUMP").tag(PadMode.beatjump)
                Text("FX1").tag(PadMode.padfx); Text("FX2").tag(PadMode.padfx2)
            }.pickerStyle(.segmented)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(0..<8, id: \.self) { p in pad(p) }
            }
        }
    }
    func padLabel(_ p: Int) -> String {
        switch deck.padMode {
        case .hotcue: return String(UnicodeScalar(65 + p)!)
        case .beatloop: return fracText(LOOP_SIZES[p])
        case .beatjump: let j = JUMPS[p]; return (j < 0 ? "◀" : "") + fracText(abs(j)) + (j > 0 ? "▶" : "")
        case .padfx, .padfx2: let e = PAD_FX[deck.padMode]![p]; return "\(e.0.rawValue.prefix(5)) \(fracText(e.1))"
        }
    }
    func padOn(_ p: Int) -> Bool {
        switch deck.padMode {
        case .hotcue: return deck.hot[p] != nil
        case .beatloop: return deck.loop.on && abs(deck.loopBeats() - LOOP_SIZES[p]) < 0.01
        case .beatjump: return false
        case .padfx, .padfx2: return app.core.fx.pad[deck.i].map { $0.p == p && $0.bank == deck.padMode } ?? false
        }
    }
    func pad(_ p: Int) -> some View {
        let on = padOn(p)
        let c: Color = deck.padMode == .hotcue ? Theme.hot : deck.padMode == .beatloop ? Theme.loop : color
        return HoldButton(down: { deck.padPress(p) }, up: { deck.padRelease(p) }) {
            Text(padLabel(p)).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: phone ? 28 : compact ? 30 : 38)
                .foregroundStyle(on ? Color.black : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? c : Theme.raise))
        }
        .contextMenu { if deck.padMode == .hotcue && deck.hot[p] != nil { Button("Clear hot cue \(String(UnicodeScalar(65 + p)!))", role: .destructive) { deck.clearHot(p) } } }
    }
}

/// The platter: touch the top to scratch (or hold a playing track), turn the edge to nudge
struct JogView: View {
    @ObservedObject var deck: DeckModel
    let color: Color
    @State private var last: Double?
    var body: some View {
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                Circle().fill(Theme.raise).overlay(Circle().stroke(Theme.line2, lineWidth: 2))
                Circle().fill(Theme.panel).padding(g.size.width * 0.18)
                Rectangle().fill(color).frame(width: 3, height: g.size.width * 0.18).offset(y: -g.size.width * 0.38)
                    .rotationEffect(.degrees(deck.now() / 1.8 * 360))
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x))
                    if let l = last {
                        var da = a - l
                        if da > .pi { da -= 2 * .pi }
                        if da < -.pi { da += 2 * .pi }
                        deck.jogTicks(da / (2 * .pi) * 720, .scratch)
                    } else { deck.jogTouch(true) }
                    last = a
                }
                .onEnded { _ in last = nil; deck.jogTouch(false) })
        }
    }
}

/// iPhone: one deck's waveform across the full width, its readouts over it; the number picks the deck
/// for its side of the controller in 4-deck mode
struct PhoneLane: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var deck: DeckModel
    var active = true
    var color: Color { Theme.deck[deck.i] }
    var body: some View {
        if active { full } else {
            // a deck the controller isn't on: just its readouts over the track overview
            OverviewView(deck: deck, color: color).frame(height: 16).overlay(alignment: .topLeading) { info }
                .opacity(0.75)
        }
    }
    var full: some View {
        VStack(spacing: 1) {
            WaveformView(deck: deck, color: color).overlay(alignment: .topLeading) { info }
            OverviewView(deck: deck, color: color).frame(height: 6)
        }
    }
    var info: some View {
                    HStack(spacing: 6) {
                        Button { if app.core.four { app.midi.setSide(deck.i % 2, deck.i); app.objectWillChange.send() } } label: {
                            Text("\(deck.i + 1)").font(.system(size: 12, weight: .heavy)).frame(width: 20, height: 16)
                                .foregroundStyle(active ? Color.black : color).background(RoundedRectangle(cornerRadius: 3).fill(active ? color : Theme.raise))
                        }.buttonStyle(.plain)
                        Text(deck.track.map { "\($0.title) · \($0.artist)" } ?? (deck.loading ? "Loading…" : "Empty")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if deck.loaded {
                            if let c = Keys.camelot(deck.keyNow()) { Text(c.label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.keyColor(c.num, c.letter)) }
                            Text(String(format: "%.2f", deck.effBpm())).font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text(String(format: "%+.1f%%", (deck.rate() - 1) * 100)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                            Text("-" + clock(deck.duration - deck.now())).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.bg.opacity(0.6))
    }
}

/// The scrolling waveform around the playhead: RGB (red lows, green mids, blue highs), beat grid, phrases,
/// cues and the loop. Drag it to scratch.
struct WaveformView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("cb.phrases") var showPhrases = true
    @AppStorage("cb.wave") var waveStyle = "rgb"
    @ObservedObject var deck: DeckModel
    let color: Color
    @State private var dragX: CGFloat?
    var body: some View {
        GeometryReader { g in
            TimelineView(.animation) { _ in
                Canvas { ctx, size in draw(ctx, size) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard deck.loaded else { return }
                    if let x = dragX {
                        // 1:1 with the finger: the strip moves with it
                        let secsPerPt = app.zoomSecs / Double(max(1, g.size.width))
                        let dt = -Double(v.location.x - x) * secsPerPt
                        deck.jogTicks(dt / (1.8 / 720), .scratch, raw: true)
                    } else { deck.jogTouch(true, noCoast: true) }
                    dragX = v.location.x
                }
                .onEnded { _ in dragX = nil; deck.jogTouch(false, noCoast: true) })
        }
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let a = deck.ana, let w = a.wave, !w.peak.isEmpty else { return }
        let now = deck.now(), span = app.zoomSecs, W = Double(size.width), H = Double(size.height), mid = H / 2
        let t0 = now - span / 2, pps = W / span
        let wps = Double(w.wps)
        // waveform: bars at the waveform's own time positions, grouped by whole bins counted from the start
        // of the track, so the shape slides smoothly instead of being re-sampled (and shimmering) every frame
        let ppb = pps / wps, n = w.peak.count
        let g = max(1, Int((1.5 / ppb).rounded(.up)))
        var k = max(0, Int((t0 * wps).rounded(.down)) / g * g)
        let kEnd = min(n, Int(((t0 + span) * wps).rounded(.up)) + g)
        let bw = Double(g) * ppb
        while k < kEnd {
            var pk: UInt8 = 0, lo: UInt8 = 0, mi: UInt8 = 0, hi: UInt8 = 0
            for j in k..<min(n, k + g) { pk = max(pk, w.peak[j]); lo = max(lo, w.low[j]); mi = max(mi, w.mid[j]); hi = max(hi, w.high[j]) }
            let tk = Double(k) / wps, x = (tk - t0) * pps
            let past = tk + Double(g) / wps / 2 < now
            let wd = max(1, bw * 0.85)
            if waveStyle == "3band" {
                // the older blue / orange / white style: lows, mids and highs stacked
                for (v, c) in [(Double(lo) / 255, Theme.hex(0x2f6fff)), (Double(mi) / 255, Theme.hex(0xff9a3c)), (Double(hi) / 255, Color.white)] {
                    let h = v * mid * 0.95
                    ctx.fill(Path(CGRect(x: x, y: mid - h, width: wd, height: max(1, 2 * h))), with: .color(c.opacity(past ? 0.4 : 0.85)))
                }
            } else {
                let l = Double(lo) / 255, m = Double(mi) / 255, h3 = Double(hi) / 255, sum = max(0.001, l + m + h3)
                let col = Color(red: min(1, 0.25 + l / sum * 1.1), green: min(1, 0.25 + m / sum * 1.1), blue: min(1, 0.3 + h3 / sum * 1.1))
                let h = Double(pk) / 255 * mid * 0.95
                ctx.fill(Path(CGRect(x: x, y: mid - h, width: wd, height: max(1, 2 * h))), with: .color(col.opacity(past ? 0.55 : 1)))
            }
            k += g
        }
        // phrases along the top
        for p in showPhrases ? a.phrases : [] {
            let end = p.start + Double(p.bars) * 4 * deck.spb
            let x0 = (p.start - t0) * pps, x1 = (end - t0) * pps
            if x1 < 0 || x0 > W { continue }
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: 4)), with: .color(Theme.phrase[p.label] ?? Theme.muted))
        }
        // beat grid: bar lines brighter
        if deck.bpm > 0 {
            var b = (t0 - a.firstBeat) / deck.spb
            b.round(.down)
            while true {
                let t = a.firstBeat + b * deck.spb
                let gx = (t - t0) * pps
                if gx > W { break }
                if gx >= 0 {
                    let bar = Int(b) % 4 == 0
                    ctx.fill(Path(CGRect(x: gx, y: 4, width: bar ? 1.5 : 1, height: bar ? H - 4 : 10)), with: .color(Color.white.opacity(bar ? 0.55 : 0.3)))
                }
                b += 1
            }
        }
        // loop, cue, hot cues
        if let la = deck.loop.a {
            let lb = deck.loop.b ?? la
            ctx.fill(Path(CGRect(x: (la - t0) * pps, y: 0, width: max(2, (lb - la) * pps), height: H)), with: .color(Theme.loop.opacity(deck.loop.on ? 0.25 : 0.12)))
        }
        ctx.fill(Path(CGRect(x: (deck.cue - t0) * pps - 1, y: 0, width: 2, height: H)), with: .color(Theme.cue))
        for (k, h) in deck.hot.enumerated() {
            guard let h else { continue }
            let hx = (h - t0) * pps
            ctx.fill(Path(CGRect(x: hx - 1, y: 0, width: 2, height: H)), with: .color(Theme.hot))
            ctx.draw(Text(String(UnicodeScalar(65 + k)!)).font(.system(size: 9, weight: .bold)).foregroundColor(.white), at: CGPoint(x: hx + 6, y: H - 8))
        }
        // playhead
        ctx.fill(Path(CGRect(x: W / 2 - 1, y: 0, width: 2, height: H)), with: .color(color))
    }
}

/// The whole track, small: where you are, phrases, cues; tap to jump
struct OverviewView: View {
    @ObservedObject var deck: DeckModel
    let color: Color
    var body: some View {
        GeometryReader { g in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Canvas { ctx, size in
                    guard let a = deck.ana, let w = a.wave, !w.peak.isEmpty, deck.duration > 0 else { return }
                    let W = Double(size.width), H = Double(size.height)
                    let n = w.peak.count, per = max(1, n / Int(max(1, W)))
                    for x in 0..<Int(W) {
                        let k = x * n / Int(W)
                        var m: UInt8 = 0
                        for j in k..<min(n, k + per) { m = max(m, w.peak[j]) }
                        let h = Double(m) / 255 * H
                        ctx.fill(Path(CGRect(x: Double(x), y: H - h, width: 1, height: h)), with: .color(Theme.muted.opacity(0.6)))
                    }
                    for p in a.phrases {
                        ctx.fill(Path(CGRect(x: p.start / deck.duration * W, y: 0, width: Double(p.bars) * 4 * deck.spb / deck.duration * W, height: 3)), with: .color(Theme.phrase[p.label] ?? Theme.muted))
                    }
                    for h in deck.hot.compactMap({ $0 }) { ctx.fill(Path(CGRect(x: h / deck.duration * W, y: 0, width: 1.5, height: H)), with: .color(Theme.hot)) }
                    let px = deck.now() / deck.duration * W
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: px, height: H)), with: .color(Color.black.opacity(0.35)))
                    ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: H)), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in if deck.loaded { deck.seekTo(Double(p.x / g.size.width) * deck.duration) } }
        }
        .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
