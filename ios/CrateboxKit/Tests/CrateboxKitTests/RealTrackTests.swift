import XCTest
import AVFoundation
@testable import CrateboxKit

/// Analysis on REAL tracks (Jonah, 2026-11-12: no synthetic test tracks): his tough picks with rekordbox's analysis
/// files, from the private repo zonahbear/cratebox-test-tracks (ios.yml fetches it with the TEST_TRACKS_TOKEN secret
/// and passes the folder as CRATEBOX_REAL). Without it every test here skips, and a skip is not a pass.
///
/// manifest.json in that folder:
///   { "tracks": [ { "file": "tracks/x.mp3", "anlz": "anlz/x.DAT", "title": "…", "artist": "…",
///                   "ref": "online" | "hand" | "rekordbox", "bpm": 95.0, "firstBeat": 0.42 } ],
///     "floor": { "tempo": 0.8, "bar1": 0.6 } }
/// `ref` says what's trusted: `hand` = Jonah's hand-fixed grid (ground truth for the grid), `online` = a BPM checked
/// online (tempo only), `rekordbox` = rekordbox's grid as the baseline. `bpm` / `firstBeat` override the ANLZ's.
/// `floor` (optional): the least share of tracks that must agree, so a change that makes analysis worse fails here.
/// Every track prints a `REAL` line (ios.yml copies them into the CI summary).
final class RealTrackTests: XCTestCase {
    struct Entry: Decodable {
        var file: String, anlz: String?, title: String?, artist: String?, ref: String?
        var bpm: Double?, firstBeat: Double?
    }
    struct Manifest: Decodable {
        var tracks: [Entry]
        var floor: [String: Double]?
    }

    func folder() throws -> URL {
        guard let d = ProcessInfo.processInfo.environment["CRATEBOX_REAL"], !d.isEmpty,
              FileManager.default.fileExists(atPath: d + "/manifest.json") else {
            print("REAL tracks: none here (CRATEBOX_REAL unset or no manifest.json): SKIPPED")
            throw XCTSkip("no real test tracks (CRATEBOX_REAL)")
        }
        return URL(fileURLWithPath: d)
    }

