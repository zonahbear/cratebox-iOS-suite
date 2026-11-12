import XCTest
@testable import CrateboxKit

/// AI mode's comparison of Apple's beats and bars with a grid we trust, and the stored form of Apple's results.
/// No framework needed: the Apple side is made up here.
final class AppleFeaturesTests: XCTestCase {
    /// Apple's beats/bars for an even grid at `bpm`, bar 1 at `first`, `beats` long
    func apple(bpm: Double, first: Double, beats n: Int = 256, giveBpm: Bool = true) -> AppleFeatures {
        var f = AppleFeatures()
        let p = 60 / bpm
        f.beats = (0..<n).map { first + Double($0) * p }
        f.bars = stride(from: 0, to: n, by: 4).map { first + Double($0) * p }
        f.bpm = giveBpm ? bpm : nil
        return f
    }

    func testSameGridAgrees() {
        let r = GridCompare.compare(.init(bpm: 128, firstBeat: 0.5), apple: apple(bpm: 128, first: 0.5))
        XCTAssertTrue(r.agrees)
        XCTAssertEqual(r.tempoRatio!, 1, accuracy: 1e-9)
        XCTAssertEqual(r.beatOffsetMs!, 0, accuracy: 1e-6)
        XCTAssertEqual(r.barShift, 0); XCTAssertEqual(r.barShare!, 1, accuracy: 1e-9)
        XCTAssertEqual(r.beatsOnGrid!, 1, accuracy: 1e-9)
    }
    func testBarOneTwoBeatsLate() {
        // Apple's bars start two beats after ours: the beats agree, the bars don't
        let p = 60 / 124.0
        let r = GridCompare.compare(.init(bpm: 124, firstBeat: 1.0), apple: apple(bpm: 124, first: 1.0 + 2 * p))
        XCTAssertEqual(r.beatOffsetMs!, 0, accuracy: 1e-6)
        XCTAssertEqual(r.barShift, 2)
        XCTAssertFalse(r.agrees)
    }
    func testSmallBeatOffsetIsMeasuredNotABarShift() {
        // 20 ms late everywhere: a beat offset, bars still on our bar 1
        let r = GridCompare.compare(.init(bpm: 125, firstBeat: 0.2), apple: apple(bpm: 125, first: 0.22))
        XCTAssertEqual(r.beatOffsetMs!, 20, accuracy: 0.01)
        XCTAssertEqual(r.barShift, 0)
        XCTAssertTrue(r.agrees)
    }
    func testDoubleTimeIsCompared() {
        let r = GridCompare.compare(.init(bpm: 87, firstBeat: 0), apple: apple(bpm: 174, first: 0))
        XCTAssertEqual(r.tempoRatio!, 2, accuracy: 1e-9)
        XCTAssertEqual(r.tempoMult, 2); XCTAssertFalse(r.sameTempo)
        XCTAssertEqual(r.beatOffsetMs!, 0, accuracy: 1e-6)
        XCTAssertEqual(r.beatsOnGrid!, 1, accuracy: 1e-9)
        XCTAssertEqual(r.barShift, 0)
        XCTAssertTrue(r.agrees)
    }
    func testHalfTimeIsCompared() {
        // the usual case for 140 bass music: Apple counts 70. Its beats are every second one of ours, its bars two of ours
        let r = GridCompare.compare(.init(bpm: 140, firstBeat: 0.3), apple: apple(bpm: 70, first: 0.3))
        XCTAssertEqual(r.tempoMult, 0.5)
        XCTAssertEqual(r.beatOffsetMs!, 0, accuracy: 1e-6)
        XCTAssertEqual(r.barShift, 0); XCTAssertEqual(r.barShare!, 1, accuracy: 1e-9)
        XCTAssertTrue(r.agrees)
        // Apple's half-time beats on our off-beats (2 and 4): on the grid, but its bars start on our beat 2
        let p = 60 / 140.0
        let s = GridCompare.compare(.init(bpm: 140, firstBeat: 0.3), apple: apple(bpm: 70, first: 0.3 + p))
        XCTAssertEqual(s.beatOffsetMs!, 0, accuracy: 1e-6)
        XCTAssertEqual(s.barShift, 1)
        XCTAssertFalse(s.agrees)
    }
    func testOtherTempoRatiosAreReportedNotCompared() {
        let r = GridCompare.compare(.init(bpm: 180, firstBeat: 0), apple: apple(bpm: 60, first: 0))
        XCTAssertEqual(r.tempoRatio!, 1 / 3.0, accuracy: 1e-9)
        XCTAssertNil(r.tempoMult); XCTAssertNil(r.beatOffset); XCTAssertNil(r.barShift)
        XCTAssertFalse(r.agrees)
    }
    func testTempoFromBeatsWhenAppleGivesNone() {
        let f = apple(bpm: 140, first: 0.1, giveBpm: false)
        XCTAssertEqual(f.tempo!, 140, accuracy: 1e-6)
        XCTAssertTrue(GridCompare.compare(.init(bpm: 140, firstBeat: 0.1), apple: f).agrees)
    }
    func testRekordboxBeatByBeatGrid() {
        // a grid that changes tempo halfway (rekordbox's beat list, bar 1 at beat index 4)
        var b = [Double](), t = 0.0
        for i in 0..<200 { b.append(t); t += i < 100 ? 0.5 : 0.48 }
        let g = GridCompare.Grid(bpm: 120, firstBeat: b[4], beats: b, beat0: 4)
        XCTAssertEqual(g.position(b[4]), 0, accuracy: 1e-9)
        XCTAssertEqual(g.position(b[150]), 146, accuracy: 1e-9)
        XCTAssertEqual(g.position((b[150] + b[151]) / 2), 146.5, accuracy: 1e-9)
        // Apple: the same beats, bars from beat index 4
        var f = AppleFeatures()
        f.beats = Array(b[4...]); f.bars = stride(from: 4, to: 200, by: 4).map { b[$0] }; f.bpm = 120
        let r = GridCompare.compare(g, apple: f)
        XCTAssertEqual(r.barShift, 0)
        XCTAssertEqual(r.beatsOnGrid!, 1, accuracy: 1e-9)
    }
    func testKeyHeardLongestAndShares() {
        var f = AppleFeatures()
        f.keys = [.init(0, 30, 21), .init(30, 200, 9), .init(200, 220, 21)]      // A minor 50 s, A major 170 s
        XCTAssertEqual(f.key, 9)
        f.keys = []
        XCTAssertEqual(f.key, -1)
        f.present["vocal"] = [.init(10, 40), .init(100, 130)]
        XCTAssertEqual(f.share("vocal", duration: 300)!, 0.2, accuracy: 1e-9)
        XCTAssertNil(f.share("drum", duration: 300))
    }
    func testBinAveragesAndHolds() {
        let v = AppleFeatures.bin([(0.1, 1), (0.3, 3), (1.2, 4)], step: 0.5, duration: 2)
        XCTAssertEqual(v, [2, 2, 4, 4])
    }
    func testStoredFormRoundTrips() throws {
        var f = apple(bpm: 128, first: 0.5, beats: 16)
        f.keys = [.init(0, 60, 21)]; f.present["vocal"] = [.init(1, 2)]; f.activity["vocal"] = [0, 0.5]; f.lufs = -8.2
        let g = try JSONDecoder().decode(AppleFeatures.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(f, g)
    }

    // ---- a grid from Apple's beats ----
    func testGridFromEvenBeats() {
        let g = apple(bpm: 128, first: 0.5).grid(near: 128)!
        XCTAssertEqual(g.bpm, 128, accuracy: 1e-9)
        XCTAssertEqual(g.firstBeat, 0.5, accuracy: 1e-6)
    }
    func testGridFoldsHalfTimeToTheTempoWeHave() {
        // Apple counts 70 on a 140 track, its first bar 3 of our bars in
        let p = 60 / 140.0
        let g = apple(bpm: 70, first: 0.3 + 12 * p).grid(near: 140)!
        XCTAssertEqual(g.bpm, 140, accuracy: 1e-9)
        XCTAssertEqual(g.firstBeat, 0.3, accuracy: 1e-6)
        // no tempo to go by: folded into 80..<160
        XCTAssertEqual(apple(bpm: 70, first: 0.3).grid()!.bpm, 140, accuracy: 1e-9)
        XCTAssertEqual(apple(bpm: 174, first: 0).grid()!.bpm, 87, accuracy: 1e-9)
        XCTAssertEqual(apple(bpm: 174, first: 0).grid(near: 174)!.bpm, 174, accuracy: 1e-9)
        // or into Settings → Decks → BPM range
        XCTAssertEqual(apple(bpm: 174, first: 0).grid(range: (88, 175))!.bpm, 174, accuracy: 1e-9)
        XCTAssertEqual(apple(bpm: 87, first: 0).grid(range: (88, 175))!.bpm, 174, accuracy: 1e-9)
        XCTAssertEqual(apple(bpm: 70, first: 0).grid(range: (88, 175))!.bpm, 140, accuracy: 1e-9)
    }
    func testGridBarOneFollowsApplesBars() {
        // beats from 0.1, but Apple's bars start on its third beat
        var f = apple(bpm: 120, first: 0.1)
        f.bars = stride(from: 2, to: 256, by: 4).map { 0.1 + Double($0) * 0.5 }
        XCTAssertEqual(f.grid(near: 120)!.firstBeat, 1.1, accuracy: 1e-6)
    }
    func testGridSurvivesJitterAndAMissedBeat() {
        var f = apple(bpm: 126, first: 0.2)
        for i in f.beats.indices { f.beats[i] += (i % 2 == 0 ? 0.004 : -0.004) }
        f.beats.remove(at: 100)
        let g = f.grid(near: 126)!
        XCTAssertEqual(g.bpm, 126, accuracy: 0.01)
        XCTAssertEqual(g.firstBeat, 0.2, accuracy: 0.01)
    }
    func testNoGridWhenTheTempoWanders() {
        var f = AppleFeatures(), t = 0.0
        for i in 0..<200 { f.beats.append(t); t += 0.5 + 0.1 * sin(Double(i) / 7) }
        XCTAssertNil(f.grid())
        XCTAssertNil(apple(bpm: 120, first: 0, beats: 8).grid())
    }

    // ---- mix points ----
    func testMixPoints() {
        // 128 BPM, bar 1 at 0: a bar is 1.875 s, a phrase of 8 bars 15 s. 300 s long.
        // drums from 30 s to 270 s, vocals from 60 s to 210 s
        var f = AppleFeatures()
        f.present["drum"] = [.init(30, 270)]; f.present["vocal"] = [.init(60, 210)]
        let r = MixPoints.suggest(f, bpm: 128, firstBeat: 0, duration: 300)
        XCTAssertEqual(r.mixIn!, 30, accuracy: 1e-6)             // the first phrase with drums
        XCTAssertEqual(r.inBars, 16)                             // two clean phrases before the vocal
        XCTAssertEqual(r.mixOut!, 240, accuracy: 1e-6)           // vocals end at 210: the last four phrases are clean
        XCTAssertEqual(r.outBars, 32)
    }
    func testMixPointsNeedAppleToSaySomething() {
        let r = MixPoints.suggest(AppleFeatures(), bpm: 128, firstBeat: 0, duration: 300)
        XCTAssertNil(r.mixIn); XCTAssertNil(r.mixOut)
        // vocals all the way through: no clean way out
        var f = AppleFeatures()
        f.present["drum"] = [.init(0, 300)]; f.present["vocal"] = [.init(0, 300)]
        let v = MixPoints.suggest(f, bpm: 128, firstBeat: 0, duration: 300)
        XCTAssertNil(v.mixIn); XCTAssertNil(v.mixOut)
    }
}
