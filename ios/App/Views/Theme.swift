import SwiftUI

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
    static let warn = hex(0xffaa00)
}

/// A button with a light, like the hardware's
struct LitButton: View {
    let label: String
    var on = false
    var color: Color = Theme.ok
    var wide = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: wide ? .infinity : nil, minHeight: 30).padding(.horizontal, 8)
                .foregroundStyle(on ? Color.black : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? color : Theme.line2, lineWidth: 1))
        }.buttonStyle(.plain)
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
                .onChanged { _ in if !held { held = true; down() } }
                .onEnded { _ in if held { held = false; up() } })     // either path may come first: one release
            .onChange(of: pressing) { _, p in if !p && held { held = false; up() } }
    }
}

/// A knob: drag up/down; double-tap goes back to the centre
struct Knob: View {
    let label: String
    let value: Double
    var color: Color = Theme.fg
    var size: CGFloat = 30
    var center = 0.5
    var bipolar = false                  // TRIM, EQ, CFX: lit only when turned away from the centre
    let set: (Double) -> Void
    @State private var start: Double?
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Theme.raise).overlay(Circle().stroke(Theme.line2))
                // EQ-style knobs light only away from 12 o'clock, from the centre to where they're turned
                let lo = bipolar ? min(0.5, value) : 0, hi = bipolar ? max(0.5, value) : value
                if !bipolar || abs(value - 0.5) > 0.01 {
                    Circle().trim(from: 0.75 * lo, to: 0.75 * hi).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(135)).padding(2)
                }
                Rectangle().fill(Theme.fg).frame(width: 2, height: size * 0.32).offset(y: -size * 0.18)
                    .rotationEffect(.degrees(-135 + 270 * value))
            }.frame(width: size, height: size)
            if !label.isEmpty { Text(label).font(.system(size: 9)).foregroundStyle(Theme.muted) }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { g in let s = start ?? value; start = s; set(min(1, max(0, s - Double(g.translation.height) / 160))) }
            .onEnded { _ in start = nil })
        .onTapGesture(count: 2) { set(center) }
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
                Capsule().fill(Theme.raise).frame(width: 6).frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 30, height: 14)
                    .offset(y: -CGFloat(v) * (h - 14))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let y = min(max(0, d.location.y - 7), h - 14)
                let nv = 1 - Double(y / (h - 14))
                set(inverted ? 1 - nv : nv)
            })
        }.frame(width: 34, height: height)
    }
}
