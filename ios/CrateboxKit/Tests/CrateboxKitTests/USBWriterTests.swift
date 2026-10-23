import XCTest
@testable import CrateboxKit

/// The cue, beat grid and track info writers, each read back with the readers the rest of Cratebox USB uses:
/// ANLZ files and export.pdb from the copy of a real rekordbox stick, OneLibrary from the SQLCipher fixture.
/// Then the whole thing (plan → apply) on a temporary copy of the stick, locked and unlocked.
final class USBWriterTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!))
    }
    func stickFile(_ rel: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: USBTests.stick.appendingPathComponent(rel))) }
    static let demo1 = "PIONEER/USBANLZ/P016/0000875E/ANLZ0000", demo2 = "PIONEER/USBANLZ/P053/0001D21F/ANLZ0000"
    func tags(_ b: [UInt8]) throws -> [String] { try RekordboxANLZ.split(b).tags.map { $0.name } }
    func tagBytes(_ b: [UInt8], _ name: String) throws -> [[UInt8]] { try RekordboxANLZ.split(b).tags.filter { $0.name == name }.map { $0.bytes } }

    // ---- ANLZ: cues ----
    let cues = [
        ANLZCuePoint(hot: 1, ms: 15000, comment: "Drop"),
        ANLZCuePoint(hot: 2, ms: 30000, loopMs: 31875),
        ANLZCuePoint(hot: 4, ms: 45000, comment: "Ünïcödé 🎧", color: ANLZHotCueColor(code: 0x2a, r: 0xff, g: 0x80, b: 0x00)),
        ANLZCuePoint(hot: 8, ms: 60000),
        ANLZCuePoint(hot: 0, ms: 25),
        ANLZCuePoint(hot: 0, ms: 90000, loopMs: 93750, comment: "Breakdown loop"),
    ]
    func testNoCuesRewritesTheFileByteForByte() throws {
        // the stick's cue lists are empty: writing no cues must give the same file
        for f in [USBWriterTests.demo1, USBWriterTests.demo2] {
            for ext in ["DAT", "EXT"] {
                let b = try stickFile(f + "." + ext)
                XCTAssertEqual(try RekordboxANLZ.writeCues(b, []), b, "\(f).\(ext)")
            }
        }
    }
    func testWritesCuesAndReadsThemBack() throws {
        let dat = try stickFile(USBWriterTests.demo1 + ".DAT"), ext = try stickFile(USBWriterTests.demo1 + ".EXT")
        let d2 = try RekordboxANLZ.writeCues(dat, cues), e2 = try RekordboxANLZ.writeCues(ext, cues)
        // the .DAT: hot cues A-C only, as the older players read it
        let a = RekordboxANLZ.parse(d2)
        XCTAssertEqual(a.hot, [ANLZCue(hot: 1, ms: 15000, loopMs: nil), ANLZCue(hot: 2, ms: 30000, loopMs: 31875)])
        XCTAssertEqual(a.memory, [ANLZCue(hot: 0, ms: 25, loopMs: nil), ANLZCue(hot: 0, ms: 90000, loopMs: 93750)])
        // the .EXT: all eight, with comments and colours
        let e = RekordboxANLZ.parse(e2)
        XCTAssertEqual(e.hot.map { $0.hot }, [1, 2, 4, 8])
        XCTAssertEqual(RekordboxANLZ.cuePoints(e2), cues.filter { $0.hot > 0 } + cues.filter { $0.hot == 0 })
        let c = RekordboxANLZ.cues(e)
        XCTAssertEqual(c.cue, 0.025)
        XCTAssertEqual(c.hot, [15, 30, nil, 45, nil, nil, nil, 60])
        // every other tag exactly as it was, the file length in the header right
        for (x, y) in [(dat, d2), (ext, e2)] {
            XCTAssertEqual(try tags(x), try tags(y))
            for (p, q) in zip(try RekordboxANLZ.split(x).tags, try RekordboxANLZ.split(y).tags) where p.name != "PCOB" && p.name != "PCO2" { XCTAssertEqual(p.bytes, q.bytes, p.name) }
            XCTAssertEqual(Int(y[8]) << 24 | Int(y[9]) << 16 | Int(y[10]) << 8 | Int(y[11]), y.count)
        }
        // the entries as crate-digger lays them out
        let hotPCOB = try tagBytes(d2, "PCOB")[0]
        XCTAssertEqual(Array(hotPCOB[12..<24]), [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2])
        XCTAssertEqual(Array(hotPCOB[24..<28]), Array("PCPT".utf8))
        XCTAssertEqual(hotPCOB.count, 24 + 2 * 0x38)
        // writing the same again changes nothing; writing none puts the file back
        XCTAssertEqual(try RekordboxANLZ.writeCues(e2, cues), e2)
        XCTAssertEqual(try RekordboxANLZ.writeCues(e2, []), ext)
        XCTAssertEqual(try RekordboxANLZ.writeCues(d2, []), dat)
    }
    func testRefusesCuesItCantWrite() throws {
        let dat = try stickFile(USBWriterTests.demo1 + ".DAT")
        XCTAssertThrowsError(try RekordboxANLZ.writeCues(dat, [ANLZCuePoint(hot: 9, ms: 1)]))
        XCTAssertThrowsError(try RekordboxANLZ.writeCues(dat, [ANLZCuePoint(hot: 1, ms: 1), ANLZCuePoint(hot: 1, ms: 2)]))
        XCTAssertThrowsError(try RekordboxANLZ.writeCues(dat, [ANLZCuePoint(hot: 0, ms: 500, loopMs: 400)]))
        XCTAssertThrowsError(try RekordboxANLZ.writeCues(Array(dat.prefix(100)), []))
        XCTAssertThrowsError(try RekordboxANLZ.writeCues([UInt8](repeating: 0, count: 64), []))
        // a file without the cue lists: nothing to replace, so no write
        var noCues = try RekordboxANLZ.split(dat)
        noCues.tags.removeAll { $0.name == "PCOB" }
        XCTAssertThrowsError(try RekordboxANLZ.writeCues(RekordboxANLZ.join(noCues.header, noCues.tags.map { $0.bytes }), [])) {
            XCTAssertEqual($0 as? ANLZWriteError, .missingTag("PCOB"))
        }
    }

    // ---- ANLZ: grid ----
    func testRewritingTheSameGridGivesTheSameFile() throws {
        for f in [USBWriterTests.demo1, USBWriterTests.demo2] {
            let dat = try stickFile(f + ".DAT")
            XCTAssertEqual(try RekordboxANLZ.writeGrid(dat, RekordboxANLZ.parse(dat).beats), dat, f)
        }
    }
    func testConstantGrid() throws {
        let g = try RekordboxANLZ.constantGrid(bpm: 128, firstBeat: 0.5, duration: 10)
        // 0.5 s is a downbeat: one beat (the bar's 4th) comes before it
        XCTAssertEqual(g[0], ANLZBeat(n: 4, bpm: 128, ms: 31))
        XCTAssertEqual(g[1], ANLZBeat(n: 1, bpm: 128, ms: 500))
        XCTAssertEqual(g[2].n, 2); XCTAssertEqual(g[5].n, 1)
        XCTAssertEqual(g.count, Int((10 - 0.03125) / 0.46875) + 1)
        XCTAssertTrue(g.allSatisfy { $0.ms < 10000 })
        let r = RekordboxANLZ.grid(g)!
        XCTAssertEqual(r.bpm, 128); XCTAssertEqual(r.firstBeat, 0.5)
        XCTAssertThrowsError(try RekordboxANLZ.constantGrid(bpm: 0, firstBeat: 0, duration: 10))
        XCTAssertThrowsError(try RekordboxANLZ.constantGrid(bpm: 128, firstBeat: 20, duration: 10))
        // the stick's own grid for Demo Track 1, rebuilt: same tempo and downbeat, every beat within a ms
        let dat = try stickFile(USBWriterTests.demo1 + ".DAT")
        let have = RekordboxANLZ.parse(dat).beats
        let mine = try RekordboxANLZ.constantGrid(bpm: 128, firstBeat: 0.025, duration: 172.1)
        XCTAssertEqual(mine.count, have.count)
        for (a, b) in zip(mine, have) { XCTAssertEqual(a.n, b.n); XCTAssertEqual(a.bpm, b.bpm); XCTAssertLessThanOrEqual(abs(Int(a.ms) - Int(b.ms)), 1) }
    }
    func testWritesAGridAndReadsItBack() throws {
        let dat = try stickFile(USBWriterTests.demo1 + ".DAT"), ext = try stickFile(USBWriterTests.demo1 + ".EXT")
        let grid = try RekordboxANLZ.constantGrid(bpm: 127.5, firstBeat: 0.112, duration: 172)
        let d2 = try RekordboxANLZ.writeGrid(dat, grid)
        let back = RekordboxANLZ.parse(d2)
        XCTAssertEqual(back.beats, grid)
        XCTAssertEqual(RekordboxANLZ.grid(back.beats)?.bpm, 127.5)
        XCTAssertEqual(RekordboxANLZ.grid(back.beats)!.firstBeat, 0.112, accuracy: 1e-9)
        // the header words of PQTZ kept, everything else untouched
        XCTAssertEqual(Array(try tagBytes(d2, "PQTZ")[0][12..<20]), Array(try tagBytes(dat, "PQTZ")[0][12..<20]))
        XCTAssertEqual(try tags(d2), try tags(dat))
        for (p, q) in zip(try RekordboxANLZ.split(dat).tags, try RekordboxANLZ.split(d2).tags) where p.name != "PQTZ" { XCTAssertEqual(p.bytes, q.bytes, p.name) }
        // the .EXT has no PQTZ, and loses PQT2 (it would disagree with the new grid); nothing else changes
        XCTAssertTrue(try tags(ext).contains("PQT2"))
        let e2 = try RekordboxANLZ.writeGrid(ext, grid)
        XCTAssertEqual(try tags(e2), try tags(ext).filter { $0 != "PQT2" })
        XCTAssertEqual(try RekordboxANLZ.split(e2).tags.map { $0.bytes }, try RekordboxANLZ.split(ext).tags.filter { $0.name != "PQT2" }.map { $0.bytes })
        XCTAssertNotNil(RekordboxANLZ.waveform(ext: e2, duration: 172), "the colour waveform still reads")
        // cues and grid together, in either order
        XCTAssertEqual(try RekordboxANLZ.writeCues(RekordboxANLZ.writeGrid(dat, grid), cues), try RekordboxANLZ.writeGrid(RekordboxANLZ.writeCues(dat, cues), grid))
        XCTAssertThrowsError(try RekordboxANLZ.writeGrid(dat, [grid[1], grid[0]]))
    }

    // ---- export.pdb: track info ----
    func testNoTrackEditsGiveTheSameFile() throws {
        let src = try fixture("export.pdb")
        XCTAssertEqual(try PDB.writeTracks(src, [:]), src)
        XCTAssertEqual(try PDB.writeTracks(src, [1: PDBTrackEdit()]), src)
    }
    func testRatingAndBPMArePatchedInPlace() throws {
        let src = try fixture("export.pdb")
        let out = try PDB.writeTracks(src, [2: PDBTrackEdit(rating: 4, bpm: 121.5)])
        XCTAssertEqual(out.count, src.count)
        let diff = zip(src, out).enumerated().filter { $0.element.0 != $0.element.1 }.map { $0.offset }
        XCTAssertLessThanOrEqual(diff.count, 5, "the rating byte and the tempo word, nothing else")
        let t = PDB.parse(out).tracks.first { $0.id == 2 }!
        XCTAssertEqual(t.rating, 4); XCTAssertEqual(t.bpm, 121.5)
    }
    func testWritesTrackInfoAndReadsItBack() throws {
        let src = try fixture("export.pdb")
        let before = PDB.parse(src)
        let edits: [UInt32: PDBTrackEdit] = [
            1: PDBTrackEdit(title: "Demo Track 1 (Cratebox Edit)", artist: "Loopmasters", album: "Demo Album", genre: "House", comment: "peak time", rating: 5),
            3: PDBTrackEdit(title: "Hörn – ünïcödé 🎧", artist: "Foley Dept", genre: "House"),
            6: PDBTrackEdit(comment: String(repeating: "long comment ", count: 20)),
        ]
        let out = try PDB.writeTracks(src, edits)
        XCTAssertEqual(PDB.problems(out), [])
        let after = PDB.parse(out)
        let t1 = after.tracks.first { $0.id == 1 }!, t3 = after.tracks.first { $0.id == 3 }!, t6 = after.tracks.first { $0.id == 6 }!
        XCTAssertEqual(t1.title, "Demo Track 1 (Cratebox Edit)"); XCTAssertEqual(t1.artist, "Loopmasters"); XCTAssertEqual(t1.album, "Demo Album")
        XCTAssertEqual(t1.genre, "House"); XCTAssertEqual(t1.comment, "peak time"); XCTAssertEqual(t1.rating, 5)
        XCTAssertEqual(t3.title, "Hörn – ünïcödé 🎧"); XCTAssertEqual(t3.artist, "Foley Dept"); XCTAssertEqual(t3.genre, "House")
        XCTAssertEqual(t6.comment, String(repeating: "long comment ", count: 20))
        // everything else as it was: paths, analysis paths, other tracks, playlists, formats
        for t in before.tracks {
            let g = after.tracks.first { $0.id == t.id }!
            XCTAssertEqual(g.path, t.path); XCTAssertEqual(g.anlzPath, t.anlzPath); XCTAssertEqual(g.filename, t.filename)
            XCTAssertEqual(g.dateAdded, t.dateAdded); XCTAssertEqual(g.key, t.key); XCTAssertEqual(g.size, t.size)
            if edits[t.id] == nil { XCTAssertEqual(g, t) }
        }
        XCTAssertEqual(after.playlists, before.playlists)
        XCTAssertEqual(PDB.trackFormats(out), PDB.trackFormats(src))
        // the same artist name reuses its row; "House" got one genre row for both tracks
        XCTAssertEqual(PDB.rowBytes(Bytes(b: out), .artists).count, PDB.rowBytes(Bytes(b: src), .artists).count + 1)
        XCTAssertEqual(PDB.rowBytes(Bytes(b: out), .genres).count, PDB.rowBytes(Bytes(b: src), .genres).count + 1)
        // track rows keep rekordbox's numbering, and the playlist writer still works on the result
        let rows = PDB.rowBytes(Bytes(b: out), .tracks)
        XCTAssertEqual(rows.map { Int(Bytes(b: $0.bytes).u16(2)) }, (0..<rows.count).map { $0 * 0x20 })
        var nodes = after.playlists; nodes[0].name = "Renamed"
        XCTAssertEqual(PDB.parse(try PDB.writePlaylists(out, nodes)).tracks, after.tracks)
        // and back again
        let undo = try PDB.writeTracks(out, [1: PDBTrackEdit(title: "Demo Track 1", artist: "Loopmasters", album: "", genre: "", comment: "Tracks by www.loopmasters.com", rating: 0)])
        XCTAssertEqual(PDB.parse(undo).tracks.first { $0.id == 1 }, before.tracks.first { $0.id == 1 })
    }
    func testManyBigEditsNeedANewPage() throws {
        let src = try fixture("export.pdb")
        let long = String(repeating: "x", count: 600)
        let edits = Dictionary(uniqueKeysWithValues: PDB.parse(src).tracks.map { ($0.id, PDBTrackEdit(comment: long + "\($0.id)")) })
        let out = try PDB.writeTracks(src, edits)
        XCTAssertGreaterThan(out.count, src.count, "the track table grew a page")
        XCTAssertEqual(PDB.problems(out), [])
        XCTAssertTrue(PDB.parse(out).tracks.allSatisfy { $0.comment == long + "\($0.id)" })
    }
    func testRefusesTrackEditsItCantWrite() throws {
        let src = try fixture("export.pdb")
        XCTAssertThrowsError(try PDB.writeTracks(src, [99: PDBTrackEdit(title: "x")]))
        XCTAssertThrowsError(try PDB.writeTracks(src, [1: PDBTrackEdit(rating: 6)]))
        XCTAssertThrowsError(try PDB.writeTracks(src, [1: PDBTrackEdit(bpm: -1)]))
        XCTAssertThrowsError(try PDB.writeTracks([UInt8](repeating: 0, count: 8192), [1: PDBTrackEdit(title: "x")]))
    }

    // ---- OneLibrary ----
    func testWritesOneLibraryTrackInfo() throws {
        let src = try fixture("onelibrary/exportLibrary.db")
        let before = try OneLibrary.read(src)
        let out = try OneLibrary.writeTracks(src, [1: OLTrackEdit(title: "Demo Track 1 (Cratebox Edit)", artist: "New Artist", album: "Demo Album", genre: "House", comment: "peak time", rating: 4, bpm: 127.5),
                                                   2: OLTrackEdit(artist: "Loopmasters")])
        XCTAssertFalse(SQLCipherCodec.isPlainSQLite(out)); XCTAssertEqual(Array(out[0..<16]), Array(src[0..<16]))
        let after = try OneLibrary.read(out)
        XCTAssertEqual(after.integrity, ["ok"])
        let t = after.tracks.first { $0.id == 1 }!
        XCTAssertEqual(t.title, "Demo Track 1 (Cratebox Edit)"); XCTAssertEqual(t.artist, "New Artist"); XCTAssertEqual(t.album, "Demo Album")
        XCTAssertEqual(t.genre, "House"); XCTAssertEqual(t.comment, "peak time"); XCTAssertEqual(t.rating, 4); XCTAssertEqual(t.bpm, 127.5)
        XCTAssertEqual(after.tracks.first { $0.id == 2 }, before.tracks.first { $0.id == 2 }, "same artist: nothing changes")
        XCTAssertEqual(after.playlists, before.playlists); XCTAssertEqual(after.cues, before.cues)
        XCTAssertThrowsError(try OneLibrary.writeTracks(src, [99: OLTrackEdit(title: "x")]))
    }
    func testWritesOneLibraryCues() throws {
        let src = try fixture("onelibrary/exportLibrary.db")
        let before = try OneLibrary.read(src)
        let out = try OneLibrary.writeCues(src, [1: cues])
        let after = try OneLibrary.read(out)
        XCTAssertEqual(after.integrity, ["ok"])
        let mine = after.cues.filter { $0.track == 1 }
        XCTAssertEqual(mine.count, cues.count)
        XCTAssertEqual(mine.filter { $0.kind > 0 }.map { $0.kind }, [1, 2, 4, 8])
        XCTAssertEqual(mine.first { $0.kind == 2 }?.outMs, 31875)
        XCTAssertEqual(mine.first { $0.kind == 1 }?.comment, "Drop")
        XCTAssertEqual(after.tracks, before.tracks); XCTAssertEqual(after.playlists, before.playlists)
        XCTAssertEqual(try OneLibrary.read(try OneLibrary.writeCues(src, [1: []])).cues.filter { $0.track == 1 }, [])
        XCTAssertThrowsError(try OneLibrary.writeCues(src, [99: cues]))
    }

    // ---- the whole thing, on a copy of the stick ----
    func tempStick() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cratebox-stick-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: USBTests.stick, to: dir)
        try Data(try fixture("onelibrary/exportLibrary.db")).write(to: dir.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db"))
        return dir
    }
    func openLibrary(_ root: URL) throws -> (USBLibrary, [UInt8], [UInt8]) {
        let pdb = [UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/export.pdb")))
        let ol = [UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")))
        return (USBLibrary(pdb: PDB.parse(pdb), one: try OneLibrary.read(ol)), pdb, ol)
    }
    func testLockedUntilProven() throws {
        let root = try tempStick()
        defer { try? FileManager.default.removeItem(at: root) }
        let (lib, pdb, ol) = try openLibrary(root)
        let key = lib.tracks.first { $0.title == "Demo Track 1" }!.key
        let change = USBTrackChanges(hot: [USBCue(time: 15)], bpm: 127, title: "x")
        XCTAssertEqual(change.kinds, [.cues, .beatgrid, .metadata])
        XCTAssertThrowsError(try USBTrackWriter.plan(lib, root: root, changes: [key: change], gate: USBWriteGate(proven: []), pdbBytes: pdb, olBytes: ol)) {
            guard case .locked = $0 as? USBWriteError else { return XCTFail("\($0)") }
        }
        // one kind proven isn't enough for a change that needs three
        XCTAssertThrowsError(try USBTrackWriter.plan(lib, root: root, changes: [key: change], gate: USBWriteGate(proven: [.cues]), pdbBytes: pdb, olBytes: ol))
        XCTAssertTrue(USBWriteGate(proven: []).allowed(.cues) == false)
        XCTAssertTrue(USBWriteGate(proven: [.cues]).allowed(.cues))
    }
    func testPlanAndApplyOnAStick() throws {
        let root = try tempStick()
        defer { try? FileManager.default.removeItem(at: root) }
        let (lib, pdb, ol) = try openLibrary(root)
        let t = lib.tracks.first { $0.title == "Demo Track 1" }!
        var hot = [USBCue?](repeating: nil, count: 8)
        hot[0] = USBCue(time: 15, comment: "Drop"); hot[3] = USBCue(time: 45, loopEnd: 46.875)
        let changes = [t.key: USBTrackChanges(cue: 0.112, hot: hot, bpm: 127.5, firstBeat: 0.112, title: "Demo Track 1 (Edit)", genre: "House", rating: 3)]
        let gate = USBWriteGate(proven: [.cues, .beatgrid, .metadata])
        let plan = try USBTrackWriter.plan(lib, root: root, changes: changes, gate: gate, pdbBytes: pdb, olBytes: ol)
        XCTAssertEqual(Set(plan.files.map { $0.rel }), Set<String>([USBWriterTests.demo1 + ".DAT", USBWriterTests.demo1 + ".EXT", "PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportLibrary.db"]))
        XCTAssertEqual(plan.tracks, [t.key])
        // nothing on the stick yet
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/export.pdb"))), pdb)
        let backups = try USBTrackWriter.apply(plan, root: root, appBackupDir: nil)
        XCTAssertEqual(backups.count, 4)
        XCTAssertEqual(USBSafeWrite.recover(root: root), [])
        // read the stick again, the way Cratebox USB opens it
        let (lib2, _, _) = try openLibrary(root)
        let t2 = lib2.track(t.key)!
        XCTAssertEqual(t2.title, "Demo Track 1 (Edit)"); XCTAssertEqual(t2.genre, "House"); XCTAssertEqual(t2.rating, 3); XCTAssertEqual(t2.bpm, 127.5)
        XCTAssertTrue(lib2.inSync, "\(lib2.differences)")
        XCTAssertEqual(lib2.one?.tracks.first { $0.id == t.olId }?.title, "Demo Track 1 (Edit)")
        let dat = RekordboxANLZ.parse(try [UInt8](Data(contentsOf: root.appendingPathComponent(USBWriterTests.demo1 + ".DAT"))))
        var ext = RekordboxANLZ.parse(try [UInt8](Data(contentsOf: root.appendingPathComponent(USBWriterTests.demo1 + ".EXT"))))
        XCTAssertEqual(RekordboxANLZ.grid(dat.beats)?.bpm, 127.5)
        XCTAssertEqual(RekordboxANLZ.grid(dat.beats)!.firstBeat, 0.112, accuracy: 1e-9)
        ext.beats = dat.beats
        let c = RekordboxANLZ.cues(ext)
        XCTAssertEqual(c.cue, 0.112); XCTAssertEqual(c.hot, [15, nil, nil, 45, nil, nil, nil, nil])
        XCTAssertEqual(ext.hot.first { $0.hot == 4 }?.loopMs, 46875)
        XCTAssertNotNil(RekordboxANLZ.phrases(ext), "rekordbox's phrases still read")
        XCTAssertEqual(lib2.one?.cues.filter { $0.track == t.olId }.count, 3)
        // the other tracks' analysis files untouched
        let d2 = USBWriterTests.demo2 + ".DAT"
        XCTAssertEqual(try [UInt8](Data(contentsOf: root.appendingPathComponent(d2))), try stickFile(d2))
    }
    func testApplyPutsBackWhatItWroteWhenALaterFileFails() throws {
        let root = try tempStick()
        defer { try? FileManager.default.removeItem(at: root) }
        let (lib, pdb, ol) = try openLibrary(root)
        let t = lib.tracks.first { $0.title == "Demo Track 1" }!
        var plan = try USBTrackWriter.plan(lib, root: root, changes: [t.key: USBTrackChanges(title: "Edited")], gate: USBWriteGate(proven: [.metadata]), pdbBytes: pdb, olBytes: ol)
        XCTAssertEqual(plan.files.map { $0.rel }, ["PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportLibrary.db"])
        // OneLibrary changed on the stick after it was read (rekordbox exported to it?): its write is refused
        plan.files[1].old = [1, 2, 3]
        XCTAssertThrowsError(try USBTrackWriter.apply(plan, root: root, appBackupDir: nil))
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/export.pdb"))), pdb, "the Device Library was put back")
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db"))), ol)
        XCTAssertEqual(USBSafeWrite.recover(root: root), [])
    }
    func testATrackWithoutAnalysisCantTakeCues() throws {
        let root = try tempStick()
        defer { try? FileManager.default.removeItem(at: root) }
        let (lib, pdb, ol) = try openLibrary(root)
        let t = lib.tracks.first { $0.title == "Demo Track 1" }!
        try FileManager.default.removeItem(at: root.appendingPathComponent(USBWriterTests.demo1 + ".DAT"))
        XCTAssertThrowsError(try USBTrackWriter.plan(lib, root: root, changes: [t.key: USBTrackChanges(cue: 1)], gate: USBWriteGate(proven: [.cues]), pdbBytes: pdb, olBytes: ol))
    }
}
