package com.zonahbear.cratebox.core

import java.io.File
import kotlin.math.abs
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Port of USBWriterTests.swift: the cue, beat grid and track info writers, each read back with the readers the
 *  rest of Cratebox USB uses, then the whole thing (plan → apply) on a temporary copy of the stick. */
class USBWriterTest {
    private val temps = ArrayList<File>()
    @BeforeTest fun sqlite() = JdbcSQLite.install()
    @AfterTest fun clean() { temps.forEach { it.deleteRecursively() } }

    private val demo1 = "PIONEER/USBANLZ/P016/0000875E/ANLZ0000"; private val demo2 = "PIONEER/USBANLZ/P053/0001D21F/ANLZ0000"
    private fun tags(b: ByteArray) = RekordboxANLZ.split(b).tags.map { it.name }
    private fun tagBytes(b: ByteArray, name: String) = RekordboxANLZ.split(b).tags.filter { it.name == name }.map { it.bytes }
    private val cues = OneLibraryTest.cues

    // ---- ANLZ: cues ----
    @Test fun noCuesRewritesTheFileByteForByte() {
        // the stick's cue lists are empty: writing no cues must give the same file
        for (f in listOf(demo1, demo2)) for (ext in listOf("DAT", "EXT")) {
            val b = Stick.file("$f.$ext")
            assertContentEquals(b, RekordboxANLZ.writeCues(b, emptyList()), "$f.$ext")
        }
    }

    @Test fun writesCuesAndReadsThemBack() {
        val dat = Stick.file("$demo1.DAT"); val ext = Stick.file("$demo1.EXT")
        val d2 = RekordboxANLZ.writeCues(dat, cues); val e2 = RekordboxANLZ.writeCues(ext, cues)
        // the .DAT: hot cues A-C only, as the older players read it
        val a = RekordboxANLZ.parse(d2)
        assertEquals(listOf(ANLZCue(1, 15000, null), ANLZCue(2, 30000, 31875)), a.hot)
        assertEquals(listOf(ANLZCue(0, 25, null), ANLZCue(0, 90000, 93750)), a.memory)
        // the .EXT: all eight, with comments and colours
        val e = RekordboxANLZ.parse(e2)
        assertEquals(listOf(1, 2, 4, 8), e.hot.map { it.hot })
        assertEquals(cues.filter { it.hot > 0 } + cues.filter { it.hot == 0 }, RekordboxANLZ.cuePoints(e2))
        val c = RekordboxANLZ.cues(e)
        assertEquals(0.025, c.cue)
        assertEquals(listOf(15.0, 30.0, null, 45.0, null, null, null, 60.0), c.hot)
        // every other tag exactly as it was, the file length in the header right
        for ((x, y) in listOf(dat to d2, ext to e2)) {
            assertEquals(tags(x), tags(y))
            for ((p, q) in RekordboxANLZ.split(x).tags.zip(RekordboxANLZ.split(y).tags))
                if (p.name != "PCOB" && p.name != "PCO2") assertContentEquals(p.bytes, q.bytes, p.name)
            val len = ((y[8].toInt() and 0xff) shl 24) or ((y[9].toInt() and 0xff) shl 16) or ((y[10].toInt() and 0xff) shl 8) or (y[11].toInt() and 0xff)
            assertEquals(y.size, len)
        }
        // the entries as crate-digger lays them out
        val hotPCOB = tagBytes(d2, "PCOB")[0]
        assertContentEquals(byteArrayOf(0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2), hotPCOB.copyOfRange(12, 24))
        assertContentEquals("PCPT".toByteArray(), hotPCOB.copyOfRange(24, 28))
        assertEquals(24 + 2 * 0x38, hotPCOB.size)
        // writing the same again changes nothing; writing none puts the file back
        assertContentEquals(e2, RekordboxANLZ.writeCues(e2, cues))
        assertContentEquals(ext, RekordboxANLZ.writeCues(e2, emptyList()))
        assertContentEquals(dat, RekordboxANLZ.writeCues(d2, emptyList()))
    }

