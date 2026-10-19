// rekordbox XML (File → Export Collection in xml format): reading it (RB.parseXml in tools/rekordbox.js) and
// writing one (exportXml in cratebox.html), so playlists, grids, keys and cues go both ways.
import Foundation

public struct XMLTrack {
    public var id = "", title = "", artist = "", album = "", genre = "", key = ""
    public var bpm = 0.0, duration = 0.0, size = 0, location = "", filename = ""
    public var grid: (bpm: Double, firstBeat: Double, beat: Int)?
    public var marks: [(num: Int, start: Double, end: Double?, type: Int, name: String)] = []
}
public struct XMLNodeEntry { public var name: String, folder: Bool, parent: Int?, tracks: [String], key: Int }

public enum RekordboxXML {
    public enum Failure: Error { case notRekordbox }

    final class P: NSObject, XMLParserDelegate {
        var tracks = [String: XMLTrack](), order = [String]()
        var lists = [XMLNodeEntry]()
        var inCollection = false, inPlaylists = false, sawRoot = false, seenDJ = false
        var cur: XMLTrack?
        var stack = [Int?]()                    // playlist node keys (nil = ROOT)
        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch el {
            case "DJ_PLAYLISTS": seenDJ = true
            case "COLLECTION": inCollection = true
            case "PLAYLISTS": inPlaylists = true
            case "TRACK" where inCollection && cur == nil:
                var t = XMLTrack()
                t.id = a["TrackID"] ?? ""; t.title = a["Name"] ?? ""; t.artist = a["Artist"] ?? ""; t.album = a["Album"] ?? ""; t.genre = a["Genre"] ?? ""; t.key = a["Tonality"] ?? ""
                t.bpm = Double(a["AverageBpm"] ?? "") ?? 0; t.duration = Double(a["TotalTime"] ?? "") ?? 0; t.size = Int(a["Size"] ?? "") ?? 0
                var loc = a["Location"] ?? ""
                if loc.hasPrefix("file://localhost") { loc.removeFirst("file://localhost".count) }
                loc = loc.removingPercentEncoding ?? loc
                t.location = loc
                t.filename = loc.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? loc
                cur = t
            case "TEMPO" where cur != nil && cur!.grid == nil:
                cur!.grid = (Double(a["Bpm"] ?? "") ?? 0, Double(a["Inizio"] ?? "") ?? 0, Int(a["Battito"] ?? "1") ?? 1)
            case "POSITION_MARK" where cur != nil:
                cur!.marks.append((Int(a["Num"] ?? "") ?? -1, Double(a["Start"] ?? "") ?? 0, a["End"].flatMap(Double.init), Int(a["Type"] ?? "0") ?? 0, a["Name"] ?? ""))
            case "NODE" where inPlaylists:
                if !sawRoot { sawRoot = true; stack.append(nil); return }
                let folder = a["Type"] == "0"
                let e = XMLNodeEntry(name: a["Name"] ?? "", folder: folder, parent: stack.last ?? nil, tracks: [], key: lists.count)
                lists.append(e)
                stack.append(e.key)
            case "TRACK" where inPlaylists:
                if let k = stack.last ?? nil, !lists[k].folder, let key = a["Key"] { lists[k].tracks.append(key) }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "COLLECTION": inCollection = false
            case "PLAYLISTS": inPlaylists = false
            case "TRACK" where inCollection: if let t = cur { tracks[t.id] = t; order.append(t.id) }; cur = nil
            case "NODE" where inPlaylists: _ = stack.popLast()
            default: break
            }
        }
    }

    public static func parse(_ data: Data) throws -> (tracks: [String: XMLTrack], order: [String], playlists: [XMLNodeEntry]) {
        let p = P(), x = XMLParser(data: data)
        x.delegate = p
        guard x.parse(), p.seenDJ else { throw Failure.notRekordbox }
        return (p.tracks, p.order, p.lists)
    }

    // ---- writing ----
    public struct ExportTrack { public var id: String, title: String, artist: String, file: String, rel: String, size: Int, duration: Double, bpm: Double, firstBeat: Double?, key: Int, cue: Double?, hot: [Double?]
        public init(id: String, title: String, artist: String, file: String, rel: String, size: Int, duration: Double, bpm: Double, firstBeat: Double?, key: Int, cue: Double?, hot: [Double?]) {
            self.id = id; self.title = title; self.artist = artist; self.file = file; self.rel = rel; self.size = size; self.duration = duration; self.bpm = bpm; self.firstBeat = firstBeat; self.key = key; self.cue = cue; self.hot = hot
        }
    }
    public struct ExportList { public var id: String, name: String, folder: Bool, parent: String?, order: Int, items: [String]
        public init(id: String, name: String, folder: Bool, parent: String?, order: Int, items: [String]) { self.id = id; self.name = name; self.folder = folder; self.parent = parent; self.order = order; self.items = items }
    }
    static let keyXML = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    public static func keyName(_ k: Int) -> String { k < 0 ? "" : keyXML[k % 12] + (k >= 12 ? "m" : "") }
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    /// root: where the music folder lives on the computer rekordbox runs on (rekordbox needs full paths)
    public static func export(_ tracks: [ExportTrack], _ lists: [ExportList], root: String) -> String {
        let tid = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset + 1) })
        let base = root.replacingOccurrences(of: "\\", with: "/")
        func loc(_ t: ExportTrack) -> String {
            let rel = t.rel.split(separator: "/").dropFirst().joined(separator: "/")
            let full = base.isEmpty ? t.rel : "\(base)/\(rel.isEmpty ? t.rel : rel)"
            var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "#?")
            return "file://localhost/" + (String(full.drop { $0 == "/" }).addingPercentEncoding(withAllowedCharacters: allowed) ?? full)
        }
        var out = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<DJ_PLAYLISTS Version=\"1.0.0\">", "  <PRODUCT Name=\"Cratebox\" Version=\"1\" Company=\"Cratebox\"/>", "  <COLLECTION Entries=\"\(tracks.count)\">"]
        for t in tracks {
            let ext = (t.file as NSString).pathExtension.uppercased()
            let attrs: [(String, String)] = [("TrackID", "\(tid[t.id]!)"), ("Name", t.title), ("Artist", t.artist), ("Kind", "\(ext) File"), ("Size", "\(t.size)"),
                ("TotalTime", "\(Int(jsRound(t.duration)))"), ("AverageBpm", String(format: "%.2f", t.bpm)), ("Tonality", keyName(t.key)), ("Location", loc(t))]
            out.append("    <TRACK " + attrs.map { "\($0.0)=\"\(esc($0.1))\"" }.joined(separator: " ") + ">")
            if t.bpm > 0, let fb = t.firstBeat { out.append(String(format: "      <TEMPO Inizio=\"%.3f\" Bpm=\"%.2f\" Metro=\"4/4\" Battito=\"1\"/>", fb, t.bpm)) }
            if let c = t.cue { out.append(String(format: "      <POSITION_MARK Name=\"\" Type=\"0\" Start=\"%.3f\" Num=\"-1\"/>", c)) }
            for (i, h) in t.hot.enumerated() { if let h { out.append(String(format: "      <POSITION_MARK Name=\"\" Type=\"0\" Start=\"%.3f\" Num=\"%d\"/>", h, i)) } }
            out.append("    </TRACK>")
        }
        out += ["  </COLLECTION>", "  <PLAYLISTS>"]
        func node(_ parent: String?, _ ind: String) {
            for p in lists.filter({ $0.parent == parent }).sorted(by: { $0.order < $1.order }) {
                if p.folder {
                    out.append("\(ind)<NODE Type=\"0\" Name=\"\(esc(p.name))\" Count=\"\(lists.filter { $0.parent == p.id }.count)\">")
                    node(p.id, ind + "  ")
                    out.append("\(ind)</NODE>")
                } else {
                    let items = p.items.filter { tid[$0] != nil }
                    out.append("\(ind)<NODE Name=\"\(esc(p.name))\" Type=\"1\" KeyType=\"0\" Entries=\"\(items.count)\">")
                    for id in items { out.append("\(ind)  <TRACK Key=\"\(tid[id]!)\"/>") }
                    out.append("\(ind)</NODE>")
                }
            }
        }
        out.append("    <NODE Type=\"0\" Name=\"ROOT\" Count=\"\(lists.filter { $0.parent == nil }.count)\">")
        node(nil, "      ")
        out += ["    </NODE>", "  </PLAYLISTS>", "</DJ_PLAYLISTS>"]
        return out.joined(separator: "\n")
    }
}
