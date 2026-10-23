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
                Picker("Link", selection: $mic.mode) {
                    Text("Bluetooth").tag("bt"); Text("Wi-Fi").tag("wifi"); Text("Auto").tag("auto")
                }
                LabeledContent("Status", value: mic.status)
                if !mic.peer.isEmpty { LabeledContent("Watch", value: mic.peer) }
                if !mic.path.isEmpty { LabeledContent("Arriving over", value: mic.path) }
                LabeledContent("This phone", value: "\(mic.address) port \(WatchMic.port)")
                Text(mic.wcInfo).font(.caption).foregroundStyle(Theme.muted)
                if mic.listening && mic.mode != "wifi" { LabeledContent("Bluetooth messages from the watch", value: "\(mic.btMessages)") }
            } footer: {
                Text("Pick the same link on the watch (Link: on its start screen), then tap Go live there. Bluetooth needs no Wi-Fi and no call. Wi-Fi finds this phone on the same network; if it doesn't, type the address above into the watch. Auto uses Wi-Fi when it answers, else Bluetooth.")
            }
            Section {
                LabeledContent("Mic gain") {
                    HStack {
                        Slider(value: $mic.gainDb, in: -12...24, step: 1).frame(width: 180)
                        Text("\(mic.gainDb >= 0 ? "+" : "")\(Int(mic.gainDb)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Feedback filter", isOn: $mic.feedbackOn)
                LabeledContent("Notches", value: mic.notches.isEmpty ? "none yet" : mic.notches.map { $0 >= 1000 ? String(format: "%.1f kHz", $0 / 1000) : "\(Int($0)) Hz" }.joined(separator: ", "))
                Button("Reset notches") { mic.resetFeedback() }.disabled(mic.notches.isEmpty)
            } header: { Text("Gain and feedback") } footer: {
                Text("Mic gain is set once for the room. The MIC knob in the mixer is the live volume on top of it; map it to a knob on your controller in Settings → Controller → MIDI learn → Watch mic volume (on the FLX4, the MIC LEVEL knob works). The feedback filter cuts rumble below 100 Hz and drops a narrow notch on any tone that rings steadily for about 0.2 s, up to 8. Ring the room out before the set: raise the gain until it just starts to howl, let it notch, repeat.")
            }
            Section {
                Toggle("Duck tracks when I talk", isOn: $mic.duckOn)
                if mic.duckOn {
                    LabeledContent("Duck by") {
                        HStack {
                            Slider(value: $mic.duckDb, in: -30...(-3), step: 1).frame(width: 160)
                            Text("\(Int(mic.duckDb)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                    Toggle("Mic on only while talking", isOn: $mic.gateOn)
                    LabeledContent("Voice threshold") {
                        HStack {
                            Slider(value: $mic.voiceDb, in: -55...(-15), step: 1).frame(width: 160)
                            Text("\(Int(mic.voiceDb)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                    LabeledContent("Hold") {
                        HStack {
                            Slider(value: $mic.holdS, in: 0.2...2, step: 0.1).frame(width: 160)
                            Text(String(format: "%.1f s", mic.holdS)).monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                    LabeledContent("Hearing you", value: mic.talking ? "YES" : "no")
                }
            } header: { Text("Auto duck") } footer: {
                Text("While you talk, the tracks on the master drop by this much (about 15 ms down, half a second back up) and your voice goes through; headphones and recordings aren't ducked. Talking means louder than the threshold and 10 dB over the room's background (steady music bleeding into the watch doesn't count) for 30 ms. If it ducks on its own, raise the threshold; if it misses quiet words, lower it.")
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
                    LabeledContent("Volume (board)", value: "\(Int(mic.volume * 100))%")
                }
                Section {
                    Picker("Jitter buffer", selection: $mic.targetMs) { ForEach([20, 40, 60, 100, 150], id: \.self) { Text("\($0) ms").tag($0) } }
                    LabeledContent("Buffered now", value: "\(mic.bufferedMs) ms")
                    LabeledContent("Round trip (watch)", value: mic.watchRttMs.map { "\($0) ms" } ?? "—")
                    LabeledContent("Late drops (watch)", value: "\(mic.watchLateDrops)")
                    LabeledContent("Dropouts", value: "\(mic.underruns)")
                    LabeledContent("Lost packets", value: "\(mic.lost)")
                } header: { Text("Link") } footer: {
                    Text("Delay you hear ≈ the watch's own audio buffer + half the round trip + the jitter buffer + this phone's output. Measure the real total with a clap test. Lower the jitter buffer until dropouts start, then go one step up.")
                }
            }
            Section {
                if mic.watchLog.isEmpty { Text("Nothing yet. On the watch: Send log to phone.").foregroundStyle(Theme.muted) }
                else {
                    Text(String(mic.watchLog.suffix(6000))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Button("Copy log") { UIPasteboard.general.string = mic.watchLog }
                }
            } header: { Text("Watch log") }
        }
        .navigationTitle("Watch mic (experiment)")
    }
}
