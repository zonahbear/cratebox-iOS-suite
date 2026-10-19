import XCTest
@testable import CrateboxKit

/// The Swift export.pdb code against the web app's (tools/rekordbox.js): Fixtures/write-*.pdb were
/// written by the JS writer from Fixtures/export.pdb (a real rekordbox USB export, from pyrekordbox's
/// test data, MIT licence) with the nodes in write-*.json. The Swift writer must give the same bytes.
final class PDBTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!
        return [UInt8](try Data(contentsOf: url))
    }
    struct Node: Decodable { let id: UInt32; let parent: UInt32; let folder: Bool; let name: String; let unk: UInt32?; let tracks: [UInt32] }
    struct Read: Decodable { let tracks: [PDBTrack]; let playlists: [PDBPlaylist] }

    func testReadsLikeTheWebApp() throws {
        let db = PDB.parse(try fixture("export.pdb"))
        let want = try JSONDecoder().decode(Read.self, from: Data(try fixture("read.json")))
        XCTAssertEqual(db.tracks, want.tracks)
        XCTAssertEqual(db.playlists, want.playlists)
        XCTAssertEqual(db.tracks.count, 6)
        let d1 = db.tracks.first { $0.title == "Demo Track 1" }!
        XCTAssertEqual(d1.artist, "Loopmasters"); XCTAssertEqual(d1.key, "Fm"); XCTAssertEqual(d1.bpm, 128)
        XCTAssertEqual(d1.path, "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3")
    }

    func testWritesByteForByteLikeTheWebApp() throws {
        let src = try fixture("export.pdb")
        for c in ["same", "edit", "big"] {
            let nodes = try JSONDecoder().decode([Node].self, from: Data(try fixture("write-\(c).json")))
                .map { PDBPlaylist(id: $0.id, parent: $0.parent, unk: $0.unk ?? 0, folder: $0.folder, name: $0.name, tracks: $0.tracks) }
            let out = try PDB.writePlaylists(src, nodes)
            let want = try fixture("write-\(c).pdb")
            XCTAssertEqual(out.count, want.count, c)
            let firstDiff = zip(out, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            XCTAssertNil(firstDiff, "\(c): first differing byte at \(String(describing: firstDiff))")
        }
        XCTAssertEqual(src, try fixture("export.pdb"), "input untouched")
    }

    func testRefusesBadInput() {
        XCTAssertThrowsError(try PDB.writePlaylists([UInt8](repeating: 0, count: 8192), []))
        let src = (try? fixture("export.pdb")) ?? []
        XCTAssertThrowsError(try PDB.writePlaylists(src, [PDBPlaylist(id: 1, name: "a"), PDBPlaylist(id: 1, name: "b")]))
        XCTAssertThrowsError(try PDB.writePlaylists(src, [PDBPlaylist(id: 2, parent: 99, name: "x")]))
    }

    func testStrings() {
        for s in ["", "Peak time", String(repeating: "x", count: 126), String(repeating: "x", count: 127), "Ünïcödé 🎧"] {
            XCTAssertEqual(PDB.string(Bytes(b: PDB.stringBytes(s)), 0), s)
        }
    }
}
