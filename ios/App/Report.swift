// "Send this session to GitHub" (Settings, the ladybug by Done; Jonah, 2026-11-13): this session's log, a short
// description and a screenshot, as a GitHub issue on zonahbear/Cratebox. The first time it asks for a GitHub key
// (a fine-grained token: Issues + Contents read/write on that repo), kept in this phone's Keychain only, never in
// the app or the repo. The full log and the screenshot go to the repo's `reports` branch (reports/ios/<time>/) and
// the issue links them. Without a key, GitHub's new-issue page opens filled in instead. The issue has the web
// report's marker, so reports.yml collects it into apps/web/reports.txt too.
// The repo is public: the log has track names and messages, never paths outside the app, emails or keys.
import SwiftUI
import UIKit
import PhotosUI
import Security

/// This session's log: the app's messages and what Apple's analysis and USB copies did, with times. Kept in memory
/// (the last 3000 lines) and in Files → Cratebox → Logs, one file per launch
enum AppLog {
    private static let q = DispatchQueue(label: "cratebox.log")
    private static var lines = [String]()
    private static var handle: FileHandle?
    static let started = Date()
    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
    }
    static let file: URL = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return dir.appendingPathComponent("Session \(f.string(from: started)).txt")
    }()
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    static func add(_ s: String) {
        let line = "\(stamp.string(from: Date()))  \(s)"
        q.async {
            lines.append(line)
            if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
            if handle == nil {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: file)
                _ = try? handle?.seekToEnd()
            }
            if let d = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: d) }
        }
    }
    static func all() -> [String] { q.sync { lines } }
}

