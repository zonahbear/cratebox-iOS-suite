import SwiftUI
import UIKit

/// The web app's Booth look
enum Theme {
    static func hex(_ v: UInt32) -> Color { Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255) }
    static let bg = hex(0x000000), panel = hex(0x101215), raise = hex(0x1d2025), line = hex(0x23262c), line2 = hex(0x33373f)
    static let fg = hex(0xeef1f5), muted = hex(0x8d96a5), dim = hex(0x5a6271)
    static let deck = [hex(0x2f9dff), hex(0xff7b2e), hex(0x22d6b8), hex(0xe553c8)]
    static let hot = hex(0xff2d4b), ok = hex(0x24e07a), cue = hex(0xffaa00), loop = hex(0xffd21f)
    static let phrase: [String: Color] = ["Intro": hex(0x4cc9f0), "Build": hex(0xffd23f), "Drop": hex(0xff4d6d), "Breakdown": hex(0x9b7bff), "Groove": hex(0x3ddc84), "Outro": hex(0x5b7cfa)]
    static func keyColor(_ num: Int, _ letter: String) -> Color { Color(hue: Double((num * 30 + 150) % 360) / 360, saturation: 0.7, brightness: letter == "A" ? 0.95 : 1) }
    static let mono = Font.system(.caption, design: .monospaced)
    /// the suite's accent (mode selector, Deck Bridge, Cratebox USB): cyan, between decks 1 and 3's colours
    static let accent = hex(0x2ad4f0)
    /// raised surfaces (buttons, knob bodies): lighter at the top, like moulded plastic under a light
    static let raiseFill = LinearGradient(colors: [hex(0x2a2e35), hex(0x1a1d22)], startPoint: .top, endPoint: .bottom)
    static let warn = hex(0xffaa00)
}

/// Haptics for touches only (Settings → Look → Haptics, on by default). Called from gesture handlers alone, never
/// from the model, so a controller or AI DJ moving the same control is silent
enum Haptics {
    static let key = "cb.haptics"
    static var on: Bool { UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key) }
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let sel = UISelectionFeedbackGenerator()
    /// a button press
    static func tap() { if on { light.impactOccurred(intensity: 0.7) } }
    /// a knob or fader passing its centre detent
    static func detent() { if on { rigid.impactOccurred(intensity: 0.6) } }
    /// a step (a picker, a tab)
    static func step() { if on { sel.selectionChanged() } }
}

/// A button with a light, like the hardware's: a squircle with a soft top highlight; lit, it glows its colour
struct LitButton: View {
    let label: String
    var on = false
    var color: Color = Theme.ok
    var wide = false
    let action: () -> Void
    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: wide ? .infinity : nil, minHeight: 30).padding(.horizontal, 8)
                .foregroundStyle(on ? Color.black : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Theme.raiseFill)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? color.opacity(0.9) : Theme.line2, lineWidth: 1))
                .shadow(color: on ? color.opacity(0.45) : .clear, radius: on ? 5 : 0)
        }.buttonStyle(PressStyle())
    }
}

/// pressed: a touch smaller and darker, like a real button going down
struct PressStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.scaleEffect(c.isPressed ? 0.96 : 1).brightness(c.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.08), value: c.isPressed)
    }
}

/// A button that reports press and release (CUE, pads, hot cues)
struct HoldButton<Label: View>: View {
    let down: () -> Void
    let up: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var held = false
    /// true while the finger is down; SwiftUI resets it when the gesture is cancelled too (a system gesture, an
    /// alert, the app leaving the screen), which never calls onEnded: then the release is sent from here, so a
    /// CUE preview or a PAD FX can't stay stuck on
    @GestureState private var pressing = false
    var body: some View {
        label()
            .opacity(held ? 0.75 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressing) { _, s, _ in s = true }
                .onChanged { _ in if !held { held = true; Haptics.tap(); down() } }
                .onEnded { _ in if held { held = false; up() } })     // either path may come first: one release
            .onChange(of: pressing) { _, p in if !p && held { held = false; up() } }
    }
}

