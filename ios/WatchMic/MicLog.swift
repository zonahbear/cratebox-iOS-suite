// Cratebox Mic (personal/heat only): a small log that survives a crash. Each line goes to a file straight away;
// on the next launch the old file becomes "last session", which the watch shows and can send to the phone.
import Foundation

enum MicLog {
    private static let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let url = dir.appendingPathComponent("mic-log.txt")
    static let prevURL = dir.appendingPathComponent("mic-log-prev.txt")
    private static let lock = NSLock()
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// at launch: keep the last session's log, start a new one, and note any uncaught exception before dying
    static func start() {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: prevURL)
            try? FileManager.default.moveItem(at: url, to: prevURL)
        }
        NSSetUncaughtExceptionHandler { e in MicLog.add("EXCEPTION \(e.name.rawValue): \(e.reason ?? "")") }
        add("launch")
    }

    static func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let line = Data("\(fmt.string(from: Date())) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    static var previous: String { (try? String(contentsOf: prevURL, encoding: .utf8)) ?? "" }
    static var current: String { lock.lock(); defer { lock.unlock() }; return (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