/// the GitHub key, in the Keychain (this device only)
enum GitHubKey {
    private static let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cratebox.github", kSecAttrAccount as String: "reports"]
    static var value: String? {
        var r: AnyObject?
        var a = q; a[kSecReturnData as String] = true; a[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(a as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ v: String?) {
        SecItemDelete(q as CFDictionary)
        guard let v, !v.isEmpty else { return }
        var a = q; a[kSecValueData as String] = Data(v.utf8); a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }
}

/// the few GitHub REST calls a report needs
enum GitHubReport {
    static let repo = "zonahbear/Cratebox", branch = "reports"
    struct Failure: Error { let code: Int; let text: String }
    static func call(_ method: String, _ path: String, _ key: String, _ json: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)\(path)")!)
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure(code: code, text: String(data: d, encoding: .utf8) ?? "") }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
    /// the reports branch, made from main the first time
    static func ensureBranch(_ key: String) async throws {
        do { _ = try await call("GET", "/git/ref/heads/\(branch)", key) } catch let f as Failure where f.code == 404 {
            let main = try await call("GET", "/git/ref/heads/main", key)
            guard let sha = (main["object"] as? [String: Any])?["sha"] as? String else { throw Failure(code: 0, text: "no main") }
            _ = try await call("POST", "/git/refs", key, ["ref": "refs/heads/\(branch)", "sha": sha])
        }
    }
    static func put(_ path: String, _ data: Data, _ key: String) async throws {
        let p = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        _ = try await call("PUT", "/contents/\(p)", key, ["message": "iOS report: \(path)", "content": data.base64EncodedString(), "branch": branch])
    }
    static func url(_ path: String, raw: Bool) -> String {
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "https://github.com/\(repo)/\(raw ? "raw" : "blob")/\(branch)/\(p)"
    }
}

struct ReportView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var devices: Devices
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL
    @State private var what = ""
    @State private var pick: PhotosPickerItem?
    @State private var shot: UIImage?
    @State private var note = ""
    @State private var askKey = false
    @State private var keyText = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What went wrong? (what you did, what happened)", text: $what, axis: .vertical).lineLimit(3...8)
                } header: { Text("Quick description") }
                Section {
                    PhotosPicker(selection: $pick, matching: .screenshots) {
                        Label(shot == nil ? "Attach a screenshot" : "Change the screenshot", systemImage: "photo")
                    }
                    if let shot {
                        Image(uiImage: shot).resizable().scaledToFit().frame(maxHeight: 160)
                        Button("Remove the screenshot", role: .destructive) { self.shot = nil; pick = nil }
                    }
                } header: { Text("Screenshot") }
                Section {
                    Button { if GitHubKey.value == nil { askKey = true } else { Task { await upload() } } } label: {
                        HStack { Label("Send this session to GitHub", systemImage: "paperplane.fill"); if sending { Spacer(); ProgressView() } }
                    }
                    .disabled(sending || what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if GitHubKey.value != nil { Button("Forget the GitHub key", role: .destructive) { GitHubKey.set(nil); note = "Key removed from this phone" } }
                    ShareLink(item: AppLog.file) { Label("Share the full log…", systemImage: "square.and.arrow.up") }
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(Theme.ok) }
                } footer: {
                    Text("Makes an issue on zonahbear/Cratebox with the description, this session's full log and the screenshot. The first time, it asks for a GitHub key, kept in this phone's Keychain only. The issue is public, and the log has your track names. The full log is also in Files → Cratebox → Logs.")
                }
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("GitHub key", isPresented: $askKey) {
                SecureField("github_pat_…", text: $keyText)
                Button("Save and send") {
                    GitHubKey.set(keyText.trimmingCharacters(in: .whitespacesAndNewlines)); keyText = ""
                    Task { await upload() }
                }
                Button("Open GitHub instead") { send() }
                Button("Cancel", role: .cancel) { keyText = "" }
            } message: {
                Text("A fine-grained token for zonahbear/Cratebox with Issues and Contents: read and write (github.com → Settings → Developer settings → Fine-grained tokens). Kept in this phone's Keychain only.")
            }
            .onChange(of: pick) { _, p in
                guard let p else { return }
                Task { if let d = try? await p.loadTransferable(type: Data.self), let i = UIImage(data: d) { await MainActor.run { shot = i } } }
            }
        }
    }

    /// device, build, settings that matter and library counts, then the log (newest last)
    func details() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let lib = app.library.tracks, apple = AppleMusic.shared
        var out = [
            "Cratebox \(ver) · \(model) · iOS \(UIDevice.current.systemVersion) · \(free / 1_000_000_000) GB free",
            "Mode: \(SuiteState.shared.mode.title) · AI mode \(AIMode.on ? "on" : "off") · decks \(app.core.deckCount)",
            "Library: \(lib.filter { $0.device == nil }.count) on this device, \(lib.filter { $0.device != nil }.count) on sticks (\(devices.list.map(\.name).joined(separator: ", "))) · Apple analysed \(apple.analysed)",
            "Session started \(AppLog.started.formatted(date: .abbreviated, time: .standard))",
        ]
        if let c = CrashLog.latest { out.append("Last crash: \(c.formatted(date: .abbreviated, time: .standard)) (report in Files → Cratebox → Crash reports)") }
        return out.joined(separator: "\n")
    }

    /// with the key: the full log and the screenshot onto the reports branch, then the issue that links them
    @MainActor func upload() async {
        guard let key = GitHubKey.value else { askKey = true; return }
        let text = what.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.add("report: \(text)")
        sending = true; note = "Sending…"
        defer { sending = false }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let dir = "reports/ios/\(f.string(from: Date()))"
        let log = AppLog.all().joined(separator: "\n")
        do {
            try await GitHubReport.ensureBranch(key)
            try await GitHubReport.put("\(dir)/log.txt", Data(((try? String(contentsOf: AppLog.file, encoding: .utf8)) ?? log).utf8), key)
            var shotLine = ""
            if let shot, let jpg = shot.jpegData(compressionQuality: 0.8) {
                try await GitHubReport.put("\(dir)/screenshot.jpg", jpg, key)
                shotLine = "\n### Screenshot\n![screenshot](\(GitHubReport.url("\(dir)/screenshot.jpg", raw: true)))\n"
            }
            // the issue: description, details, the full log's link, and the log's end inline (bodies hold 65k)
            var lines = [String](), room = 50_000
            for l in AppLog.all().reversed() { if room - l.count - 1 < 0 { break }; lines.insert(l, at: 0); room -= l.count + 1 }
            let body = "### What happened\n\(text)\n\n### Details\n```\n\(details())\n```\n\(shotLine)\n### Log\nFull log: \(GitHubReport.url("\(dir)/log.txt", raw: false))\n```\n\(lines.joined(separator: "\n"))\n```\n\n<!-- cratebox-report -->"
            let title = "[Report iOS] " + String((text.split(separator: "\n").first.map(String.init) ?? "Problem").prefix(70))
            let issue = try await GitHubReport.call("POST", "/issues", key, ["title": title, "body": body])
            let n = issue["number"] as? Int ?? 0
            note = "Sent: issue #\(n). Thanks!"
            AppLog.add("report sent: issue #\(n)")
            if let u = (issue["html_url"] as? String).flatMap({ URL(string: $0) }) { openURL(u) }
        } catch let e as GitHubReport.Failure {
            if e.code == 401 { GitHubKey.set(nil); note = "GitHub didn't accept that key: send again to enter a new one" }
            else if e.code == 403 || e.code == 404 { note = "That key can't write to zonahbear/Cratebox (it needs Issues and Contents: read and write). Error \(e.code)" }
            else { note = "GitHub said \(e.code): \(e.text.prefix(120))" }
            AppLog.add("report failed: \(e.code)")
        } catch {
            note = "Couldn't reach GitHub: \(error.localizedDescription)"
        }
    }

    /// without a key: GitHub's new-issue page, filled in (the log's end only: a link holds about 8 kB)
    func send() {
        let text = what.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.add("report: \(text)")
        let title = "[Report iOS] " + String((text.split(separator: "\n").first.map(String.init) ?? "Problem").prefix(70))
        // GitHub's new-issue link carries about 8 kB: the description and details, then as much of the log's end
        // as fits (the whole log is in Files and Share the full log)
        let head = "### What happened\n\(text)\n\n### Details\n```\n\(details())\n```\n\n### Log (latest)\n```\n"
        let tail = "\n```\n" + (shot == nil ? "" : "\n_Screenshot: paste it here._\n") + "\n<!-- cratebox-report -->"
        var log = [String](), room = 6000 - head.count - tail.count
        for l in AppLog.all().reversed() { if room - l.count - 1 < 0 { break }; log.insert(l, at: 0); room -= l.count + 1 }
        let body = head + log.joined(separator: "\n") + tail
        if let shot { UIPasteboard.general.image = shot }
        var c = URLComponents(string: "https://github.com/zonahbear/Cratebox/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        if let u = c.url { openURL(u) }
        note = shot == nil ? "Opened GitHub: press Submit." : "Opened GitHub: tap the description, Paste to add the screenshot, then Submit."
    }
}
