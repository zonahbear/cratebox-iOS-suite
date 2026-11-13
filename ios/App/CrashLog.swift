// Crash reports from iOS (MetricKit): after Cratebox crashes, iOS hands the next launch a report with the call
// stack. It's saved in Files → On My iPhone → Cratebox → Crash reports, so it can be sent along with a bug report
// (TestFlight's own crash logs can't be read from outside App Store Connect). Nothing is sent anywhere.
import Foundation
import MetricKit

final class CrashLog: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashLog()
    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Crash reports", isDirectory: true)
    }
    /// when the newest saved report was made (Settings shows it)
    static var latest: Date? {
        let t = UserDefaults.standard.double(forKey: "cb.crash.latest")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func start() { MXMetricManager.shared.add(self) }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            guard let c = p.crashDiagnostics, !c.isEmpty else { continue }
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "Crash \(f.string(from: p.timeStampEnd)).json"
            try? p.jsonRepresentation().write(to: Self.dir.appendingPathComponent(name), options: .atomic)
            UserDefaults.standard.set(p.timeStampEnd.timeIntervalSince1970, forKey: "cb.crash.latest")
        }
    }
}
