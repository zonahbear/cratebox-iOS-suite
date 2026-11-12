import XCTest
@testable import CrateboxKit

/// "Ask the library": the model's answer is cleaned up by SmartFilter.checked before anything is filtered.
final class SmartFilterTests: XCTestCase {
    // key numbers: 0-11 major (C...B), 12-23 minor; A minor = 8A, C major = 8B, E minor = 9A
    let aMinor = 12 + 9, cMajor = 0, eMinor = 12 + 4, fSharpMajor = 6

    func testCheckedCleansTheAnswer() {
        let f = SmartFilter.checked(words: [" acid ", "", String(repeating: "x", count: 50)], bpmMin: 128, bpmMax: 124,
                                    keys: ["8a", "9 A", "13B", "Am", "8A"], minMinutes: 0, maxMinutes: 7, fitsPlaying: false, playing: nil)
        XCTAssertEqual(f.words, ["acid"])
        XCTAssertEqual(f.bpmMin, 124); XCTAssertEqual(f.bpmMax, 128)       // swapped
        XCTAssertEqual(f.keys, ["8A", "9A"])                                // junk and repeats dropped
        XCTAssertNil(f.minMinutes); XCTAssertEqual(f.maxMinutes, 7)
        XCTAssertEqual(f.summary, "“acid” · 124–128 BPM · 8A 9A · under 7 min")
    }

    func testNonsenseIsDroppedNotGuessed() {
        let f = SmartFilter.checked(words: [], bpmMin: 0, bpmMax: 900, keys: ["Z"], minMinutes: -1, maxMinutes: 500, fitsPlaying: false, playing: nil)
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.summary, "everything")
    }

    func testMatches() {
        var f = SmartFilter(); f.bpmMin = 124; f.bpmMax = 128; f.keys = ["8A", "8B"]; f.maxMinutes = 7
        XCTAssertTrue(f.matches(title: "Ok", artist: "", bpm: 126, key: aMinor, duration: 400))
        XCTAssertTrue(f.matches(title: "Ok", artist: "", bpm: 128, key: cMajor, duration: 420))
        XCTAssertFalse(f.matches(title: "Fast", artist: "", bpm: 130, key: aMinor, duration: 400))
        XCTAssertFalse(f.matches(title: "Other key", artist: "", bpm: 126, key: fSharpMajor, duration: 400))
        XCTAssertFalse(f.matches(title: "Long", artist: "", bpm: 126, key: aMinor, duration: 421))
        XCTAssertFalse(f.matches(title: "Not analysed", artist: "", bpm: nil, key: -1, duration: 400))
        var w = SmartFilter(); w.words = ["Burial", "kode"]
        XCTAssertTrue(w.matches(title: "Archangel", artist: "Burial", bpm: nil, key: -1, duration: 0))
        XCTAssertTrue(w.matches(title: "Kode9 dub", artist: "", bpm: nil, key: -1, duration: 0))
        XCTAssertFalse(w.matches(title: "Something", artist: "Else", bpm: nil, key: -1, duration: 0))
    }

    func testFitsWhatsPlaying() {
        let f = SmartFilter.checked(words: [], bpmMin: 0, bpmMax: 0, keys: [], minMinutes: 0, maxMinutes: 0,
                                    fitsPlaying: true, playing: (bpm: 125, key: aMinor))
        XCTAssertEqual(f.bpmMin, 118); XCTAssertEqual(f.bpmMax, 133)       // ±6 %, rounded
        XCTAssertEqual(Set(f.keys), ["7A", "8A", "9A", "8B"])              // same as the KEY column's highlight
        XCTAssertTrue(f.matches(title: "", artist: "", bpm: 124, key: eMinor, duration: 300))
        // an explicit tempo in the same request wins over the playing deck's
        let g = SmartFilter.checked(words: [], bpmMin: 140, bpmMax: 140, keys: [], minMinutes: 0, maxMinutes: 0,
                                    fitsPlaying: true, playing: (bpm: 125, key: aMinor))
        XCTAssertEqual(g.bpmMin, 140); XCTAssertEqual(g.bpmMax, 140); XCTAssertEqual(g.keys.count, 4)
        // nothing playing: "fits what's playing" adds nothing
        XCTAssertTrue(SmartFilter.checked(words: [], bpmMin: 0, bpmMax: 0, keys: [], minMinutes: 0, maxMinutes: 0, fitsPlaying: true, playing: nil).isEmpty)
    }
}
