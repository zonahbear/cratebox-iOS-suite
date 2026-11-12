// AI DJ's screen (the suite's fourth mode, beside Deck Bridge and Cratebox USB): what's on air and what's next, the
// transition as it runs (32 bars, the bass swap at bar 16, the tempo glide), START / MIX NOW / SKIP / STOP, and
// where the tracks come from (library, a playlist, or tracks picked here), the energy, and an Apple Intelligence
// "vibe". Performance Mode keeps running underneath: switch to it to watch the decks move.
//
// No GeometryReader here: built with Xcode 27, state read inside a reader's closure doesn't redraw.
import SwiftUI
import CrateboxKit

struct AIDJView: View {
    @ObservedObject var dj: AIDJ
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    @AppStorage(AIMode.key) private var aiMode = false
    @State private var picking = false
    @State private var vibeText = ""
    @State private var asking = false
    @State private var canAsk = false

    var body: some View {
        VStack(spacing: 4) {
            ModeBar(title: "AI DJ", subtitle: subtitle) { bar }
            if !aiMode { gate } else {
                HStack(alignment: .top, spacing: 8) {
                    ScrollView { VStack(spacing: 8) { decks; transition; if !dj.message.isEmpty { note } } .padding(.bottom, 8) }
                        .frame(maxWidth: .infinity)
                    ScrollView { VStack(spacing: 8) { sourceCard; optionsCard; upNext } .padding(.bottom, 8) }
                        .frame(maxWidth: 380)
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $picking) { AIDJPicker(dj: dj) }
        .onAppear { canAsk = SmartSearch.available }
    }

    var subtitle: String {
        switch dj.phase {
        case .idle: return "Picks, beat-matches and mixes on decks 1 and 2"
        case .loading: return "Loading the first track…"
        case .playing, .preparing, .ready: return "On air: deck \(dj.onAir + 1)"
        case .mixing: return "Mixing deck \(dj.onAir + 1) into deck \(2 - dj.onAir)"
        }
    }
    @ViewBuilder var bar: some View {
        if aiMode {
            if dj.running {
                LitButton(label: "MIX NOW", on: dj.phase == .ready, color: Theme.accent) { dj.mixNow() }.accessibilityHint("Start the transition at the next bar")
                LitButton(label: "SKIP", on: false) { dj.skipNext() }.accessibilityHint("Pick another next track")
                LitButton(label: "STOP", on: true, color: Theme.hot) { dj.stop() }
            } else {
                LitButton(label: "START", on: true, color: Theme.ok) { dj.start() }.frame(minWidth: 90)
            }
        }
    }

    var gate: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("AI DJ is part of AI mode").font(.title3.weight(.bold))
            Text("It picks tracks from your library, a playlist or tracks you choose, matches their loudness, beat-matches them with a tempo glide and mixes them with 32-bar bass swaps, keeping vocals apart using Apple's analysis. Everything runs on this device.")
                .font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 520)
            Toggle("AI mode", isOn: $aiMode).frame(width: 200).tint(Theme.accent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ---- on air / next ----
    var decks: some View {
        HStack(spacing: 8) {
            deckCard(dj.onAir, label: "ON AIR")
            deckCard(1 - dj.onAir, label: dj.phase == .mixing ? "COMING IN" : "NEXT")
        }
    }
    func deckCard(_ i: Int, label: String) -> some View {
        AIDJDeckCard(deck: core.decks[i], label: label, trim: dj.trims[i], active: dj.running)
    }

    var transition: some View {
        let p = dj.plan
        let n = p?.bars ?? AutoMix.Transition.bassSwap.bars
        let swap = (p?.kind ?? .bassSwap).swapBar(of: n)
        let x = dj.phase == .mixing ? dj.bar : 0
        let a = core.decks[dj.onAir]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TRANSITION").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                Text("\((p?.kind ?? .bassSwap).name) · \(n) bars").font(.system(size: 11, weight: .semibold))
                Spacer()
                if let p, dj.phase == .ready, a.bpm > 0 {
                    let left = max(0, Int(((p.outStart - a.beatAt(a.now())) / 4).rounded(.up)))
                    Text("starts in \(left) bars").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                } else if dj.phase == .mixing {
                    Text("bar \(min(n, Int(x) + 1)) / \(n)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                }
            }
            AIDJProgress(progress: x / Double(n), swapAt: swap / Double(n))
                .frame(height: 22)
                .accessibilityElement().accessibilityLabel("Transition").accessibilityValue(dj.phase == .mixing ? "bar \(Int(x) + 1) of \(n)" : "not started")
            if let p {
                HStack(spacing: 12) {
                    let from = a.bpm * p.fromRate
                    let to = a.bpm * p.toRate
                    Label(String(format: "%.1f → %.1f BPM (%+.1f%%)", from, to, p.tempoChange), systemImage: "metronome")
                    if p.mult != 1 { Text(p.mult < 1 ? "half time" : "double time").foregroundStyle(Theme.warn) }
                    Spacer(minLength: 0)
                    vocalLabel(p.clash)
                }.font(.system(size: 11)).foregroundStyle(Theme.fg).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(dj.running ? "Planning the next transition…" : "Bass swap: the next track comes in with its bass cut, the basses swap on the downbeat of bar 16, the old track fades out over the last 8 bars. More transition kinds later.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    @ViewBuilder func vocalLabel(_ c: Double?) -> some View {
        if let c {
            Label(c < 0.5 ? "no vocal overlap" : String(format: "vocals overlap %.0f s", c), systemImage: c < 0.5 ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(c < 0.5 ? Theme.ok : Theme.warn)
        } else {
            Label("vocals unknown", systemImage: "questionmark.circle").foregroundStyle(Theme.muted)
                .accessibilityHint("Apple's analysis (iOS 27) hasn't reached one of these tracks")
        }
    }
    var note: some View {
        Text(dj.message).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }

    // ---- where the tracks come from ----
    var sourceCard: some View {
        let lists = app.browseSources().filter { $0.view != .collection }
        let count = dj.poolTracks().count
        return VStack(alignment: .leading, spacing: 8) {
            Text("TRACKS").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                LitButton(label: "LIBRARY", on: dj.source == .library, color: Theme.accent, wide: true) { dj.source = .library }
                Menu {
                    ForEach(lists) { s in
                        Button("\(s.group == "CRATEBOX" ? "" : s.group + ": ")\(s.name)") { dj.source = .playlist(s.view) }
                    }
                } label: {
                    Text(isPlaylist ? dj.sourceName : "PLAYLIST ▾").font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 30).padding(.horizontal, 6)
                        .foregroundStyle(isPlaylist ? Color.black : Theme.fg)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isPlaylist ? Theme.accent : Theme.raise))
                }.disabled(lists.isEmpty)
                LitButton(label: "SELECTED", on: dj.source == .selected, color: Theme.accent, wide: true) { dj.source = .selected; if dj.selected.isEmpty { picking = true } }
            }
            HStack {
                Text("\(count) analysed track\(count == 1 ? "" : "s") in \(dj.sourceName)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                if dj.source == .selected { Button("Choose…") { picking = true }.font(.system(size: 12, weight: .semibold)) }
            }
            if dj.source != .library {
                Toggle("Play in this order", isOn: $dj.keepOrder).font(.system(size: 12)).tint(Theme.accent)
            }
            if canAsk { vibe }
        }
        .disabled(dj.running && dj.phase == .mixing)
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
    var isPlaylist: Bool { if case .playlist = dj.source { return true }; return false }

    /// Apple Intelligence: a sentence narrows the tracks ("dark rollers around 174", "warm-up house under 124")
    var vibe: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                TextField("Vibe, in words (Apple Intelligence)", text: $vibeText).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .submitLabel(.go).onSubmit(ask)
                if asking { ProgressView().controlSize(.small) } else { Button("Ask", action: ask).font(.system(size: 12, weight: .semibold)).disabled(vibeText.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            if let f = dj.vibe {
                HStack {
                    Text("Only: \(f.summary)").font(.system(size: 11)).foregroundStyle(Theme.accent).lineLimit(2)
                    Spacer()
                    Button("Clear") { dj.vibe = nil; vibeText = "" }.font(.system(size: 11))
                }
            }
        }
    }
    func ask() {
        let s = vibeText.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !asking else { return }
        asking = true
        let a = core.decks[dj.onAir]
        let playing: (bpm: Double, key: Int)? = a.loaded && a.bpm > 0 ? (a.effBpm(), a.keyNow()) : nil
        Task {
            let f = try? await SmartSearch.filter(for: s, playing: playing)
            await MainActor.run {
                asking = false
                dj.vibe = (f?.isEmpty ?? true) ? nil : f
            }
        }
    }

    var optionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ENERGY").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
            Picker("Energy", selection: $dj.flow) {
                Text("Cool down").tag(-1); Text("Steady").tag(0); Text("Build").tag(1)
            }.pickerStyle(.segmented)
            Text("Tempo can glide up to ±10% per transition (half and double time count), so the set moves between tempos. Loudness is matched with TRIM. Decks 1 and 2 only.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if !AppleMusic.usable {
                Text("Without Apple's analysis (iOS 27) AI DJ can't see vocals: it still mixes on key, tempo and phrases.")
                    .font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    var upNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dj.options.isEmpty ? "HISTORY" : "WHAT FITS NEXT").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
            ForEach(Array(dj.options.enumerated()), id: \.offset) { k, c in
                let t = app.library.track(c.track.id)
                HStack(spacing: 6) {
                    Text("\(Int(c.score.rounded()))").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(k == 0 ? Theme.ok : Theme.muted).frame(width: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t?.info.title ?? c.track.id).font(.system(size: 12, weight: k == 0 ? .bold : .regular)).lineLimit(1)
                        Text(c.why.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !dj.history.isEmpty {
                if !dj.options.isEmpty { Text("HISTORY").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted).padding(.top, 4) }
                ForEach(Array(dj.history.enumerated().reversed()), id: \.offset) { k, id in
                    Text("\(k + 1). \(app.library.track(id)?.info.title ?? core.decks.first { $0.track?.id == id }?.track?.title ?? id)")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
}

/// one deck as AI DJ shows it: title, tempo, key, loudness trim, where it is
struct AIDJDeckCard: View {
    @ObservedObject var deck: DeckModel
    let label: String
    let trim: Double?
    let active: Bool
    var body: some View {
        let c = Theme.deck[deck.i]
        let key = Keys.camelot(deck.keyNow())
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(deck.i + 1)").font(.system(size: 13, weight: .heavy)).foregroundStyle(c)
                Text(label).font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                Spacer()
                if deck.playing { Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Theme.ok) }
                if deck.sync { Text("SYNC").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.accent) }
            }
            Text(deck.track?.title ?? (deck.loading ? "Loading…" : "Empty")).font(.system(size: 14, weight: .bold)).lineLimit(1)
            Text(deck.track?.artist ?? " ").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack(spacing: 10) {
                Text(deck.bpm > 0 ? String(format: "%.1f BPM", deck.effBpm()) : "– BPM").font(.system(size: 11, design: .monospaced))
                if let key { Text(key.label).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.keyColor(key.num, key.letter)) }
                if let trim, active { Text(String(format: "TRIM %+.1f dB", trim)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted) }
                Spacer(minLength: 0)
                if deck.loaded { Text(deck.barBeat()).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted) }
            }
            ProgressView(value: deck.duration > 0 ? min(1, deck.now() / deck.duration) : 0).tint(c)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(deck.playing ? c.opacity(0.7) : Theme.line, lineWidth: 1))
    }
}

/// the transition's bar: how far in, the bass-swap line, 8-bar ticks
struct AIDJProgress: View {
    let progress: Double, swapAt: Double
    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerRadius: 5), with: .color(Theme.raise))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: W * min(1, max(0, progress)), height: H), cornerRadius: 5), with: .color(Theme.accent.opacity(0.55)))
            for k in 1..<4 { ctx.fill(Path(CGRect(x: W * Double(k) / 4 - 0.5, y: H * 0.6, width: 1, height: H * 0.4)), with: .color(Theme.line2)) }
            ctx.fill(Path(CGRect(x: W * swapAt - 1, y: 0, width: 2, height: H)), with: .color(Theme.cue))
            ctx.draw(Text("BASS SWAP").font(.system(size: 8, weight: .heavy)).foregroundColor(Theme.cue), at: CGPoint(x: W * swapAt + 4, y: H / 2), anchor: .leading)
        }
    }
}

