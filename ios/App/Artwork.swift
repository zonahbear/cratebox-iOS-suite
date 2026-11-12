// Album art. Library rows (the library and the controller's browser) show rekordbox's small icon for stick
// tracks (export.pdb's artwork table → PIONEER/Artwork/…/a1.jpg), and the file's own cover for other tracks.
// Decks show the full-size cover embedded in the file, shrunk to fit, for every track, stick tracks included.
// rekordbox's a1_m.jpg, then its a1.jpg, are used only when the file has no cover (Jonah, 2026-11-12). With
// no art anywhere, or when the track itself is missing, a greyscale record is drawn. Images are decoded off
// the main thread at the size they're drawn and kept in a cache that iOS empties under memory pressure.
// Always on (no setting: Jonah, 2026-11-12).
import SwiftUI
import ImageIO
import AVFoundation
import CrateboxKit

@MainActor
final class Artwork {
    static let shared = Artwork()
    enum Size: String {
        case icon, deck
        /// longest side in pixels it's decoded to (library icons are 22 pt, deck art up to 160 pt; 3x screens)
        var px: Int { self == .icon ? 72 : 480 }
    }
    private let cache = NSCache<NSString, UIImage>()
    private var none = Set<String>()                       // tracks known to have no art (at this size)
    private var running = [String: Task<UIImage?, Never>]()
    init() { cache.countLimit = 600 }

    private func key(_ id: String, _ s: Size) -> String { s.rawValue + "|" + id }
    func cached(_ id: String, _ s: Size) -> UIImage? { cache.object(forKey: key(id, s) as NSString) }

    func image(for t: LibTrack, _ s: Size) async -> UIImage? {
        let k = key(t.id, s)
        if let i = cache.object(forKey: k as NSString) { return i }
        if none.contains(k) { return nil }
        if let r = running[k] { return await r.value }
        // where to look, worked out here (the device list lives on the main thread)
        var files = [URL]()
        if let p = t.rb?.artwork, let d = Devices.shared.device(of: t) {
            func on(_ path: String) -> URL { d.root.appendingPathComponent(String(path.drop { $0 == "/" })) }
            if s == .deck { files.append(on(PDBTrack.bigArtwork(p))) }
            files.append(on(p))
        }
        let audio = Devices.shared.url(for: t) ?? Devices.shared.app?.library.fileURL(t)
        let px = s.px, fileFirst = s == .deck        // decks: the file's full-size cover before rekordbox's copies
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            func inFile() async -> UIImage? {
                guard let a = audio, let data = await Artwork.embedded(a) else { return nil }
                return Artwork.decode(data: data, px: px)
            }
            if fileFirst, let i = await inFile() { return i }
            for f in files { if let i = Artwork.decode(url: f, px: px) { return i } }
            return fileFirst ? nil : await inFile()
        }
        running[k] = task
        let img = await task.value
        running[k] = nil
        if let img { cache.setObject(img, forKey: k as NSString) } else { none.insert(k) }
        return img
    }
    nonisolated static func decode(url: URL, px: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumb(src, px)
    }
    nonisolated static func decode(data: Data, px: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumb(src, px)
    }
    nonisolated static func thumb(_ src: CGImageSource, _ px: Int) -> UIImage? {
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: px]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary).map { UIImage(cgImage: $0) }
    }
    /// the cover in the file's tags (ID3 APIC, MP4 covr, FLAC/Vorbis picture: whatever AVFoundation reads)
    nonisolated static func embedded(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for i in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let d = try? await i.load(.dataValue) { return d }
        }
        return nil
    }
}

/// A track's cover, square, filling its frame; a greyscale record while it loads, when there's none, or when
/// the track itself isn't available.
struct ArtworkView: View {
    let track: LibTrack?
    var size: Artwork.Size = .icon
    @State private var img: UIImage?
    var body: some View {
        let r = size == .deck ? 5.0 : 3.0
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous).fill(Theme.raise)
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                RecordGlyph()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .task(id: track?.id) {
            guard let t = track else { img = nil; return }
            img = Artwork.shared.cached(t.id, size)
            if img == nil { img = await Artwork.shared.image(for: t, size) }
        }
        .accessibilityHidden(true)
    }
}

/// The stand-in cover: a grey vinyl record (grooves, a lighter label, the spindle hole), drawn so it scales
/// from a 21 pt icon to a deck-sized square.
struct RecordGlyph: View {
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height) * 0.86
            ZStack {
                Circle().fill(Color(white: 0.13))
                ForEach([0.92, 0.80, 0.68], id: \.self) { r in
                    Circle().stroke(Color(white: 0.3), lineWidth: max(0.5, d * 0.012)).frame(width: d * r, height: d * r)
                }
                Circle().fill(Color(white: 0.55)).frame(width: d * 0.36, height: d * 0.36)
                Circle().fill(Color(white: 0.13)).frame(width: d * 0.06, height: d * 0.06)
            }
            .frame(width: d, height: d)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}