/// A knob: drag up/down; double-tap goes back to the centre, or with `tap` set (EQ kill) one tap does `tap`
struct Knob: View {
    let label: String
    let value: Double
    var color: Color = Theme.fg
    var size: CGFloat = 30
    var center = 0.5
    var bipolar = false                  // TRIM, EQ, CFX: lit only when turned away from the centre
    var tap: ((Double) -> Double)? = nil  // one tap sets tap(value) instead of double-tap → centre
    let set: (Double) -> Void
    @State private var start: Double?
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // a sculpted knob: a dark well, the arc, then a moulded cap with its pointer
                Circle().fill(Theme.bg).overlay(Circle().stroke(Theme.line2))
                // EQ-style knobs light only away from 12 o'clock, from the centre to where they're turned
                let lo = bipolar ? min(0.5, value) : 0, hi = bipolar ? max(0.5, value) : value
                if !bipolar || abs(value - 0.5) > 0.01 {
                    Circle().trim(from: 0.75 * lo, to: 0.75 * hi).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(135)).padding(2)
                }
                Circle().fill(RadialGradient(colors: [Theme.hex(0x3a3f47), Theme.hex(0x16181c)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.42))
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .padding(size * 0.16)
                Capsule().fill(Theme.fg).frame(width: 2.5, height: size * 0.26).offset(y: -size * 0.17)
                    .rotationEffect(.degrees(-135 + 270 * value))
            }.frame(width: size, height: size)
            if !label.isEmpty { Text(label).font(.system(size: 9)).foregroundStyle(Theme.muted) }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { g in
                let s = start ?? value; start = s
                let v = min(1, max(0, s - Double(g.translation.height) / 160))
                // a click as a centred knob (EQ, TRIM, CFX) passes 12 o'clock, and at either end
                if (bipolar && (value - center) * (v - center) < 0) || (v != value && (v == 0 || v == 1)) { Haptics.detent() }
                set(v)
            }
            .onEnded { _ in start = nil })
        .onTapGesture(count: tap == nil ? 2 : 1) { Haptics.tap(); set(tap?(value) ?? center) }
    }
}

/// Faders follow the finger from where the cap is, like hardware: a touch on the track doesn't make the cap jump
/// to it. `value` and `set` are 0...1 along the drag (`vertical`: 0 at the top, so down is up the scale).
/// The start is GestureState, so a drag the system cancels can't leave a stale start for the next one.
struct FaderDrag: ViewModifier {
    let value: Double
    let span: CGFloat
    var vertical = false
    let set: (Double) -> Void
    @GestureState private var start: Double?
    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 0).updating($start) { d, s, _ in
            if s == nil { s = value }
            let t = Double(vertical ? d.translation.height : d.translation.width) / Double(max(1, span))
            set(min(1, max(0, s! + t)))
        })
    }
}
extension View {
    func faderDrag(_ value: Double, span: CGFloat, vertical: Bool = false, set: @escaping (Double) -> Void) -> some View {
        modifier(FaderDrag(value: value, span: span, vertical: vertical, set: set))
    }
}

/// The crossfader bar (Performance Mode's mixers). It gets its value from the caller, read in the caller's body:
/// built with Xcode 27, observed state read only inside a GeometryReader's closure doesn't redraw the view (the
/// cap stayed put while the crossfader moved from the controller or AI DJ)
struct XFaderBar: View {
    let value: Double
    var capW: CGFloat = 16, capH: CGFloat = 26
    let set: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg).overlay(Capsule().stroke(Theme.line2)).frame(height: 6)
                FaderCap(color: Theme.fg, vertical: false).frame(width: capW, height: capH)
                    .offset(x: CGFloat(value) * (g.size.width - capW))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .faderDrag(value, span: g.size.width - capW) { v in
                if (value - 0.5) * (v - 0.5) < 0 { Haptics.detent() }      // the centre click
                set(v)
            }
            .onTapGesture(count: 2) { Haptics.tap(); set(0.5) }
        }
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// A vertical fader
struct VFader: View {
    let value: Double
    var color: Color = Theme.fg
    var height: CGFloat = 110
    var inverted = false
    let set: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let h = g.size.height, v = inverted ? 1 - value : value
            ZStack(alignment: .bottom) {
                Capsule().fill(Theme.bg).overlay(Capsule().stroke(Theme.line2)).frame(width: 6).frame(maxWidth: .infinity)
                FaderCap(color: color, vertical: true).frame(width: 30, height: 14)
                    .offset(y: -CGFloat(v) * (h - 14))
            }
            .contentShape(Rectangle())
            // 0 at the top for the drag: the shown value is 1 − that
            .faderDrag(1 - v, span: h - 14, vertical: true) { y in set(inverted ? y : 1 - y) }
        }.frame(width: 34, height: height)
    }
}

/// A fader cap: moulded, lighter on top, with the grip line across it in the channel's colour
struct FaderCap: View {
    let color: Color
    let vertical: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [Theme.hex(0xe9edf2), Theme.hex(0x9aa2ad)], startPoint: .top, endPoint: .bottom))
            .overlay(Rectangle().fill(color == Theme.fg ? Theme.bg : color).frame(width: vertical ? nil : 2, height: vertical ? 2 : nil))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.black.opacity(0.5), lineWidth: 0.5))
    }
}
