import SwiftUI
import CrateboxKit

/// WAVE mode: the decks and mixer fold away and the waveforms fill the space, one lane per deck (2 or 4).
/// The lanes the controller is driving get an outline in the deck's own colour that breathes slowly, so a
/// glance says which decks the FLX4's two sides are on. With Reduce Motion on, the outline stays lit.
struct WaveStack: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var core: Core
    var body: some View {
        let decks = core.four ? [0, 1, 2, 3] : [0, 1]
        let driven: Set<Int> = core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]
        VStack(spacing: 4) {
            ForEach(decks, id: \.self) { i in
                WaveLane(deck: core.decks[i], driven: driven.contains(i),
                         side: core.four && driven.contains(i) ? (app.midi.side[0] == i ? "L" : "R") : nil)
            }
        }
    }
}

struct WaveLane: View {
    @ObservedObject var deck: DeckModel
    let driven: Bool
    let side: String?                   // "L" / "R" in 4-deck mode, on the lanes the controller drives
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var breathe = false
    var color: Color { Theme.deck[deck.i] }
    var body: some View {
        // the L / R tag sits next to the deck number, clear of the readouts on the right
        PhoneLane(deck: deck, badge: side)
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(color.opacity(driven ? (breathe && !reduceMotion ? 0.45 : 1) : 0), lineWidth: 1.5)
                    .shadow(color: color.opacity(driven ? (breathe && !reduceMotion ? 0.15 : 0.4) : 0), radius: 5)
                    .allowsHitTesting(false)
            }
            .opacity(driven ? 1 : 0.6)
            .onAppear { startBreathing() }
            .onChange(of: driven) { _, _ in startBreathing() }
            .accessibilityLabel("Deck \(deck.i + 1) waveform\(driven ? ", on the controller" : "")")
    }
    func startBreathing() {
        breathe = false
        guard driven, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathe = true }
    }
}