/// the Selected source: tick tracks from the library (analysed ones; the order ticked is the order kept)
struct AIDJPicker: View {
    @ObservedObject var dj: AIDJ
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    var body: some View {
        let q = query.lowercased()
        let tracks = library.tracks.filter { ($0.info.bpm ?? 0) > 0 && (q.isEmpty || $0.info.title.lowercased().contains(q) || $0.info.artist.lowercased().contains(q)) }
        return NavigationStack {
            List(tracks, id: \.id) { t in
                let k = dj.selected.firstIndex(of: t.id)
                Button {
                    if let k { dj.selected.remove(at: k) } else { dj.selected.append(t.id) }
                } label: {
                    HStack {
                        Text(k.map { "\($0 + 1)" } ?? "").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(t.info.title).lineLimit(1)
                            Text(t.info.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(String(format: "%.1f", t.info.bpm ?? 0)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Text(Keys.camelot(t.info.key)?.label ?? "").font(.system(size: 12, weight: .bold)).frame(width: 32)
                        Image(systemName: k == nil ? "circle" : "checkmark.circle.fill").foregroundStyle(k == nil ? Theme.dim : Theme.accent)
                    }
                }.buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle("\(dj.selected.count) selected")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Clear") { dj.selected = [] }.disabled(dj.selected.isEmpty) }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
