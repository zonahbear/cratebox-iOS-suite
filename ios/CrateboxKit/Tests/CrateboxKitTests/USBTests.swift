import XCTest
@testable import CrateboxKit

/// Cratebox USB: SQLCipher against a real rekordbox database and SQLCipher's own output, OneLibrary read and
/// write, the two libraries side by side, the preflight scan on a copy of a real stick, staged writes and
/// recovery, and Deck Bridge's messages and mapping file.
final class USBTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!))
    }
    /// the copy of a real rekordbox stick (pyrekordbox's test export, without its audio) in tests/fixtures
    static let stick = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../tests/fixtures/rekordbox_usb").standardizedFileURL
    func tempStick(oneLibrary: String? = "onelibrary/exportLibrary.db") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cratebox-stick-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: USBTests.stick, to: dir)
        if let ol = oneLibrary { try Data(try fixture(ol)).write(to: dir.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")) }
        return dir
    }
    static let rb6Key: String = {
        let m: [UInt8] = [0x77, 0x42, 0x53, 0x12, 0x01, 0x56, 0x57, 0x4a, 0x43, 0x47, 0x5d, 0x4b, 0x45, 0x74, 0x11, 0x52, 0x41, 0x03, 0x04, 0x0e, 0x40, 0x46, 0x12, 0x07, 0x4b, 0x17, 0x74, 0x16, 0x58, 0x47, 0x54, 0x56,
                          0x5c, 0x1a, 0x17, 0x40, 0x5c, 0x16, 0x43, 0x27, 0x41, 0x50, 0x41, 0x01, 0x04, 0x58, 0x19, 0x18, 0x45, 0x52, 0x40, 0x46, 0x22, 0x43, 0x07, 0x12, 0x51, 0x51, 0x59, 0x48, 0x18, 0x40, 0x5c, 0x44]
        let mask = Array("Cratebox test".utf8)
        return String(decoding: m.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }, as: UTF8.self)
    }()

    // ---- SQLCipher ----
    func testDecryptsARealRekordboxDatabase() throws {
        let enc = try fixture("sqlcipher/rekordbox6-master-4pages.enc"), plain = try fixture("sqlcipher/rekordbox6-master-4pages.plain")
        let c = try SQLCipherCodec(passphrase: USBTests.rb6Key, salt: Array(enc[0..<16]))
        XCTAssertEqual(try c.decrypt(enc), plain)
        // and back, with the file's own IVs: byte for byte
        let ivs = (0..<(enc.count / 4096)).map { p in Array(enc[(p * 4096 + 4096 - 80)..<(p * 4096 + 4096 - 64)]) }
        XCTAssertEqual(try c.encrypt(plain, ivs: ivs), enc)
        // a wrong key is caught by the page check, not read as garbage
        let wrong = try SQLCipherCodec(passphrase: "not the key", salt: Array(enc[0..<16]))
        XCTAssertThrowsError(try wrong.decrypt(enc)) { XCTAssertEqual($0 as? SQLCipherError, .badHMAC(page: 1)) }
    }

    func testReadsOneLibraryMadeBySQLCipher() throws {
        let one = try OneLibrary.read(try fixture("onelibrary/exportLibrary.db"))
        XCTAssertEqual(one.integrity, ["ok"])
        XCTAssertEqual(one.tracks.count, 6)
        let d1 = one.tracks.first { $0.title == "Demo Track 1" }!
        XCTAssertEqual(d1.artist, "Loopmasters"); XCTAssertEqual(d1.key, "Fm"); XCTAssertEqual(d1.bpm, 128)
        XCTAssertEqual(d1.path, "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3")
        XCTAssertEqual(one.playlists.map { $0.name }, ["Playlist 1", "Folder", "Sub Playlist"])
        XCTAssertEqual(one.playlists.first { $0.name == "Sub Playlist" }?.tracks, [1, 2])
        XCTAssertEqual(one.cues.count, 2)
        XCTAssertEqual(one.deviceName, "CRATEBOX TEST")
    }

    func testWritesOneLibraryPlaylistsAndReadsThemBack() throws {
        let src = try fixture("onelibrary/exportLibrary.db")
        var nodes = try OneLibrary.read(src).playlists
        nodes[0].name = "Peak time"; nodes[0].tracks = [2, 1, 5]
        nodes.append(OLPlaylist(id: 20, parent: 0, seq: 0, folder: false, name: "Warm up", tracks: [3], attribute: 0))
        let out = try OneLibrary.writePlaylists(src, nodes)
        XCTAssertFalse(SQLCipherCodec.isPlainSQLite(out), "still encrypted")
        XCTAssertEqual(Array(out[0..<16]), Array(src[0..<16]), "same salt")
        let back = try OneLibrary.read(out)
        XCTAssertEqual(back.integrity, ["ok"])
        XCTAssertEqual(back.playlists.first { $0.id == nodes[0].id }?.name, "Peak time")
        XCTAssertEqual(back.playlists.first { $0.id == nodes[0].id }?.tracks, [2, 1, 5])
        XCTAssertEqual(back.playlists.first { $0.id == 20 }?.tracks, [3])
        XCTAssertEqual(back.tracks, try OneLibrary.read(src).tracks, "tracks untouched")
        // refuses what it can't do, writing nothing
        XCTAssertThrowsError(try OneLibrary.writePlaylists(src, [OLPlaylist(id: 1, parent: 0, seq: 0, folder: false, name: "x", tracks: [999], attribute: 0)]))
        XCTAssertThrowsError(try OneLibrary.writePlaylists(src, [OLPlaylist(id: 2, parent: 77, seq: 0, folder: false, name: "x", tracks: [], attribute: 0)]))
    }

    // ---- both libraries ----
    func testBothLibrariesInSync() throws {
        let lib = USBLibrary(pdb: PDB.parse(try fixture("export.pdb")), one: try OneLibrary.read(try fixture("onelibrary/exportLibrary.db")))
        XCTAssertEqual(lib.tracks.count, 6)
        XCTAssertTrue(lib.tracks.allSatisfy { $0.pdbId != nil && $0.olId != nil })
        XCTAssertEqual(lib.playlists.map { $0.name }, ["Playlist 1", "Folder", "Sub Playlist"])
        XCTAssertTrue(lib.playlists.allSatisfy { $0.pdbId != nil && $0.olId != nil })
        XCTAssertTrue(lib.inSync, "\(lib.differences)")
        let folder = lib.playlists.first { $0.folder }!
        XCTAssertEqual(lib.trackKeys(of: folder.id).count, 2)
    }
    func testFindsWhereTheLibrariesDisagree() throws {
        let lib = USBLibrary(pdb: PDB.parse(try fixture("export.pdb")), one: try OneLibrary.read(try fixture("onelibrary/exportLibrary-drift.db")))
        let kinds = Set(lib.differences.map { $0.kind })
        XCTAssertTrue(kinds.contains(.playlistContentDiffers))      // Sub Playlist reversed
        XCTAssertTrue(kinds.contains(.playlistOnlyInOneLibrary))    // "Only OneLibrary"
        XCTAssertTrue(kinds.contains(.metadataDiffers))             // Demo Track 2's BPM
        XCTAssertFalse(lib.inSync)
    }

    // ---- preflight ----
    func wav(rate: UInt32, bits: UInt16, float: Bool = false) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        let fmt: [UInt8] = le16(float ? 3 : 1) + le16(2) + le32(rate) + le32(rate * 2 * UInt32(bits) / 8) + le16(2 * bits / 8) + le16(bits)
        return Array("RIFF".utf8) + le32(36 + 8) + Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(8) + [UInt8](repeating: 0, count: 8)
    }
    func testSniffsHeaders() {
        XCTAssertEqual(AudioSniffer.sniff(wav(rate: 96000, bits: 24)), AudioFacts(codec: .wav, sampleRate: 96000, bitDepth: 24, channels: 2))
        XCTAssertEqual(AudioSniffer.sniff(wav(rate: 44100, bits: 32, float: true))?.floatingPoint, true)
        // an MP3 frame header after an ID3 tag: MPEG-1 layer III, 44.1 kHz
        let id3: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 2, 0, 0]
        let mp3: [UInt8] = id3 + [0xff, 0xfb, 0x90, 0x64] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(AudioSniffer.sniff(mp3)?.codec, .mp3); XCTAssertEqual(AudioSniffer.sniff(mp3)?.sampleRate, 44100)
        var flac: [UInt8] = [0x66, 0x4c, 0x61, 0x43, 0, 0, 0, 34] + [UInt8](repeating: 0, count: 10)
        flac += [0x0b, 0xb8, 0x03, 0x70] as [UInt8]
        flac += [UInt8](repeating: 0, count: 20)       // 48000 Hz, 2 ch, 24 bit
        XCTAssertEqual(AudioSniffer.sniff(flac), AudioFacts(codec: .flac, sampleRate: 48000, bitDepth: 24, channels: 2))
    }
    func testPreflightOnARealStick() throws {
        let root = try tempStick()
        defer { try? FileManager.default.removeItem(at: root) }
        // the fixture has no audio: put two of the files back (one too hi-res for an NXS), leave the rest missing
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Contents/UnknownArtist/UnknownAlbum"), withIntermediateDirectories: true)
        try Data(wav(rate: 44100, bits: 16)).write(to: root.appendingPathComponent("Contents/UnknownArtist/UnknownAlbum/SIREN.wav"))
        try Data(wav(rate: 96000, bits: 24)).write(to: root.appendingPathComponent("Contents/UnknownArtist/UnknownAlbum/HORN.wav"))
        let pdb = [UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/export.pdb")))
        let ol = [UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")))
        let lib = USBLibrary(pdb: PDB.parse(pdb), one: try OneLibrary.read(ol))
        XCTAssertTrue(PDB.problems(pdb).isEmpty, "\(PDB.problems(pdb))")
        let set = lib.playlists.first { $0.name == "Playlist 1" }!.id
        // emergency, the set only: both Demo tracks are missing → not ready
        let e = Preflight.run(lib, root: root, options: ScanOptions(mode: .emergency, players: ["cdj2000nxs2"], setPlaylist: set), pdbBytes: pdb, olBytes: ol)
        XCTAssertEqual(e.tracksChecked, 2)
        XCTAssertEqual(e.issues.filter { $0.category == .missingFile && $0.inSet }.count, 2)
        if case .notReady = e.readiness(skipped: []) {} else { XCTFail("should be not ready") }
        // skipping them makes the set ready
        let skipped = Set(e.issues.filter { $0.severity == .critical }.map { $0.id })
        XCTAssertEqual(e.readiness(skipped: skipped), .ready)
        // standard for a CDJ-2000NXS: HORN's 96 kHz is too much, and every library is checked
        let s = Preflight.run(lib, root: root, options: ScanOptions(mode: .standard, players: ["cdj2000nxs"]), pdbBytes: pdb, olBytes: ol)
        XCTAssertTrue(s.issues.contains { $0.id.hasPrefix("track|rate|") && $0.trackKey?.hasSuffix("horn.wav") == true }, "\(s.issues.map { $0.id })")
        XCTAssertFalse(s.issues.contains { $0.trackKey?.hasSuffix("siren.wav") == true && $0.category == .hardware })
        XCTAssertEqual(s.tracksChecked, 6)
        // an OPUS-QUAD only reads OneLibrary: fine here; a stick without it is critical
        try fm.removeItem(at: root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db"))
        let onlyPdb = USBLibrary(pdb: PDB.parse(pdb), one: nil)
        let o = Preflight.run(onlyPdb, root: root, options: ScanOptions(mode: .emergency, players: ["opusquad"]), pdbBytes: pdb, olBytes: nil)
        XCTAssertTrue(o.issues.contains { $0.id == "lib|need-ol" && $0.severity == .critical })
        // exFAT for an NXS2: not readable
        let f = Preflight.run(lib, root: root, options: ScanOptions(mode: .standard, players: ["cdj2000nxs2"], fileSystem: "exFAT"), pdbBytes: pdb, olBytes: ol)
        XCTAssertTrue(f.issues.contains { $0.category == .fileSystem && $0.severity == .critical })
    }
    func testPreflightFlagsOutOfSyncLibraries() throws {
        let root = try tempStick(oneLibrary: "onelibrary/exportLibrary-drift.db")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdb = [UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/export.pdb")))
        let ol = [UInt8](try Data(contentsOf: root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")))
        let lib = USBLibrary(pdb: PDB.parse(pdb), one: try OneLibrary.read(ol))
        let r = Preflight.run(lib, root: root, options: ScanOptions(mode: .standard, players: ["cdj3000x", "cdj2000nxs2"]), pdbBytes: pdb, olBytes: ol)
        let conflicts = r.issues.filter { $0.conflict }
        XCTAssertGreaterThanOrEqual(conflicts.count, 3)
        XCTAssertTrue(conflicts.allSatisfy { $0.severity == .critical }, "a mixed booth reads both libraries")
    }
    func testDamagedPDBIsReported() throws {
        var pdb = try fixture("export.pdb")
        // point the first table's chain past the end of the file
        pdb[28 + 8] = 0xff; pdb[28 + 9] = 0xff
        XCTAssertFalse(PDB.problems(pdb).isEmpty)
        XCTAssertFalse(PDB.problems(Array(pdb[0..<100])).isEmpty)
    }
    func testPlayerRequirements() {
        let mixed = PlayerProfiles.requirement(["cdj3000x", "cdj2000nxs"])
        XCTAssertTrue(mixed.deviceLibrary && mixed.oneLibrary)
        XCTAssertFalse(mixed.codecs.contains(.flac))
        XCTAssertEqual(mixed.maxSampleRate, 48000)
        let unknown = PlayerProfiles.requirement([])
        XCTAssertTrue(unknown.deviceLibrary && unknown.oneLibrary)
        XCTAssertEqual(unknown.fileSystems, ["FAT32"])
        let cdj3000 = PlayerProfiles.requirement(["cdj3000"])
        XCTAssertTrue(cdj3000.deviceLibrary || cdj3000.oneLibrary)
    }

    // ---- staged writes ----
    func testSafeWriteAndRecovery() throws {
        let root = try tempStick(oneLibrary: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let rel = "PIONEER/rekordbox/export.pdb"
        let before = [UInt8](try Data(contentsOf: root.appendingPathComponent(rel)))
        var nodes = PDB.parse(before).playlists
        nodes[0].name = "Renamed"
        let new = try PDB.writePlaylists(before, nodes)
        // a stale base is refused before anything is touched
        XCTAssertThrowsError(try USBSafeWrite.write(new, root: root, rel: rel, expectedHash: "stale", appBackupDir: nil) { _ in })
        // a failing check leaves the stick as it was
        XCTAssertThrowsError(try USBSafeWrite.write(new, root: root, rel: rel, expectedHash: USBSafeWrite.hash(before), appBackupDir: nil) { _ in throw PDBError.readBack("no") })
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent(rel))), before)
        // the real thing
        let backup = try USBSafeWrite.write(new, root: root, rel: rel, expectedHash: USBSafeWrite.hash(before), appBackupDir: nil) { b in
            if PDB.parse(b).playlists.first?.name != "Renamed" { throw PDBError.readBack("not renamed") }
        }
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent(rel))), new)
        XCTAssertEqual([UInt8](try Data(contentsOf: backup)), before)
        XCTAssertEqual(USBSafeWrite.recover(root: root), [])
        // a save cut off half way: the file is neither version, the journal is there → the backup goes back
        let j = USBJournal(target: rel, backup: backup.path.replacingOccurrences(of: root.path + "/", with: ""), oldHash: USBSafeWrite.hash(before),
                           newHash: "x", oldSize: before.count, newSize: 0, state: "staged", when: Date())
        try JSONEncoder().encode(j).write(to: USBSafeWrite.journalURL(root, rel))
        try Data(new.prefix(1000)).write(to: root.appendingPathComponent(rel))
        let rec = USBSafeWrite.recover(root: root)
        XCTAssertEqual(rec.count, 1)
        if case .restored = rec[0] {} else { XCTFail("\(rec)") }
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent(rel))), before)
    }
    func testWriteGate() {
        let none = USBWriteGate(proven: [])
        XCTAssertNotNil(none.playlistWriteBlocker(deviceLibrary: true, oneLibrary: false))
        let pdbOnly = USBWriteGate(proven: [.deviceLibraryPlaylists])
        XCTAssertNil(pdbOnly.playlistWriteBlocker(deviceLibrary: true, oneLibrary: false))
        XCTAssertNotNil(pdbOnly.playlistWriteBlocker(deviceLibrary: true, oneLibrary: true), "both libraries or neither")
        XCTAssertFalse(USBWriteGate(proven: []).allowed(.cues), "locked until proven")
        XCTAssertTrue(USBWriteGate(proven: [.cues]).allowed(.cues))
    }

    // ---- analysis waveform ----
    func testRekordboxColourWaveform() throws {
        let ext = [UInt8](try Data(contentsOf: USBTests.stick.appendingPathComponent("PIONEER/USBANLZ/P016/0000875E/ANLZ0000.EXT")))
        let w = RekordboxANLZ.waveform(ext: ext, duration: 172)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.wps, 150)
        XCTAssertGreaterThan(w?.peak.count ?? 0, 150 * 100)
        XCTAssertGreaterThan(w?.peak.max() ?? 0, 100)
    }

    // ---- Deck Bridge ----
    func testDeckBridgeMessages() {
        XCTAssertEqual(DeckBridgeMap.button(.playPause, deck: 2, on: true), [BridgeMessage(bytes: [0x92, 0x0B, 0x7F])])
        XCTAssertEqual(DeckBridgeMap.button(.playPause, deck: 3, on: false), [BridgeMessage(bytes: [0x93, 0x0B, 0x00])])
        XCTAssertEqual(DeckBridgeMap.hotCue(4, deck: 3, on: true), [BridgeMessage(bytes: [0x9A, 0x04, 0x7F])])
        XCTAssertEqual(DeckBridgeMap.value(.channelFader, deck: 2, 1), [BridgeMessage(bytes: [0xB2, 0x13, 0x7F]), BridgeMessage(bytes: [0xB2, 0x33, 0x7F])])
        XCTAssertEqual(DeckBridgeMap.value(.filter, deck: 3, 0.5).first, BridgeMessage(bytes: [0xB6, 0x1A, 0x40]))
        XCTAssertEqual(DeckBridgeMap.relative(.jogScratch, deck: 2, ticks: 100).map { $0.bytes }, [[0xB2, 0x22, 127], [0xB2, 0x22, 101]] as [[UInt8]])
        XCTAssertEqual(DeckBridgeMap.relative(.jogBend, deck: 3, ticks: -5).map { $0.bytes }, [[0xB3, 0x23, 59]] as [[UInt8]])
        XCTAssertEqual(DeckBridgeMap.feedback([0x92, 0x0B, 0x7F]), .button(.playPause, deck: 2, on: true))
        XCTAssertEqual(DeckBridgeMap.feedback([0x9A, 0x02, 0x00]), .hotCue(2, deck: 3, on: false))
    }
    func testDeckBridgeMappingFile() {
        let csv = DeckBridgeMap.rekordboxCSV()
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines[0], "@file,1,Cratebox Deck Bridge")
        for l in lines.dropFirst() { XCTAssertEqual(l.components(separatedBy: ",").count, 15, l) }
        XCTAssertTrue(lines.contains("PlayPause,PlayPause,Button,900B,0,1,2,3,900B,0,1,2,3,Fast;Blink=1000;Priority=50,Play/Pause"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("PAD1_HotCue,PAD1.HotCue.Call,Pad,9000,7,8,9,10,") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("ChannelFader,ChannelFader,KnobSliderHiRes,B013,0,1,2,3,") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Load,Load,Button,,9646,9647,9648,9649,") })
        // the copy in the repo (deckbridge/) is the same file
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../deckbridge/Cratebox Deck Bridge.midi.csv").standardizedFileURL
        XCTAssertEqual(try? String(contentsOf: repo, encoding: .utf8), csv)
    }
}
