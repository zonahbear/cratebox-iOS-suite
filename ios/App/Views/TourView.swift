import SwiftUI

/// The walkthrough: six short pages on how Performance Mode works. Optional: it's offered once, the first time the
/// app opens, every page has Skip, and Settings → "Show the walkthrough" brings it back. Never shown in CI
/// screenshot runs (they pass launch arguments).
struct TourView: View {
    @Environment(\.dismiss) var dismiss
    @State private var page = 0
    struct Page { let icon: String, title: String, lines: [String] }
    static let pages: [Page] = [
        Page(icon: "dial.medium", title: "Welcome to Cratebox", lines: [
            "A one-minute tour of the decks and mixer. Skip it any time: it's in Settings if you want it later.",
            "The cyan button in the top corner switches between Performance Mode (this), Deck Bridge and Cratebox USB.",
        ]),
        Page(icon: "music.note.list", title: "Load a track", lines: [
            "Open LIBRARY and add a music folder, or plug in a rekordbox USB stick.",
            "Pick a track and load it onto a deck. Its waveform, tempo, key and beat grid appear once it's analysed; a rekordbox stick brings its own grid and cues.",
        ]),
        Page(icon: "play.circle", title: "Play and cue", lines: [
            "PLAY starts and stops the deck.",
            "CUE: stopped, it sets the cue point (or, when you're already on it, plays for as long as you hold). Playing, it jumps back to the cue point and stops.",
            "Drag the waveform or the platter to scratch. Turn VINYL (V) off and the platter only nudges the tempo, so a resting hand can't stop the music.",
        ]),
        Page(icon: "metronome", title: "Tempo and SYNC", lines: [
            "The tempo fader speeds the track up or slows it down; double-tap it to go back to the track's own tempo. The ± button changes its range without moving the tempo.",
            "SYNC matches this deck's tempo and beats to the other deck. Hold SYNC to make this deck the one the others follow.",
            "Each deck shows the tempo it's playing at, the track's own tempo beside it, and a bar.beat counter.",
        ]),
        Page(icon: "slider.vertical.3", title: "Mix", lines: [
            "Each channel has a fader, HI / MID / LOW and a filter (CFX); the crossfader blends the two sides. With no controller plugged in, tap an EQ knob to cut that band and tap again to bring it back.",
            "The pads under each deck are hot cues, loops, beat jumps and effects. BEAT FX adds an effect in time with the music.",
            "EQ in the master section opens a ten-band EQ for the whole mix, with presets.",
        ]),
        Page(icon: "cable.connector", title: "Controller and recording", lines: [
            "Plug in a DDJ-FLX4 and its buttons, platters and faders drive the decks. Other controllers: Settings → Controller, where MIDI learn maps any control.",
            "REC records the mix to the Files app.",
            "That's it. This tour stays in Settings → Show the walkthrough.",
        ]),
    ]
    var body: some View {
        let last = page == TourView.pages.count - 1
        VStack(spacing: 8) {
            HStack {
                Text("\(page + 1) of \(TourView.pages.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                Spacer()
                if !last { Button("Skip") { dismiss() }.font(.system(size: 14, weight: .semibold)) }
            }
            TabView(selection: $page) {
                ForEach(0..<TourView.pages.count, id: \.self) { k in
                    let p = TourView.pages[k]
                    ScrollView {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: p.icon).font(.system(size: 40)).foregroundStyle(Theme.accent).frame(width: 64)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(p.title).font(.system(size: 20, weight: .heavy))
                                ForEach(p.lines, id: \.self) { l in Text(l).font(.system(size: 14)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true) }
                            }.frame(maxWidth: 560, alignment: .leading)
                        }.padding(.horizontal, 8).frame(maxWidth: .infinity)
                    }.tag(k)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 12) {
                if page > 0 { LitButton(label: "Back") { withAnimation { page -= 1 } } }
                Spacer()
                LitButton(label: last ? "Done" : page == 0 ? "Start the tour" : "Next", on: true, color: Theme.accent) {
                    if last { dismiss() } else { withAnimation { page += 1 } }
                }
            }
        }
        .padding(16)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}
