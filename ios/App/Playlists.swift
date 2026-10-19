// Your own playlists and folders, kept on the device (the web app keeps them in the browser). A playlist
// remembers each track's title and file name, so it can show (and later re-find) tracks whose folder
// isn't connected right now.
import Foundation

struct Playlist: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var folder: Bool
    var parent: String?
    var order: Int
    var items: [String]
    var meta: [String: [String: String]]       // track id -> title, artist, file
}

final class Playlists: ObservableObject {
    @Published private(set) var lists: [Playlist] = []
    private let url: URL
    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cratebox/playlists.json")
        if let d = try? Data(contentsOf: url), let l = try? JSONDecoder().decode([Playlist].self, from: d) { lists = l }
    }
    private func save() { if let d = try? JSONEncoder().encode(lists) { try? d.write(to: url, options: .atomic) } }
    func get(_ id: String) -> Playlist? { lists.first { $0.id == id } }
    func children(_ parent: String?) -> [Playlist] { lists.filter { $0.parent == parent }.sorted { ($0.order, $0.name) < ($1.order, $1.name) } }
    func nextName(_ base: String) -> String { var n = 1; while lists.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }; return "\(base) \(n)" }
    @discardableResult func new(_ name: String, folder: Bool = false, parent: String? = nil) -> Playlist {
        let p = Playlist(id: "pl" + UUID().uuidString.prefix(8), name: name, folder: folder, parent: parent, order: children(parent).count, items: [], meta: [:])
        lists.append(p); save(); return p
    }
    private func update(_ id: String, _ f: (inout Playlist) -> Void) { if let k = lists.firstIndex(where: { $0.id == id }) { f(&lists[k]); save() } }
    func rename(_ id: String, _ name: String) { update(id) { $0.name = name } }
    func add(_ tracks: [LibTrack], to id: String, at: Int? = nil) {
        update(id) { p in
            guard !p.folder else { return }
            for t in tracks { p.meta[t.id] = ["title": t.info.title, "artist": t.info.artist, "file": (t.rec.rel as NSString).lastPathComponent] }
            let ids = tracks.map { $0.id }
            p.items.insert(contentsOf: ids, at: min(at ?? p.items.count, p.items.count))
        }
    }
    func remove(at offsets: IndexSet, from id: String) { update(id) { $0.items.remove(atOffsets: offsets) } }
    func move(from: IndexSet, to: Int, in id: String) { update(id) { $0.items.move(fromOffsets: from, toOffset: to) } }
    func moveList(_ id: String, into parent: String?) {
        var x = parent
        while let p = x { if p == id { return }; x = get(p)?.parent }          // no folder into itself
        update(id) { $0.parent = parent; $0.order = children(parent).count }
    }
    func delete(_ id: String) {
        var kill: Set<String> = [id], grew = true
        while grew { grew = false; for x in lists where x.parent.map(kill.contains) == true && !kill.contains(x.id) { kill.insert(x.id); grew = true } }
        lists.removeAll { kill.contains($0.id) }; save()
    }
    func path(_ p: Playlist) -> String { var parts = [p.name]; var x = p.parent; while let id = x, let q = get(id) { parts.insert(q.name, at: 0); x = q.parent }; return parts.joined(separator: " / ") }
}