    @Test fun refusesCuesItCantWrite() {
        val dat = Stick.file("$demo1.DAT")
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeCues(dat, listOf(ANLZCuePoint(9, 1))) }
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeCues(dat, listOf(ANLZCuePoint(1, 1), ANLZCuePoint(1, 2))) }
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeCues(dat, listOf(ANLZCuePoint(0, 500, 400))) }
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeCues(dat.copyOf(100), emptyList()) }
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeCues(ByteArray(64), emptyList()) }
        // a file without the cue lists: nothing to replace, so no write
        val sp = RekordboxANLZ.split(dat)
        val noCues = RekordboxANLZ.join(sp.header, sp.tags.filter { it.name != "PCOB" }.map { it.bytes })
        val e = assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeCues(noCues, emptyList()) }
        assertEquals(ANLZWriteError.missingTag("PCOB").message, e.message)
    }

    // ---- ANLZ: grid ----
    @Test fun rewritingTheSameGridGivesTheSameFile() {
        for (f in listOf(demo1, demo2)) {
            val dat = Stick.file("$f.DAT")
            assertContentEquals(dat, RekordboxANLZ.writeGrid(dat, RekordboxANLZ.parse(dat).beats), f)
        }
    }

    @Test fun constantGrid() {
        val g = RekordboxANLZ.constantGrid(128.0, 0.5, 10.0)
        // 0.5 s is a downbeat: one beat (the bar's 4th) comes before it
        assertEquals(ANLZBeat(4, 128.0, 31), g[0])
        assertEquals(ANLZBeat(1, 128.0, 500), g[1])
        assertEquals(2, g[2].n); assertEquals(1, g[5].n)
        assertEquals(((10 - 0.03125) / 0.46875).toInt() + 1, g.size)
        assertTrue(g.all { it.ms < 10000 })
        val r = RekordboxANLZ.grid(g)!!
        assertEquals(128.0, r.bpm); assertEquals(0.5, r.firstBeat)
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.constantGrid(0.0, 0.0, 10.0) }
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.constantGrid(128.0, 20.0, 10.0) }
        // the stick's own grid for Demo Track 1, rebuilt: same tempo and downbeat, every beat within a ms
        val have = RekordboxANLZ.parse(Stick.file("$demo1.DAT")).beats
        val mine = RekordboxANLZ.constantGrid(128.0, 0.025, 172.1)
        assertEquals(have.size, mine.size)
        for ((a, b) in mine.zip(have)) { assertEquals(b.n, a.n); assertEquals(b.bpm, a.bpm); assertTrue(abs(a.ms - b.ms) <= 1) }
    }

    @Test fun writesAGridAndReadsItBack() {
        val dat = Stick.file("$demo1.DAT"); val ext = Stick.file("$demo1.EXT")
        val grid = RekordboxANLZ.constantGrid(127.5, 0.112, 172.0)
        val d2 = RekordboxANLZ.writeGrid(dat, grid)
        val back = RekordboxANLZ.parse(d2)
        assertEquals(grid, back.beats)
        assertEquals(127.5, RekordboxANLZ.grid(back.beats)?.bpm)
        assertEquals(0.112, RekordboxANLZ.grid(back.beats)!!.firstBeat, 1e-9)
        // the header words of PQTZ kept, everything else untouched
        assertContentEquals(tagBytes(dat, "PQTZ")[0].copyOfRange(12, 20), tagBytes(d2, "PQTZ")[0].copyOfRange(12, 20))
        assertEquals(tags(dat), tags(d2))
        for ((p, q) in RekordboxANLZ.split(dat).tags.zip(RekordboxANLZ.split(d2).tags)) if (p.name != "PQTZ") assertContentEquals(p.bytes, q.bytes, p.name)
        // the .EXT has no PQTZ, and loses PQT2 (it would disagree with the new grid); nothing else changes
        assertTrue("PQT2" in tags(ext))
        val e2 = RekordboxANLZ.writeGrid(ext, grid)
        assertEquals(tags(ext).filter { it != "PQT2" }, tags(e2))
        val keptExt = RekordboxANLZ.split(ext).tags.filter { it.name != "PQT2" }
        for ((p, q) in keptExt.zip(RekordboxANLZ.split(e2).tags)) assertContentEquals(p.bytes, q.bytes)
        assertNotNull(RekordboxANLZ.waveform(e2, 172.0), "the colour waveform still reads")
        // cues and grid together, in either order
        assertContentEquals(RekordboxANLZ.writeGrid(RekordboxANLZ.writeCues(dat, cues), grid), RekordboxANLZ.writeCues(RekordboxANLZ.writeGrid(dat, grid), cues))
        assertFailsWith<ANLZWriteError> { RekordboxANLZ.writeGrid(dat, listOf(grid[1], grid[0])) }
    }

    // ---- export.pdb: track info ----
    @Test fun noTrackEditsGiveTheSameFile() {
        val src = Fixtures.bytes("export.pdb")
        assertContentEquals(src, PDB.writeTracks(src, emptyMap()))
        assertContentEquals(src, PDB.writeTracks(src, mapOf(1L to PDBTrackEdit())))
    }

    @Test fun ratingAndBPMArePatchedInPlace() {
        val src = Fixtures.bytes("export.pdb")
        val out = PDB.writeTracks(src, mapOf(2L to PDBTrackEdit(rating = 4, bpm = 121.5)))
        assertEquals(src.size, out.size)
        val diff = src.indices.count { src[it] != out[it] }
        assertTrue(diff <= 5, "the rating byte and the tempo word, nothing else")
        val t = PDB.parse(out).tracks.first { it.id == 2L }
        assertEquals(4, t.rating); assertEquals(121.5, t.bpm)
    }

    @Test fun writesTrackInfoAndReadsItBack() {
        val src = Fixtures.bytes("export.pdb")
        val before = PDB.parse(src)
        val edits = mapOf(
            1L to PDBTrackEdit(title = "Demo Track 1 (Cratebox Edit)", artist = "Loopmasters", album = "Demo Album", genre = "House", comment = "peak time", rating = 5),
            3L to PDBTrackEdit(title = "Hörn – ünïcödé 🎧", artist = "Foley Dept", genre = "House"),
            6L to PDBTrackEdit(comment = "long comment ".repeat(20)),
        )
        val out = PDB.writeTracks(src, edits)
        assertEquals(emptyList(), PDB.problems(out))
        val after = PDB.parse(out)
        val t1 = after.tracks.first { it.id == 1L }; val t3 = after.tracks.first { it.id == 3L }; val t6 = after.tracks.first { it.id == 6L }
        assertEquals("Demo Track 1 (Cratebox Edit)", t1.title); assertEquals("Loopmasters", t1.artist); assertEquals("Demo Album", t1.album)
        assertEquals("House", t1.genre); assertEquals("peak time", t1.comment); assertEquals(5, t1.rating)
        assertEquals("Hörn – ünïcödé 🎧", t3.title); assertEquals("Foley Dept", t3.artist); assertEquals("House", t3.genre)
        assertEquals("long comment ".repeat(20), t6.comment)
        // everything else as it was: paths, analysis paths, other tracks, playlists, formats
        for (t in before.tracks) {
            val g = after.tracks.first { it.id == t.id }
            assertEquals(t.path, g.path); assertEquals(t.anlzPath, g.anlzPath); assertEquals(t.filename, g.filename)
            assertEquals(t.dateAdded, g.dateAdded); assertEquals(t.key, g.key); assertEquals(t.size, g.size)
            if (edits[t.id] == null) assertEquals(t, g)
        }
        assertEquals(before.playlists, after.playlists)
        assertEquals(PDB.trackFormats(src), PDB.trackFormats(out))
        // the same artist name reuses its row; "House" got one genre row for both tracks
        assertEquals(PDBWrite.rowBytes(Bytes(src), PDBPage.ARTISTS).size + 1, PDBWrite.rowBytes(Bytes(out), PDBPage.ARTISTS).size)
        assertEquals(PDBWrite.rowBytes(Bytes(src), PDBPage.GENRES).size + 1, PDBWrite.rowBytes(Bytes(out), PDBPage.GENRES).size)
        // track rows keep rekordbox's numbering, and the playlist writer still works on the result
        val rows = PDBWrite.rowBytes(Bytes(out), PDBPage.TRACKS)
        assertEquals(rows.indices.map { it * 0x20 }, rows.map { Bytes(it.bytes).u16(2) })
        val nodes = after.playlists.toMutableList(); nodes[0] = nodes[0].copy(name = "Renamed")
        assertEquals(after.tracks, PDB.parse(PDB.writePlaylists(out, nodes)).tracks)
        // and back again
        val undo = PDB.writeTracks(out, mapOf(1L to PDBTrackEdit(title = "Demo Track 1", artist = "Loopmasters", album = "", genre = "", comment = "Tracks by www.loopmasters.com", rating = 0)))
        assertEquals(before.tracks.first { it.id == 1L }, PDB.parse(undo).tracks.first { it.id == 1L })
    }

    @Test fun manyBigEditsNeedANewPage() {
        val src = Fixtures.bytes("export.pdb")
        val long = "x".repeat(600)
        val out = PDB.writeTracks(src, PDB.parse(src).tracks.associate { it.id to PDBTrackEdit(comment = long + it.id) })
        assertTrue(out.size > src.size, "the track table grew a page")
        assertEquals(emptyList(), PDB.problems(out))
        assertTrue(PDB.parse(out).tracks.all { it.comment == long + it.id })
    }

    @Test fun refusesTrackEditsItCantWrite() {
        val src = Fixtures.bytes("export.pdb")
        assertFailsWith<PDBError> { PDB.writeTracks(src, mapOf(99L to PDBTrackEdit(title = "x"))) }
        assertFailsWith<PDBError> { PDB.writeTracks(src, mapOf(1L to PDBTrackEdit(rating = 6))) }
        assertFailsWith<PDBError> { PDB.writeTracks(src, mapOf(1L to PDBTrackEdit(bpm = -1.0))) }
        assertFailsWith<PDBError> { PDB.writeTracks(ByteArray(8192), mapOf(1L to PDBTrackEdit(title = "x"))) }
    }

    // ---- the whole thing, on a copy of the stick ----
    private fun tempStick() = Stick.temp().also { temps.add(it) }
    private class Opened(val lib: USBLibrary, val pdb: ByteArray, val ol: ByteArray)
    private fun open(fs: StickFS): Opened {
        val pdb = fs.read("PIONEER/rekordbox/export.pdb")!!; val ol = fs.read("PIONEER/rekordbox/exportLibrary.db")!!
        return Opened(USBLibrary(PDB.parse(pdb), OneLibrary.read(ol)), pdb, ol)
    }

    @Test fun lockedUntilProven() {
        val fs = FileStickFS(tempStick())
        val o = open(fs)
        val key = o.lib.tracks.first { it.title == "Demo Track 1" }.key
        val change = USBTrackChanges(hot = listOf(USBCue(15.0)), bpm = 127.0, title = "x")
        assertEquals(setOf(USBWriteKind.CUES, USBWriteKind.BEATGRID, USBWriteKind.METADATA), change.kinds)
        val e = assertFailsWith<USBWriteError> { USBTrackWriter.plan(o.lib, fs, mapOf(key to change), USBWriteGate(emptySet()), o.pdb, o.ol) }
        assertEquals(USBWriteError.Kind.LOCKED, e.kind)
        // one kind proven isn't enough for a change that needs three
        assertFailsWith<USBWriteError> { USBTrackWriter.plan(o.lib, fs, mapOf(key to change), USBWriteGate(setOf(USBWriteKind.CUES)), o.pdb, o.ol) }
    }

    @Test fun planAndApplyOnAStick() {
        val root = tempStick(); val fs = FileStickFS(root)
        val o = open(fs)
        val t = o.lib.tracks.first { it.title == "Demo Track 1" }
        val hot = MutableList<USBCue?>(8) { null }
        hot[0] = USBCue(15.0, comment = "Drop"); hot[3] = USBCue(45.0, loopEnd = 46.875)
        val changes = mapOf(t.key to USBTrackChanges(cue = 0.112, hot = hot, bpm = 127.5, firstBeat = 0.112, title = "Demo Track 1 (Edit)", genre = "House", rating = 3))
        val gate = USBWriteGate(setOf(USBWriteKind.CUES, USBWriteKind.BEATGRID, USBWriteKind.METADATA))
        val plan = USBTrackWriter.plan(o.lib, fs, changes, gate, o.pdb, o.ol)
        assertEquals(setOf("$demo1.DAT", "$demo1.EXT", "PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportLibrary.db"), plan.files.map { it.rel }.toSet())
        assertEquals(listOf(t.key), plan.tracks)
        // nothing on the stick yet
        assertContentEquals(o.pdb, fs.read("PIONEER/rekordbox/export.pdb"))
        val backups = USBTrackWriter.apply(plan, fs, null)
        assertEquals(4, backups.size)
        assertEquals(emptyList(), USBSafeWrite.recover(fs))
        // read the stick again, the way Cratebox USB opens it
        val lib2 = open(fs).lib
        val t2 = lib2.track(t.key)!!
        assertEquals("Demo Track 1 (Edit)", t2.title); assertEquals("House", t2.genre); assertEquals(3, t2.rating); assertEquals(127.5, t2.bpm)
        assertTrue(lib2.inSync, "${lib2.differences}")
        assertEquals("Demo Track 1 (Edit)", lib2.one?.tracks?.first { it.id == t.olId }?.title)
        val dat = RekordboxANLZ.parse(fs.read("$demo1.DAT")!!)
        val ext = RekordboxANLZ.parse(fs.read("$demo1.EXT")!!).copy(beats = dat.beats)
        assertEquals(127.5, RekordboxANLZ.grid(dat.beats)?.bpm)
        assertEquals(0.112, RekordboxANLZ.grid(dat.beats)!!.firstBeat, 1e-9)
        val c = RekordboxANLZ.cues(ext)
        assertEquals(0.112, c.cue); assertEquals(listOf(15.0, null, null, 45.0, null, null, null, null), c.hot)
        assertEquals(46875L, ext.hot.first { it.hot == 4 }.loopMs)
        assertNotNull(RekordboxANLZ.phrases(ext), "rekordbox's phrases still read")
        assertEquals(3, lib2.one?.cues?.count { it.track == t.olId })
        // the other tracks' analysis files untouched
        assertContentEquals(Stick.file("$demo2.DAT"), fs.read("$demo2.DAT"))
    }

    @Test fun applyPutsBackWhatItWroteWhenALaterFileFails() {
        val fs = FileStickFS(tempStick())
        val o = open(fs)
        val t = o.lib.tracks.first { it.title == "Demo Track 1" }
        val plan = USBTrackWriter.plan(o.lib, fs, mapOf(t.key to USBTrackChanges(title = "Edited")), USBWriteGate(setOf(USBWriteKind.METADATA)), o.pdb, o.ol)
        assertEquals(listOf("PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportLibrary.db"), plan.files.map { it.rel })
        // OneLibrary changed on the stick after it was read (rekordbox exported to it?): its write is refused
        plan.files[1].old = byteArrayOf(1, 2, 3)
        assertFailsWith<USBWriteError> { USBTrackWriter.apply(plan, fs, null) }
        assertContentEquals(o.pdb, fs.read("PIONEER/rekordbox/export.pdb"), "the Device Library was put back")
        assertContentEquals(o.ol, fs.read("PIONEER/rekordbox/exportLibrary.db"))
        assertEquals(emptyList(), USBSafeWrite.recover(fs))
    }

    @Test fun aTrackWithoutAnalysisCantTakeCues() {
        val root = tempStick(); val fs = FileStickFS(root)
        val o = open(fs)
        val t = o.lib.tracks.first { it.title == "Demo Track 1" }
        File(root, "$demo1.DAT").delete()
        assertFailsWith<USBWriteError> { USBTrackWriter.plan(o.lib, fs, mapOf(t.key to USBTrackChanges(cue = 1.0)), USBWriteGate(setOf(USBWriteKind.CUES)), o.pdb, o.ol) }
    }
}
