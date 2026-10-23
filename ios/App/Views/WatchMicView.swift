// Watch mic (personal/heat only): the phone side of the experiment, under Settings. Shows whether the watch is
// connected and how the link is doing, and has the phone's own Mute and Level, which the watch can't override.
import SwiftUI

struct WatchMicView: View {
    @ObservedObject var mic = WatchMicReceiver.shared
    @AppStorage("cb.watchMicOn") var on = false

    var body: some View {
        Form {
            Section {
                Toggle("Listen for Cratebox Mic", isOn: $on).onChange(of: on) { _, v in v ? mic.start() : mic.stop() }
                LabeledContent("Status", value: mic.status)
                if !mic.peer.isEmpty { LabeledContent("Watch", value: mic.peer) }
                if !mic.path.isEmpty { LabeledContent("Arriving over", value: mic.path) }
                LabeledContent("This phone", value: "\(mic.address) port \(WatchMic.port)")
            } footer: {
                Text("On the watch, open Cratebox Mic and tap Go live. It finds this phone by itself on the same Wi-Fi; if it doesn't, type the address above into the watch. With no shared Wi-Fi it falls back to Bluetooth (slower).")
            }
            if mic.listening {
                Section("Live") {
                    HStack {
                        Text(mic.phoneMuted || mic.watchMuted ? "MUTED" : "MIC LIVE")
                            .font(.headline).foregroundStyle(mic.phoneMuted || mic.watchMuted ? Theme.muted : Theme.hot)
                        Spacer()
                        ProgressView(value: Double(min(1, mic.level))).frame(width: 120)
                    }
                    Toggle("Mute (phone)", isOn: $mic.phoneMuted)
                    if mic.watchMuted { Text("Muted on the watch").font(.caption).foregroundStyle(Theme.muted) }
                    LabeledContent("Level (phone)") { Slider(value: $mic.phoneLevel, in: 0...1.5).frame(width: 200) }
                }
                Section {
                    Picker("Jitter buffer", selection: $mic.targetMs) { ForEach([20, 40, 60, 100, 150], id: \.self) { Text("\($0) ms").tag($0) } }
                    LabeledContent("Buffered now", value: "\(mic.bufferedMs) ms")
                    LabeledContent("Dropouts", value: "\(mic.underruns)")
                    LabeledContent("Lost packets", value: "\(mic.lost)")
                } header: { Text("Link") } footer: {
                    Text("Delay you hear ≈ the watch's own audio buffer + half the round trip shown on the watch + the jitter buffer + this phone's output. Measure the real total with a clap test. Lower the jitter buffer until dropouts start, then go one step up.")
                }
            }
        }
        .navigationTitle("Watch mic (experiment)")
    }
}
