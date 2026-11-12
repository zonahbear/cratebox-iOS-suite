import XCTest
@testable import CrateboxKit

/// Next-track suggestions: the same cases and numbers as the checks in tools/next_track.js.
final class NextTrackTests: XCTestCase {
    // Camelot nA / nB → key index (0-11 major, 12-23 minor): 8A = A minor, 8B = C major, 1B = B major
    func A(_ n: Int) -> Int { [8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1][n - 1] + 12 }
    func B(_ n: Int) -> Int { [11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4][n - 1] }
    let e = 1e-6

    func testCamelotTable() {
        for n in 1...12 {
            XCTAssertEqual(Keys.camelot(A(n))?.label, "\(n)A")
            XCTAssertEqual(Keys.camelot(B(n))?.label, "\(n)B")
        }
    }

    func testKeyMoves() {
        XCTAssertEqual(NextTrack.keyScore(A(8), A(8)).s, 1, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(8), A(9)).s, 0.9, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(8), A(7)).s, 0.9, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(12), A(1)).s, 0.9, accuracy: e)       // wraps round
        XCTAssertEqual(NextTrack.keyScore(A(8), B(8)).s, 0.85, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(8), B(9)).s, 0.6, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(B(9), A(8)).s, 0.6, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(8), A(10)).s, 0.6, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(8), A(3)).s, 0.55, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(A(8), A(2)).s, 0.1, accuracy: e)
        XCTAssertEqual(NextTrack.keyScore(-1, A(8)).s, 0.5, accuracy: e)
        // every move Keys.mixes allows scores at least 0.85
        for a in 0..<24 { for b in 0..<24 where Keys.mixes(a, b) { XCTAssertGreaterThanOrEqual(NextTrack.keyScore(a, b).s, 0.85) } }
    }

    func testTempoFitFollowsTheDeckRange() {
        var f = NextTrack.tempoFit(124, 128, range: 6)!
        XCTAssertEqual(f.mult, 1); XCTAssertEqual(f.pct, (124.0 / 128 - 1) * 100, accuracy: e)
        f = NextTrack.tempoFit(124, 64, range: 6)!                               // half time: the 62 under 124
        XCTAssertEqual(f.mult, 0.5); XCTAssertEqual(f.pct, (124.0 / 128 - 1) * 100, accuracy: e)
        XCTAssertNil(NextTrack.tempoFit(140, 92, range: 10))                       // Jonah's 140/92: same as SYNC
        XCTAssertEqual(NextTrack.tempoFit(140, 92, range: 100)!.mult, 0.5)
        XCTAssertEqual(NextTrack.tempoScore(NextTrack.tempoFit(128, 128, range: 10)!, range: 10), 1, accuracy: e)
        XCTAssertEqual(NextTrack.tempoScore(NextTrack.tempoFit(124, 128, range: 6)!, range: 6), 1 - (4.0 / 128 * 100) / 6, accuracy: e)
        XCTAssertEqual(NextTrack.tempoScore(NextTrack.tempoFit(140, 92, range: 100)!, range: 100), 0, accuracy: e)
    }

    func testPitchMovesTheKeyWithoutMasterTempo() {
        let now = NextTrack.Item(id: "a", bpm: 128, key: A(8))
        let cand = NextTrack.Item(id: "b", bpm: 120.75, key: A(8))                 // +6% = +1 semitone
        let r = NextTrack.score(now: now, cand: cand, .init(range: 10, keylock: false))!
        XCTAssertEqual(r.keyAfter, A(3)); XCTAssertTrue(r.why[1].contains("pitched"))
        XCTAssertEqual(NextTrack.score(now: now, cand: cand, .init(range: 10, keylock: true))!.keyAfter, A(8))
    }

    func testWeightsRenormaliseAndRanking() {
        let now = NextTrack.Item(id: "a", bpm: 128, key: A(8))
        let r = NextTrack.score(now: now, cand: .init(id: "c", bpm: 128, key: A(9)), .init(range: 10, keylock: true))!
        XCTAssertEqual(r.score, (1 * 0.35 + 0.9 * 0.3) / 0.65 * 100, accuracy: e)
        XCTAssertNil(NextTrack.score(now: now, cand: .init(id: "a", bpm: 128, key: A(8)), .init(range: 10, keylock: true)))

        let lib: [NextTrack.Item] = [
            .init(id: "clash", bpm: 128, key: A(2)), .init(id: "perfect", bpm: 128, key: A(8)),
            .init(id: "played", bpm: 128, key: A(8)), .init(id: "far", bpm: 150, key: A(8)), .init(id: "half", bpm: 64, key: A(9)),
        ]
        let s = NextTrack.suggest(now: now, lib, .init(range: 10, keylock: true, played: ["played"]))
        XCTAssertEqual(s.map(\.id), ["perfect", "half", "clash", "played"])        // "far" (+17%) isn't offered
        XCTAssertEqual(s[1].score, (1 * 0.85 * 0.35 + 0.9 * 0.3) / 0.65 * 100, accuracy: e)
        XCTAssertEqual(s[2].score, (1 * 0.35 + 0.1 * 0.3) / 0.65 * 100 * 0.6, accuracy: e)
        XCTAssertEqual(s[3].score, 30, accuracy: e)
    }

    func testEnergyAndSound() {
        XCTAssertEqual(NextTrack.energyScore(0.5, 0.58, flow: 1), 1, accuracy: e)
        XCTAssertEqual(NextTrack.energyScore(0.5, 0.5, flow: 0), 1, accuracy: e)
        XCTAssertEqual(NextTrack.energyScore(0.5, 0.9, flow: 0), 0, accuracy: e)
        XCTAssertEqual(NextTrack.soundScore([0.5, 0.3, 0.2], [0.5, 0.3, 0.2]), 1, accuracy: e)
        XCTAssertEqual(NextTrack.soundScore([1, 0, 0], [0, 1, 0]), 0, accuracy: e)
        let w = Waveform(duration: 10, wps: 10, peak: [UInt8](repeating: 200, count: 100), rms: [UInt8](repeating: 128, count: 100),
                         low: [UInt8](repeating: 100, count: 100), mid: [UInt8](repeating: 60, count: 100), high: [UInt8](repeating: 40, count: 100))
        let p = NextTrack.profile(w)
        XCTAssertEqual(p.bands[0], 0.5, accuracy: e)
        XCTAssertEqual(p.energy, 128.0 / 255 * 0.75 + 0.25, accuracy: e)
    }

    func testSharesFromApplesAnalysisReplaceTheBandSplit() {
        XCTAssertEqual(NextTrack.shareScore([0.9, 0.8, 0.7], [0.9, 0.8, 0.7]), 1, accuracy: e)
        XCTAssertEqual(NextTrack.shareScore([1, 1, 1], [0, 0, 0]), 0, accuracy: e)
        XCTAssertEqual(NextTrack.shareScore([0.9, 0.5, 0.5], [0.3, 0.5, 0.5]), 0.8, accuracy: e)
        XCTAssertEqual(NextTrack.energy(lufs: -10), 0.5, accuracy: e)
        XCTAssertEqual(NextTrack.energy(lufs: -2), 1, accuracy: e)
        // a vocal track after a vocal track outranks an instrumental one, all else equal
        let now = NextTrack.Item(id: "now", bpm: 140, key: A(8), shares: [0.9, 0.8, 0.8])
        let vocal = NextTrack.Item(id: "v", bpm: 140, key: A(8), shares: [0.8, 0.8, 0.8])
        let inst = NextTrack.Item(id: "i", bpm: 140, key: A(8), shares: [0.0, 0.8, 0.8])
        let o = NextTrack.Options(range: 6, keylock: true)
        XCTAssertGreaterThan(NextTrack.score(now: now, cand: vocal, o)!.score, NextTrack.score(now: now, cand: inst, o)!.score)
    }
}