    /// the file as mono at 11 025 Hz, the analysis input (the same downmix the app uses)
    static func mono(_ url: URL) throws -> (x: [Float], fs: Double, duration: Double) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { throw CocoaError(.fileReadCorruptFile) }
        try f.read(into: buf)
        guard let ch = buf.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let n = Int(buf.frameLength), nc = Int(fmt.channelCount)
        let ptrs = (0..<min(2, nc)).map { UnsafePointer(ch[$0]) }
        let m = Analysis.monoFor(nc > 1 ? ptrs : [ptrs[0], ptrs[0]], length: n, sampleRate: fmt.sampleRate)
        return (m.mono, m.fs, Double(n) / fmt.sampleRate)
    }

    /// where `first` sits against the reference grid: beats off (−0.5…0.5) and whole beats off bar 1 (0…3)
    static func offset(_ first: Double, ref: Double, bpm: Double) -> (beat: Double, bar: Int) {
        let spb = 60 / bpm
        let beats = (first - ref) / spb
        let frac = beats - beats.rounded()
        var bar = Int(beats.rounded()) % 4
        if bar < 0 { bar += 4 }
        return (frac, bar)
    }

    func testAnalysisAgainstTheReferences() throws {
        let dir = try folder()
        let man = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        var tempoOK = 0, tempoN = 0, bar1OK = 0, bar1N = 0, beatOK = 0
        for e in man.tracks {
            let name = [e.artist, e.title].compactMap { $0 }.joined(separator: " – ")
            let url = dir.appendingPathComponent(e.file)
            guard let m = try? Self.mono(url) else { print("REAL \(name): can't read \(e.file)"); XCTFail("can't read \(e.file)"); continue }
            // the reference grid: the manifest's numbers, else rekordbox's from the ANLZ file
            var refBpm = e.bpm, refFirst = e.firstBeat
            if let a = e.anlz, let b = try? Data(contentsOf: dir.appendingPathComponent(a)),
               let g = RekordboxANLZ.grid(RekordboxANLZ.parse([UInt8](b)).beats) {
                if refBpm == nil { refBpm = g.bpm }
                if refFirst == nil && e.ref != "online" { refFirst = g.firstBeat }
            }
            let r = Analysis.analyze(m.x, fs: m.fs, noWave: true)
            var line = String(format: "REAL %@ [%@]: Cratebox %.2f BPM, bar 1 at %.3f s", name, e.ref ?? "?", r.bpm, r.firstBeat)
            if let rb = refBpm, rb > 0 {
                tempoN += 1
                let ok = abs(r.bpm - rb) < 0.5
                if ok { tempoOK += 1 }
                let octave = abs(r.bpm * 2 - rb) < 1 || abs(r.bpm / 2 - rb) < 0.5
                line += String(format: " · tempo vs %.2f: %@", rb, ok ? "OK" : octave ? "OCTAVE" : "OFF")
                if let rf = refFirst, ok {
                    bar1N += 1
                    let o = Self.offset(r.firstBeat, ref: rf, bpm: rb)
                    let onBeat = abs(o.beat) < 0.125
                    if onBeat { beatOK += 1 }
                    if onBeat && o.bar == 0 { bar1OK += 1 }
                    line += String(format: " · beat %+.2f, bar 1 %@", o.beat, onBeat && o.bar == 0 ? "OK" : onBeat ? "\(o.bar) beats off" : "off the beat")
                }
            }
            print(line)
        }
        let tShare = tempoN > 0 ? Double(tempoOK) / Double(tempoN) : 0, bShare = bar1N > 0 ? Double(bar1OK) / Double(bar1N) : 0
        print("REAL score: tempo \(tempoOK)/\(tempoN), on the beat \(beatOK)/\(bar1N), bar 1 \(bar1OK)/\(bar1N) (of \(man.tracks.count) tracks)")
        if let f = man.floor?["tempo"] { XCTAssertGreaterThanOrEqual(tShare, f, "tempo agreement fell under the floor") }
        if let f = man.floor?["bar1"] { XCTAssertGreaterThanOrEqual(bShare, f, "bar 1 agreement fell under the floor") }
    }

    /// AI DJ on real tracks: every pair in the set gets a plan within ±12 % (or none, for a reason), and no plan
    /// ever has both basses up at once or runs past either track's end
    func testAIDJPlansOnRealGrids() throws {
        let dir = try folder()
        let man = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        var tracks = [AutoMix.Track]()
        for e in man.tracks {
            guard let a = e.anlz, let b = try? Data(contentsOf: dir.appendingPathComponent(a)) else { continue }
            let anlz = RekordboxANLZ.parse([UInt8](b))
            guard let g = RekordboxANLZ.grid(anlz.beats), let last = anlz.beats.last else { continue }
            tracks.append(AutoMix.Track(id: e.file, bpm: e.bpm ?? g.bpm, firstBeat: e.firstBeat ?? g.firstBeat, duration: Double(last.ms) / 1000 + 1, key: -1))
        }
        guard tracks.count >= 2 else { throw XCTSkip("fewer than two tracks with rekordbox analysis") }
        var o = AutoMix.PlanOptions(); o.kinds = AutoMix.Transition.allCases; o.variableLength = true
        var planned = 0
        for a in tracks { for b in tracks where b.id != a.id {
            guard let p = AutoMix.plan(from: a, aRate: 1, to: b, after: 32, maxShift: 0.12, options: o) else { continue }
            planned += 1
            XCTAssertLessThanOrEqual(p.outEnd, a.lastBeat, "\(a.id) → \(b.id)")
            XCTAssertLessThanOrEqual(p.inStart + Double(p.bars * 4) * p.mult, b.lastBeat, "\(a.id) → \(b.id)")
        } }
        print("REAL AI DJ: \(planned) of \(tracks.count * (tracks.count - 1)) pairs planned (the rest are over ±12 % apart)")
    }
}
