// The suite's three modes and the selector that switches between them. Each mode is its own screen with its
// own model; switching never stops Performance Mode's audio (decks keep playing while you check a stick).
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case performance, deckBridge, usb
    var id: String { rawValue }
    var title: String {
        switch self {
        case .performance: return "Performance Mode"
        case .deckBridge: return "Deck Bridge"
        case .usb: return "Cratebox USB"
        }
    }
    var short: String {
        switch self {
        case .performance: return "PERFORMANCE"
        case .deckBridge: return "DECK BRIDGE"
        case .usb: return "USB"
        }
    }
    var icon: String {
        switch self {
        case .performance: return "dial.medium"
        case .deckBridge: return "slider.horizontal.below.square.and.square.filled"
        case .usb: return "externaldrive"
        }
    }
    var blurb: String {
        switch self {
        case .performance: return "Cratebox's decks, mixer, controller and library"
        case .deckBridge: return "Touch controller for rekordbox decks 3 and 4"
        case .usb: return "Prepare and check rekordbox USB sticks"
        }
    }
}

/// Which mode is up (remembered across launches)
final class SuiteState: ObservableObject {
    static let shared = SuiteState()
    @Published var mode: AppMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "cb.mode") } }
    init() {
        let args = CommandLine.arguments
        if args.contains("-bridge") { mode = .deckBridge }
        else if args.contains("-usb") { mode = .usb }
        else if args.contains("-demo") { mode = .performance }
        else { mode = AppMode(rawValue: UserDefaults.standard.string(forKey: "cb.mode") ?? "") ?? .performance }
    }
}

/// The selector: a cyan capsule with the mode's name (just its icon when `compact`), opening the three modes
struct ModeSwitcher: View {
    @ObservedObject var suite = SuiteState.shared
    var compact = false
    var body: some View {
        Menu {
            ForEach(AppMode.allCases) { m in
                Button { withAnimation(.easeInOut(duration: 0.18)) { suite.mode = m } } label: {
                    Label { Text(m.title) } icon: { Image(systemName: m == suite.mode ? "checkmark" : m.icon) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: suite.mode.icon).font(.system(size: 12, weight: .semibold))
                if !compact { Text(suite.mode.short).font(.system(size: 11, weight: .heavy)).tracking(1) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, compact ? 8 : 10).frame(height: 26)
            .background(Capsule().fill(Theme.accent))
            .accessibilityLabel("Mode: \(suite.mode.title)")
        }
    }
}

/// The app's root: the mode that's up, Performance Mode underneath the others so it keeps its state
struct SuiteRoot: View {
    @ObservedObject var suite = SuiteState.shared
    @EnvironmentObject var app: AppModel
    var body: some View {
        ZStack {
            ContentView()
                .opacity(suite.mode == .performance ? 1 : 0)
                .allowsHitTesting(suite.mode == .performance)
                .accessibilityHidden(suite.mode != .performance)
            if suite.mode == .deckBridge {
                DeckBridgeView(bridge: app.bridge).transition(.opacity)
            }
            if suite.mode == .usb {
                CrateboxUSBView(usb: app.usb).transition(.opacity)
            }
        }
        .background(Theme.bg)
        .onChange(of: suite.mode) { _, m in
            app.bridge.setActive(m == .deckBridge)
            app.usb.setActive(m == .usb)
        }
        .onAppear {
            app.bridge.setActive(suite.mode == .deckBridge)
            app.usb.setActive(suite.mode == .usb)
        }
    }
}

/// a top bar shared by the two new modes: the selector, a title, then whatever the mode adds
struct ModeBar<Trailing: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            ModeSwitcher()
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 14, weight: .heavy)).tracking(1.5).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 8).frame(height: 40)
    }
}
