// Performance Mode's EJECT. iOS gives apps no unmount call (Disk Arbitration's DADiskUnmount is macOS and Mac
// Catalyst only) and no notice when a drive is plugged in. So "connected" here means a drive Cratebox was given
// in Files once (a rekordbox stick added with + USB, a music folder on a drive, the stick open in Cratebox USB)
// that answers right now (checked every 2 s), and "eject" means letting go of it: every deck stopped, its tracks
// unloaded, saves finished and flushed to the stick, and every security-scoped access to it ended. After that
// nothing in Cratebox has it open, and unplugging is safe. An ejected drive comes back by itself once it has
// been unplugged and plugged in again.
import Foundation

struct Drive: Identifiable, Equatable {
    let id: String          // the folder's id, or "usb-mode" for a stick open only in Cratebox USB
    let name: String
}

final class DriveWatch: ObservableObject {
    static let shared = DriveWatch()
    weak var app: AppModel?
    @Published private(set) var drives: [Drive] = []
    @Published private(set) var ejecting: String?
    @Published var notice: Notice?
    struct Notice: Identifiable { let id = UUID(); let title: String; let message: String }
    private var timer: Timer?
    private var external = [String: Bool]()     // folder id: on a drive, not the phone's own storage
    private var demo = false, demoGone = false

    func start() {
        demo = CommandLine.arguments.contains("-demo")
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        // CI screenshots: EJECT pressed with deck 1 playing, or (-stopped) with every deck stopped
        if demo && CommandLine.arguments.contains("-eject") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if CommandLine.arguments.contains("-stopped") { self.app?.core.decks.forEach { if $0.playing { $0.setPlaying(false) } } }
                if let d = self.drives.first { self.eject(d) }
            }
        }
    }

    // ---- which drives are here ----
    func check() {
        guard let app else { return }
        let lib = app.library, devs = Devices.shared
        for f in lib.folders where f.device || lib.offline[f.id] != nil || isExternal(f) {
            if lib.offline[f.id] != nil {
                // ejected or unplugged: look for it with an access that's ended straight away
                if !probe(f) { lib.seenGone(f) }
                else if lib.offline[f.id] == true {
                    lib.reconnect(f)
                    if f.device, let u = lib.url(of: f) { devs.mount(u, folder: f) }
                }
            } else if let u = lib.url(of: f), (try? u.checkResourceIsReachable()) != true {
                // pulled out without EJECT: loaded decks keep playing (their audio is in memory)
                if let d = devs.list.first(where: { $0.id == f.id }) {
                    devs.drop(d, unplugged: true)
                    app.status("\(d.name) was unplugged without EJECT. Loaded decks keep playing.", 8)
                } else { lib.release(f, unplugged: true) }
            }
        }
        var list = devs.list.map { Drive(id: $0.id, name: $0.name) }
        for f in lib.folders where !f.device && lib.offline[f.id] == nil && external[f.id] == true { list.append(Drive(id: f.id, name: f.name)) }
        if let u = app.usbMade, let r = u.root, !devs.list.contains(where: { $0.root.standardizedFileURL == r.standardizedFileURL }) {
            list.append(Drive(id: "usb-mode", name: u.name))
        }
        if demo && !demoGone && list.isEmpty { list.append(Drive(id: "demo", name: "DJ USB")) }
        if list != drives { drives = list }
    }
    /// a folder on another volume than the app's own storage: a USB drive, an SD card (or a server)
    private func isExternal(_ f: MusicFolder) -> Bool {
        if let e = external[f.id] { return e }
        guard let u = app?.library.url(of: f), let a = volume(u),
              let b = volume(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) else { return false }
        let e = !a.isEqual(b)
        external[f.id] = e
        return e
    }
    private func volume(_ u: URL) -> NSObject? { (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
    private func probe(_ f: MusicFolder) -> Bool {
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: f.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        let ok = u.startAccessingSecurityScopedResource()
        defer { if ok { u.stopAccessingSecurityScopedResource() } }
        return (try? u.checkResourceIsReachable()) == true
    }

    // ---- EJECT ----
    func eject(_ drive: Drive) {
        guard ejecting == nil else { return }
        if let why = stillPlaying() { notice = Notice(title: "Stop the music first", message: why + " Stop every deck, then press EJECT again to unload and eject \(drive.name)."); return }
        ejecting = drive.id
        finish(drive, tries: 0)
    }
    private func stillPlaying() -> String? {
        guard let app else { return nil }
        var on = app.core.decks.filter { $0.playing }.map { "deck \($0.i + 1)" }
        if let u = app.usbMade, u.preview.deck.playing { on.append("the Cratebox USB player") }
        guard let last = on.last else { return nil }
        let s = on.count == 1 ? last : on.dropLast().joined(separator: ", ") + " and " + last
        return s.prefix(1).uppercased() + s.dropFirst() + (on.count == 1 ? " is playing." : " are playing.")
    }
    private func finish(_ drive: Drive, tries: Int) {
        guard let app else { return }
        if let why = stillPlaying() {
            ejecting = nil
            notice = Notice(title: "Stop the music first", message: why + " Stop every deck, then press EJECT again to unload and eject \(drive.name)."); return
        }
        let lib = app.library
        let dev = Devices.shared.list.first { $0.id == drive.id }
        let folder = lib.folders.first { $0.id == drive.id }
        let usb = app.usbMade.flatMap { u -> USBSession? in
            guard let r = u.root else { return nil }
            return drive.id == "usb-mode" || dev?.root.standardizedFileURL == r.standardizedFileURL ? u : nil
        }
        // the decks holding one of its tracks
        let mine = Set(lib.tracks.filter { $0.rec.folder == drive.id }.map { ObjectIdentifier($0.info) })
        let decks = app.core.decks.filter { d in d.track.map { mine.contains(ObjectIdentifier($0)) } ?? false }
        // still reading or writing it (a deck loading, an analysis, a Cratebox USB save): wait for that
        if decks.contains(where: { $0.loading }) || lib.analysing(in: drive.id) || usb?.writing == true {
            if tries > 60 {
                ejecting = nil
                notice = Notice(title: "Not ejected", message: "Cratebox is still reading or writing \(drive.name). It's not safe to unplug yet: wait a moment and press EJECT again.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.finish(drive, tries: tries + 1) }
            return
        }
        decks.forEach { $0.unload() }
        let n = decks.count
        let out: (Bool) -> Void = { ok in
            self.ejecting = nil
            guard ok else {
                self.notice = Notice(title: "Not ejected", message: "Cratebox couldn't finish saving to \(drive.name), so it's not safe to unplug yet. Try EJECT again in a moment.")
                return
            }
            if drive.id == "demo" { self.demoGone = true }
            self.check()
            app.status("\(drive.name) ejected: safe to unplug", 8)
            self.notice = Notice(title: "Safe to remove \(drive.name)",
                                 message: (n > 0 ? "\(n == 1 ? "Its track was" : "Its tracks were") unloaded from the deck\(n == 1 ? "" : "s"). " : "")
                                    + "Cratebox has saved everything and let go of \(drive.name), so you can unplug it now. Plug it in again and it comes back by itself.")
        }
        if let dev {
            Devices.shared.eject(dev, quiet: true) { ok in
                if ok { usb?.eject() }
                out(ok)
            }
        } else if let usb {
            usb.eject()
            out(usb.root == nil)
        } else {
            if let folder { lib.release(folder, unplugged: false) }
            out(true)
        }
    }
}
