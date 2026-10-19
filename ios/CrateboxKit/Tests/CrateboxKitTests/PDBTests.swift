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

final class ANLZTests: XCTestCase {
    func file(_ n: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/anlz/" + n, withExtension: nil)!)) }
    /// the same numbers tests/test_rekordbox.js checks on the web app's parser
    func testDemoTrack1() throws {
        let dat = RekordboxANLZ.parse(try file("ANLZ0000.DAT")), ext = RekordboxANLZ.parse(try file("ANLZ0000.EXT"))
        XCTAssertEqual(dat.beats.count, 368)
        let g = RekordboxANLZ.grid(dat.beats)!
        XCTAssertEqual(g.bpm, 128); XCTAssertEqual(g.firstBeat, 0.025, accuracy: 1e-9)
        var a = ext; a.beats = dat.beats
        let ph = RekordboxANLZ.phrases(a)!
        XCTAssertEqual(ph.count, 19); XCTAssertEqual(ph[0].start, 0.025, accuracy: 1e-9)
        XCTAssertTrue(ph.allSatisfy { $0.bars >= 1 })
    }
    func testKeyNames() {
        XCTAssertEqual(RekordboxANLZ.keyIndex("Fm"), 17); XCTAssertEqual(RekordboxANLZ.keyIndex("Am"), 21); XCTAssertEqual(RekordboxANLZ.keyIndex("8A"), 21)
        XCTAssertEqual(RekordboxANLZ.keyIndex("C"), 0); XCTAssertEqual(RekordboxANLZ.keyIndex("Ebm"), 15); XCTAssertEqual(RekordboxANLZ.keyIndex(""), -1)
    }
}

/// rekordbox XML both ways, on the file tests/test_playlists.py imports into the web app
final class XMLTests: XCTestCase {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DJ_PLAYLISTS Version="1.0.0"><PRODUCT Name="rekordbox" Version="6.8.5" Company="AlphaTheta"/>
    <COLLECTION Entries="2">
    <TRACK TrackID="11" Name="House Groove" Artist="Test Artist" Kind="WAV File" Size="13230044" TotalTime="60" AverageBpm="126.00" Tonality="Am"
     Location="file://localhost/C:/Users/jonah/Music/Test%20Artist%20-%20House%20Groove%20126.wav">
     <TEMPO Inizio="0.367" Bpm="126.00" Metro="4/4" Battito="1"/>
     <POSITION_MARK Name="" Type="0" Start="0.367" Num="-1"/>
     <POSITION_MARK Name="drop" Type="0" Start="15.600" Num="0" Red="40" Green="226" Blue="20"/>
     <POSITION_MARK Name="" Type="0" Start="30.000" Num="3"/>
    </TRACK>
    <TRACK TrackID="12" Name="Ghost Track" Artist="Nobody" Kind="MP3 File" Size="12345" TotalTime="200" AverageBpm="140.00" Tonality="8A"
     Location="file://localhost/C:/Users/jonah/Music/ghost.mp3"><TEMPO Inizio="0.1" Bpm="140.00" Metro="4/4" Battito="1"/></TRACK>
    </COLLECTION>
    <PLAYLISTS><NODE Type="0" Name="ROOT" Count="2">
     <NODE Type="0" Name="Bass" Count="1"><NODE Name="Wobbles" Type="1" KeyType="0" Entries="2"><TRACK Key="11"/><TRACK Key="12"/></NODE></NODE>
     <NODE Name="Warmup" Type="1" KeyType="0" Entries="1"><TRACK Key="11"/></NODE>
    </NODE></PLAYLISTS></DJ_PLAYLISTS>
    """
    func testImport() throws {
        let x = try RekordboxXML.parse(Data(xml.utf8))
        XCTAssertEqual(x.tracks.count, 2)
        let h = x.tracks["11"]!
        XCTAssertEqual(h.filename, "Test Artist - House Groove 126.wav"); XCTAssertEqual(h.size, 13230044)
        XCTAssertEqual(h.grid!.bpm, 126); XCTAssertEqual(h.grid!.firstBeat, 0.367)
        XCTAssertEqual(h.marks.count, 3); XCTAssertEqual(RekordboxANLZ.keyIndex(h.key), 21)
        XCTAssertEqual(x.playlists.map { $0.name }, ["Bass", "Wobbles", "Warmup"])
        XCTAssertEqual(x.playlists[1].parent, 0); XCTAssertNil(x.playlists[2].parent)
        XCTAssertEqual(x.playlists[1].tracks, ["11", "12"])
        XCTAssertThrowsError(try RekordboxXML.parse(Data("<foo/>".utf8)))
    }
    func testExportReadsBack() throws {
        let t = RekordboxXML.ExportTrack(id: "a", title: "House Groove 126", artist: "Test Artist", file: "Test Artist - House Groove 126.wav", rel: "music/Test Artist - House Groove 126.wav",
                                         size: 13230044, duration: 75, bpm: 126, firstBeat: 0.367, key: 21, cue: 0.367, hot: [15.6, nil, nil, 30, nil, nil, nil, nil])
        let s = RekordboxXML.export([t], [RekordboxXML.ExportList(id: "f", name: "Saturday", folder: true, parent: nil, order: 0, items: []),
                                          RekordboxXML.ExportList(id: "p", name: "Peak time", folder: false, parent: "f", order: 0, items: ["a", "missing"])], root: "C:\\Users\\jonah\\Music")
        XCTAssertTrue(s.contains("Location=\"file://localhost/C:/Users/jonah/Music/Test%20Artist%20-%20House%20Groove%20126.wav\""), s)
        let x = try RekordboxXML.parse(Data(s.utf8))
        XCTAssertEqual(x.tracks["1"]?.grid?.bpm, 126); XCTAssertEqual(x.tracks["1"]?.key, "Am")
        XCTAssertEqual(x.playlists.map { $0.name }, ["Saturday", "Peak time"]); XCTAssertEqual(x.playlists[1].tracks, ["1"])
        XCTAssertEqual(x.tracks["1"]?.marks.count, 3)
    }
}
