// export.pdb health checks for Cratebox USB's preflight scan, and a few track fields the reader leaves out
// (bit rate, bit depth). Read-only: walks the same structure PDB.parse does, but reports what's wrong
// instead of skipping over it.
import Foundation

public struct PDBTrackFormat: Equatable { public var bitrate: Int, bitDepth: Int, sampleRate: Int }

extension PDB {
    /// per track id: bit rate (kbps), bit depth and sample rate as rekordbox stored them
    public static func trackFormats(_ data: [UInt8]) -> [UInt32: PDBTrackFormat] {
        let d = Bytes(b: data)
        var out = [UInt32: PDBTrackFormat]()
        rows(d, PDBPage.tracks.rawValue) { o in
            guard o + 94 <= d.count else { return }
            out[d.u32(o + 72)] = PDBTrackFormat(bitrate: Int(d.u32(o + 48)), bitDepth: Int(d.u16(o + 82)), sampleRate: Int(d.u32(o + 8)))
        }
        return out
    }

    /// What's structurally wrong with an export.pdb (empty when nothing is): the header, every table's
    /// page chain (in the file, the right type, no loops, ending at its last page) and every row's
    /// position, and each track row's strings.
    public static func problems(_ data: [UInt8]) -> [String] {
        var out = [String]()
        let d = Bytes(b: data)
        guard d.count >= 28 else { return ["export.pdb is too short to be a rekordbox database (\(d.count) bytes)"] }
        let PS = Int(d.u32(4)), NT = Int(d.u32(8))
        guard PS >= 512, PS <= 65536, PS & (PS - 1) == 0 else { return ["export.pdb has an impossible page size (\(PS))"] }
        guard NT >= 1, NT <= 64, 28 + NT * 16 <= d.count else { return ["export.pdb has an impossible table count (\(NT))"] }
        if d.count % PS != 0 { out.append("export.pdb isn't a whole number of pages (\(d.count) bytes, pages of \(PS)): it may have been cut short") }
        let pages = d.count / PS
        var types = Set<UInt32>()
        for t in 0..<NT {
            let tp = 28 + t * 16
            let type = d.u32(tp), first = Int(d.u32(tp + 8)), last = Int(d.u32(tp + 12))
            types.insert(type)
            var page = first, seen = Set<Int>(), steps = 0
            while true {
                if page >= pages { out.append("table \(type): its page chain points past the end of the file (page \(page))"); break }
                if seen.contains(page) { out.append("table \(type): its page chain loops back on itself at page \(page)"); break }
                seen.insert(page)
                let p = page * PS
                if d.u32(p + 8) != type { out.append("table \(type): page \(page) belongs to table \(d.u32(p + 8))"); break }
                let packed = Int(d.u8(p + 24)) | Int(d.u8(p + 25)) << 8 | Int(d.u8(p + 26)) << 16
                let numOffsets = packed & 0x1fff, flags = d.u8(p + 27)
                if flags & 0x40 == 0 && numOffsets > 0 && numOffsets != 0x1fff {
                    let groups = (numOffsets - 1) / 16 + 1
                    if groups * 0x24 > PS - 40 { out.append("table \(type): page \(page) claims more rows than fit"); }
                    else {
                        for g in 0..<groups {
                            let base = p + PS - g * 0x24
                            let present = d.u16(base - 4)
                            for r in 0..<16 where g * 16 + r < numOffsets && (present >> r) & 1 == 1 {
                                let ofs = Int(d.u16(base - (6 + 2 * r)))
                                if 40 + ofs >= PS - groups * 0x24 { out.append("table \(type): a row on page \(page) starts outside the page's data"); break }
                            }
                        }
                    }
                }
                if page == last { break }
                page = Int(d.u32(p + 12)); steps += 1
                if steps > pages { out.append("table \(type): page chain never reaches its last page"); break }
            }
        }
        for need in [PDBPage.tracks, .artists, .playlistTree, .playlistEntries] where !types.contains(need.rawValue) {
            out.append("export.pdb has no \(need) table")
        }
        // every track row's strings inside the file, and its path present
        rows(d, PDBPage.tracks.rawValue) { o in
            guard o + 94 + 2 * 21 <= d.count else { out.append("a track row is cut off at the end of its page"); return }
            for k in [14, 17, 19, 20] {
                let at = o + Int(d.u16(o + 94 + 2 * k))
                if at >= d.count { out.append("track \(d.u32(o + 72)): a text field points outside the file"); return }
            }
            if string(d, o + Int(d.u16(o + 94 + 2 * 20))).isEmpty { out.append("track \(d.u32(o + 72)) has no file path") }
        }
        return out
    }
}

extension RekordboxANLZ {
    /// rekordbox's colour detail waveform (PWV5 in the .EXT file: 150 columns a second, each a colour and a
    /// height), as Cratebox's own Waveform so the existing views draw it straight away, before any decoding.
    /// The colour is spread over the low / mid / high bands (red / green / blue in the RGB style).
    public static func waveform(ext b: [UInt8], duration: Double) -> Waveform? {
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }
        func tag(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }
        guard b.count >= 12, u32(0) == tag("PMAI") else { return nil }
        var pos = u32(4)
        while pos + 12 <= b.count {
            let four = u32(pos), lenHeader = u32(pos + 4), lenTag = u32(pos + 8)
            if lenTag < 12 { break }
            if four == tag("PWV5") {
                let entryBytes = u32(pos + 12), n = u32(pos + 16), s = pos + lenHeader
                guard entryBytes == 2, n > 0, s + 2 * n <= b.count else { return nil }
                // PWV5 is 150 columns a second; Cratebox's waveform keeps whole columns per second
                let wps = 150
                var peak = [UInt8](repeating: 0, count: n), low = peak, mid = peak, high = peak, rms = peak
                for i in 0..<n {
                    let v = Int(b[s + 2 * i]) << 8 | Int(b[s + 2 * i + 1])
                    let red = v >> 13 & 7, green = v >> 10 & 7, blue = v >> 7 & 7, height = v >> 2 & 0x1f
                    let h = UInt8(min(255, height * 255 / 31))
                    peak[i] = h; rms[i] = UInt8(Int(h) * 7 / 10)
                    low[i] = UInt8(min(255, red * Int(h) / 7)); mid[i] = UInt8(min(255, green * Int(h) / 7)); high[i] = UInt8(min(255, blue * Int(h) / 7))
                }
                return Waveform(duration: duration > 0 ? duration : Double(n) / Double(wps), wps: wps, peak: peak, rms: rms, low: low, mid: mid, high: high)
            }
            pos += lenTag
        }
        return nil
    }
}
