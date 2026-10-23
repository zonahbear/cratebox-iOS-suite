// Cratebox Mic (personal/heat only): Go live starts the call; while live, the crown sets the level and the big
// button mutes. The numbers under it are for measuring the experiment (round trip, the phone's buffer, dropouts).
import SwiftUI

@main
struct CrateboxMicApp: App {
    @StateObject private var mic = MicCall()
    var body: some Scene { WindowGroup { MicView().environmentObject(mic).onAppear { mic.askForMic() } } }
}

struct MicView: View {
    @EnvironmentObject var mic: MicCall
    @State private var crown = 1.0

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if mic.live && !mic.connected {
                    ProgressView()
                    Text(mic.status).font(.footnote).multilineTextAlignment(.center)
                    stats
                    Button("Cancel", role: .destructive) { mic.end() }
                } else if mic.live {
                    Button { mic.muted.toggle() } label: {
                        Text(mic.lost ? "NO LINK" : mic.muted ? "MUTED" : "LIVE").font(.system(size: 30, weight: .heavy, design: .rounded)).frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .tint(mic.lost ? .orange : mic.muted ? .gray : .red)
                    .buttonStyle(.borderedProminent)
                    HStack {
                        Text("Level \(Int(crown * 100))%").font(.system(.footnote, design: .rounded)).monospacedDigit()
                        Spacer()
                        meter
                    }
                    .focusable()
                    .digitalCrownRotation($crown, from: 0, through: 2, by: 0.05, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                    .onChange(of: crown) { _, v in mic.gain = v }
                    stats
                    Button("End", role: .destructive) { mic.end() }
                } else {
                    Button { mic.goLive() } label: {
                        Text("Go live").font(.system(size: 24, weight: .bold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .tint(.red).buttonStyle(.borderedProminent)
                    Text(mic.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    TextField("Phone address (blank = find it)", text: $mic.host).font(.footnote)
                    Text("Phone: Cratebox HEAT → Settings → Apple Watch as a mic → Listen.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { crown = mic.gain }
    }

    private var meter: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.3))
                Capsule().fill(mic.level > 0.9 ? Color.red : Color.green).frame(width: g.size.width * CGFloat(min(1, mic.level)))
            }
        }
        .frame(width: 70, height: 6)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mic.link)
            Text("Round trip " + (mic.rttMs.map { "\($0) ms" } ?? "—"))
            Text("Phone buffer " + (mic.phoneBufferMs.map { "\($0) ms" } ?? "—") + " · drops \(mic.phoneDropouts) · lost \(mic.phoneLost)")
            Text("Mic \(mic.inputInfo)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
