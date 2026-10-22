package com.zonahbear.cratebox.core

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** a temporary copy of the real rekordbox stick in tests/fixtures (pyrekordbox's test export, without its audio) */
object Stick {
    val dir = File(System.getProperty("cratebox.repo") ?: "../..", "tests/fixtures/rekordbox_usb")
    fun file(rel: String) = File(dir, rel).readBytes()
    fun temp(oneLibrary: String? = "onelibrary/exportLibrary.db"): File {
        val d = Files.createTempDirectory("cratebox-stick-").toFile()
        dir.copyRecursively(d, overwrite = true)
        if (oneLibrary != null) File(d, "PIONEER/rekordbox/exportLibrary.db").writeBytes(Fixtures.bytes(oneLibrary))
        return d
    }
}

/** Port of the rest of USBTests.swift: both libraries side by side, the preflight scan on a copy of a real stick,
 *  staged writes and recovery, the write gate, header sniffing and rekordbox's colour waveform. */
class USBTest {
    private val temps = ArrayList<File>()
    @BeforeTest fun sqlite() = JdbcSQLite.install()
    @AfterTest fun clean() { temps.forEach { it.deleteRecursively() } }
    private fun tempStick(oneLibrary: String? = "onelibrary/exportLibrary.db") = Stick.temp(oneLibrary).also { temps.add(it) }

    @Test fun bothLibrariesInSync() {
        val lib = USBLibrary(PDB.parse(Fixtures.bytes("export.pdb")), OneLibrary.read(Fixtures.bytes("onelibrary/exportLibrary.db")))
        assertEquals(6, lib.tracks.size)
        assertTrue(lib.tracks.all { it.pdbId != null && it.olId != null })
        assertEquals(listOf("Playlist 1", "Folder", "Sub Playlist"), lib.playlists.map { it.name })
        assertTrue(lib.playlists.all { it.pdbId != null && it.olId != null })
        assertTrue(lib.inSync, "${lib.differences}")
        val folder = lib.playlists.first { it.folder }
        assertEquals(2, lib.trackKeys(folder.id).size)
    }

    @Test fun findsWhereTheLibrariesDisagree() {
        val lib = USBLibrary(PDB.parse(Fixtures.bytes("export.pdb")), OneLibrary.read(Fixtures.bytes("onelibrary/exportLibrary-drift.db")))
        val kinds = lib.differences.map { it.kind }.toSet()
        assertTrue(USBSyncDifference.Kind.PLAYLIST_CONTENT_DIFFERS in kinds)      // Sub Playlist reversed
        assertTrue(USBSyncDifference.Kind.PLAYLIST_ONLY_IN_ONE_LIBRARY in kinds)  // "Only OneLibrary"
        assertTrue(USBSyncDifference.Kind.METADATA_DIFFERS in kinds)              // Demo Track 2's BPM
        assertFalse(lib.inSync)
    }

    private fun wav(rate: Int, bits: Int, float: Boolean = false): ByteArray {
        fun le32(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
        fun le16(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
        val fmt = le16(if (float) 3 else 1) + le16(2) + le32(rate) + le32(rate * 2 * bits / 8) + le16(2 * bits / 8) + le16(bits)
        return "RIFF".toByteArray() + le32(36 + 8) + "WAVE".toByteArray() + "fmt ".toByteArray() + le32(16) + fmt + "data".toByteArray() + le32(8) + ByteArray(8)
    }

    @Test fun sniffsHeaders() {
        assertEquals(AudioFacts(AudioCodec.WAV, 96000, 24, 2), AudioSniffer.sniff(wav(96000, 24)))
        assertEquals(true, AudioSniffer.sniff(wav(44100, 32, float = true))?.floatingPoint)
        // an MP3 frame header after an ID3 tag: MPEG-1 layer III, 44.1 kHz
        val id3 = byteArrayOf(0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 2, 0, 0)
        val mp3 = id3 + byteArrayOf(0xff.toByte(), 0xfb.toByte(), 0x90.toByte(), 0x64) + ByteArray(16)
        assertEquals(AudioCodec.MP3, AudioSniffer.sniff(mp3)?.codec); assertEquals(44100, AudioSniffer.sniff(mp3)?.sampleRate)
        val flac = byteArrayOf(0x66, 0x4c, 0x61, 0x43, 0, 0, 0, 34) + ByteArray(10) + byteArrayOf(0x0b, 0xb8.toByte(), 0x03, 0x70) + ByteArray(20)  // 48000 Hz, 2 ch, 24 bit
        assertEquals(AudioFacts(AudioCodec.FLAC, 48000, 24, 2), AudioSniffer.sniff(flac))
    }

    @Test fun preflightOnARealStick() {
        val root = tempStick(); val fs = FileStickFS(root)
        // the fixture has no audio: put two of the files back (one too hi-res for an NXS), leave the rest missing
        File(root, "Contents/UnknownArtist/UnknownAlbum").mkdirs()
        File(root, "Contents/UnknownArtist/UnknownAlbum/SIREN.wav").writeBytes(wav(44100, 16))
        File(root, "Contents/UnknownArtist/UnknownAlbum/HORN.wav").writeBytes(wav(96000, 24))
        val pdb = fs.read("PIONEER/rekordbox/export.pdb")!!; val ol = fs.read("PIONEER/rekordbox/exportLibrary.db")!!
        val lib = USBLibrary(PDB.parse(pdb), OneLibrary.read(ol))
        assertTrue(PDB.problems(pdb).isEmpty(), "${PDB.problems(pdb)}")
        val set = lib.playlists.first { it.name == "Playlist 1" }.id
        // emergency, the set only: both Demo tracks are missing → not ready
        val e = Preflight.run(lib, fs, ScanOptions(ScanMode.EMERGENCY, listOf("cdj2000nxs2"), set), pdb, ol)
        assertEquals(2, e.tracksChecked)
        assertEquals(2, e.issues.count { it.category == IssueCategory.MISSING_FILE && it.inSet })
        assertTrue(e.readiness(emptySet()) is Readiness.NotReady)
        // skipping them makes the set ready
        val skipped = e.issues.filter { it.severity == IssueSeverity.CRITICAL }.map { it.id }.toSet()
        assertEquals(Readiness.Ready, e.readiness(skipped))
        // standard for a CDJ-2000NXS: HORN's 96 kHz is too much, and every library is checked
        val s = Preflight.run(lib, fs, ScanOptions(ScanMode.STANDARD, listOf("cdj2000nxs")), pdb, ol)
        assertTrue(s.issues.any { it.id.startsWith("track|rate|") && it.trackKey?.endsWith("horn.wav") == true }, "${s.issues.map { it.id }}")
        assertFalse(s.issues.any { it.trackKey?.endsWith("siren.wav") == true && it.category == IssueCategory.HARDWARE })
        assertEquals(6, s.tracksChecked)
        // an OPUS-QUAD only reads OneLibrary: fine here; a stick without it is critical
        File(root, "PIONEER/rekordbox/exportLibrary.db").delete()
        val onlyPdb = USBLibrary(PDB.parse(pdb), null)
        val o = Preflight.run(onlyPdb, fs, ScanOptions(ScanMode.EMERGENCY, listOf("opusquad")), pdb, null)
        assertTrue(o.issues.any { it.id == "lib|need-ol" && it.severity == IssueSeverity.CRITICAL })
        // exFAT for an NXS2: not readable
        val f = Preflight.run(lib, fs, ScanOptions(ScanMode.STANDARD, listOf("cdj2000nxs2"), fileSystem = "exFAT"), pdb, ol)
        assertTrue(f.issues.any { it.category == IssueCategory.FILE_SYSTEM && it.severity == IssueSeverity.CRITICAL })
    }

    @Test fun preflightFlagsOutOfSyncLibraries() {
        val root = tempStick("onelibrary/exportLibrary-drift.db"); val fs = FileStickFS(root)
        val pdb = fs.read("PIONEER/rekordbox/export.pdb")!!; val ol = fs.read("PIONEER/rekordbox/exportLibrary.db")!!
        val lib = USBLibrary(PDB.parse(pdb), OneLibrary.read(ol))
        val r = Preflight.run(lib, fs, ScanOptions(ScanMode.STANDARD, listOf("cdj3000x", "cdj2000nxs2")), pdb, ol)
        val conflicts = r.issues.filter { it.conflict }
        assertTrue(conflicts.size >= 3)
        assertTrue(conflicts.all { it.severity == IssueSeverity.CRITICAL }, "a mixed booth reads both libraries")
    }

    @Test fun playerRequirements() {
        val mixed = PlayerProfiles.requirement(listOf("cdj3000x", "cdj2000nxs"))
        assertTrue(mixed.deviceLibrary && mixed.oneLibrary)
        assertFalse(AudioCodec.FLAC in mixed.codecs)
        assertEquals(48000, mixed.maxSampleRate)
        val unknown = PlayerProfiles.requirement(emptyList())
        assertTrue(unknown.deviceLibrary && unknown.oneLibrary)
        assertEquals(setOf("FAT32"), unknown.fileSystems)
        val cdj3000 = PlayerProfiles.requirement(listOf("cdj3000"))
        assertTrue(cdj3000.deviceLibrary || cdj3000.oneLibrary)
    }

    @Test fun safeWriteAndRecovery() {
        val root = tempStick(null); val fs = FileStickFS(root)
        val rel = "PIONEER/rekordbox/export.pdb"
        val before = fs.read(rel)!!
        val nodes = PDB.parse(before).playlists.toMutableList()
        nodes[0] = nodes[0].copy(name = "Renamed")
        val new = PDB.writePlaylists(before, nodes)
        // a stale base is refused before anything is touched
        assertFailsWith<USBWriteError> { USBSafeWrite.write(new, fs, rel, "stale", null) { } }
        // a failing check leaves the stick as it was
        assertFailsWith<USBWriteError> { USBSafeWrite.write(new, fs, rel, USBSafeWrite.hash(before), null) { throw PDBError.readBack("no") } }
        assertContentEquals(before, fs.read(rel))
        // the real thing
        val backup = USBSafeWrite.write(new, fs, rel, USBSafeWrite.hash(before), null) { b ->
            if (PDB.parse(b).playlists.firstOrNull()?.name != "Renamed") throw PDBError.readBack("not renamed")
        }
        assertContentEquals(new, fs.read(rel))
        assertContentEquals(before, fs.read(backup))
        assertEquals(emptyList(), USBSafeWrite.recover(fs))
        // a save cut off half way: the file is neither version, the journal is there → the backup goes back
        val j = USBJournal(rel, backup, USBSafeWrite.hash(before), "x", before.size, 0, "staged", USBJournal.now())
        fs.write(USBSafeWrite.journalRel(rel), j.json().toByteArray())
        fs.write(rel, new.copyOf(1000))
        val rec = USBSafeWrite.recover(fs)
        assertEquals(1, rec.size)
        assertTrue(rec[0] is USBSafeWrite.Recovery.Restored, "$rec")
        assertContentEquals(before, fs.read(rel))
        // cut off between delete and rename (Android's document provider has no atomic rename-over): the
        // staged file is the complete new version, so it's moved into place
        val j2 = USBJournal(rel, backup, USBSafeWrite.hash(before), USBSafeWrite.hash(new), before.size, new.size, "staged", USBJournal.now())
        fs.write(USBSafeWrite.journalRel(rel), j2.json().toByteArray())
        fs.write("PIONEER/rekordbox/export.pdb.cratebox-stage", new)
        fs.delete(rel)
        val rec2 = USBSafeWrite.recover(fs)
        assertTrue(rec2.single() is USBSafeWrite.Recovery.CleanedUp, "$rec2")
        assertContentEquals(new, fs.read(rel))
        assertFalse(fs.exists("PIONEER/rekordbox/export.pdb.cratebox-stage"))
        assertEquals(emptyList(), USBSafeWrite.recover(fs))
    }

    @Test fun readsAJournalTheIOSAppWrote() {
        // Swift's JSONEncoder: Date as seconds since 2001
        val s = """{"target":"PIONEER\/rekordbox\/export.pdb","backup":"b","oldHash":"0123456789abcdef-10","newHash":"x","oldSize":10,"newSize":0,"state":"staged","when":782812800.5}"""
        val j = USBJournal.parse(s)!!
        assertEquals("PIONEER/rekordbox/export.pdb", j.target); assertEquals(782812800.5, j.`when`)
        assertEquals(j, USBJournal.parse(j.json()))
        assertEquals("af63dc4c8601ec8c-1", USBSafeWrite.hash(byteArrayOf(0x61)))    // FNV-1a 64 of "a"
    }

    @Test fun writeGate() {
        val none = USBWriteGate(emptySet())
        assertNotNull(none.playlistWriteBlocker(deviceLibrary = true, oneLibrary = false))
        val pdbOnly = USBWriteGate(setOf(USBWriteKind.DEVICE_LIBRARY_PLAYLISTS))
        assertNull(pdbOnly.playlistWriteBlocker(deviceLibrary = true, oneLibrary = false))
        assertNotNull(pdbOnly.playlistWriteBlocker(deviceLibrary = true, oneLibrary = true), "both libraries or neither")
        assertFalse(USBWriteGate(emptySet()).allowed(USBWriteKind.CUES), "locked until proven")
        assertTrue(USBWriteGate(setOf(USBWriteKind.CUES)).allowed(USBWriteKind.CUES))
    }

    @Test fun rekordboxColourWaveform() {
        val w = RekordboxANLZ.waveform(Stick.file("PIONEER/USBANLZ/P016/0000875E/ANLZ0000.EXT"), 172.0)
        assertNotNull(w)
        assertEquals(150, w.wps)
        assertTrue(w.peak.size > 150 * 100)
        assertTrue(w.peak.maxOf { it.toInt() and 0xff } > 100)
    }
}
