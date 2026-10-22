package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Port of PDBTests.swift: the export.pdb code against the web app's (tools/rekordbox.js). Fixtures/write-*.pdb
 *  were written by the JS writer from Fixtures/export.pdb with the nodes in write-*.json; same bytes here. */
class PDBTest {
    private fun s(o: JsonObject, k: String) = o[k]!!.jsonPrimitive.content
    private fun ids(o: JsonObject, k: String) = o[k]!!.jsonArray.map { it.jsonPrimitive.long }

    @Test fun readsLikeTheWebApp() {
        val db = PDB.parse(Fixtures.bytes("export.pdb"))
        val want = Json.parseToJsonElement(Fixtures.text("read.json")).jsonObject
        val tracks = want["tracks"]!!.jsonArray.map { it.jsonObject }.map { t ->
            PDBTrack(t["id"]!!.jsonPrimitive.long, s(t, "title"), s(t, "artist"), s(t, "album"), s(t, "genre"), s(t, "label"), s(t, "key"),
                t["bpm"]!!.jsonPrimitive.double, t["duration"]!!.jsonPrimitive.int, t["size"]!!.jsonPrimitive.long, t["sampleRate"]!!.jsonPrimitive.long,
                t["rating"]!!.jsonPrimitive.int, t["color"]!!.jsonPrimitive.int, s(t, "path"), s(t, "filename"), s(t, "anlzPath"), s(t, "comment"), s(t, "dateAdded"))
        }
        val lists = want["playlists"]!!.jsonArray.map { it.jsonObject }.map { p ->
            PDBPlaylist(p["id"]!!.jsonPrimitive.long, p["parent"]!!.jsonPrimitive.long, p["unk"]!!.jsonPrimitive.long, p["sort"]!!.jsonPrimitive.long,
                p["folder"]!!.jsonPrimitive.boolean, s(p, "name"), ids(p, "tracks"))
        }
        assertEquals(tracks, db.tracks)
        assertEquals(lists, db.playlists)
        assertEquals(6, db.tracks.size)
        val d1 = db.tracks.first { it.title == "Demo Track 1" }
        assertEquals("Loopmasters", d1.artist); assertEquals("Fm", d1.key); assertEquals(128.0, d1.bpm)
        assertEquals("/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3", d1.path)
    }

    @Test fun writesByteForByteLikeTheWebApp() {
        val src = Fixtures.bytes("export.pdb")
        for (c in listOf("same", "edit", "big")) {
            val nodes = Json.parseToJsonElement(Fixtures.text("write-$c.json")).jsonArray.map { it.jsonObject }.map { n ->
                PDBPlaylist(n["id"]!!.jsonPrimitive.long, n["parent"]!!.jsonPrimitive.long, n["unk"]?.jsonPrimitive?.long ?: 0,
                    folder = n["folder"]!!.jsonPrimitive.boolean, name = s(n, "name"), tracks = ids(n, "tracks"))
            }
            val out = PDB.writePlaylists(src, nodes)
            val want = Fixtures.bytes("write-$c.pdb")
            assertEquals(want.size, out.size, c)
            val firstDiff = out.indices.firstOrNull { out[it] != want[it] }
            assertEquals(null, firstDiff, "$c: first differing byte")
        }
        assertContentEquals(Fixtures.bytes("export.pdb"), src, "input untouched")
    }

    @Test fun refusesBadInput() {
        assertFailsWith<PDBError> { PDB.writePlaylists(ByteArray(8192), emptyList()) }
        val src = Fixtures.bytes("export.pdb")
        assertFailsWith<PDBError> { PDB.writePlaylists(src, listOf(PDBPlaylist(1, name = "a"), PDBPlaylist(1, name = "b"))) }
        assertFailsWith<PDBError> { PDB.writePlaylists(src, listOf(PDBPlaylist(2, parent = 99, name = "x"))) }
    }

    @Test fun strings() {
        for (str in listOf("", "Peak time", "x".repeat(126), "x".repeat(127), "Ünïcödé 🎧"))
            assertEquals(str, PDB.string(Bytes(PDB.stringBytes(str)), 0))
    }

    @Test fun damagedPDBIsReported() {
        val pdb = Fixtures.bytes("export.pdb")
        assertTrue(PDB.problems(pdb).isEmpty(), "${PDB.problems(pdb)}")
        // point the first table's chain past the end of the file
        pdb[28 + 8] = 0xff.toByte(); pdb[28 + 9] = 0xff.toByte()
        assertTrue(PDB.problems(pdb).isNotEmpty())
        assertTrue(PDB.problems(pdb.copyOfRange(0, 100)).isNotEmpty())
    }
}

class ANLZTest {
    private fun file(n: String) = Fixtures.bytes("anlz/$n")

    /** the same numbers tests/test_rekordbox.js checks on the web app's parser */
    @Test fun demoTrack1() {
        val dat = RekordboxANLZ.parse(file("ANLZ0000.DAT")); val ext = RekordboxANLZ.parse(file("ANLZ0000.EXT"))
        assertEquals(368, dat.beats.size)
        val g = RekordboxANLZ.grid(dat.beats)!!
        assertEquals(128.0, g.bpm); assertEquals(0.025, g.firstBeat, 1e-9)
        val ph = RekordboxANLZ.phrases(ext.copy(beats = dat.beats))!!
        assertEquals(19, ph.size); assertEquals(0.025, ph[0].start, 1e-9)
        assertTrue(ph.all { it.bars >= 1 })
        assertNotNull(RekordboxANLZ.waveform(file("ANLZ0000.EXT"), 172.0))
    }

    @Test fun keyNames() {
        assertEquals(17, RekordboxANLZ.keyIndex("Fm")); assertEquals(21, RekordboxANLZ.keyIndex("Am")); assertEquals(21, RekordboxANLZ.keyIndex("8A"))
        assertEquals(0, RekordboxANLZ.keyIndex("C")); assertEquals(15, RekordboxANLZ.keyIndex("Ebm")); assertEquals(-1, RekordboxANLZ.keyIndex(""))
    }
}

/** rekordbox XML both ways, on the file tests/test_playlists.py imports into the web app */
class XMLTest {
    private val xml = """
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
    """.trimIndent()

    @Test fun import() {
        val x = RekordboxXML.parse(xml.toByteArray())
        assertEquals(2, x.tracks.size)
        val h = x.tracks["11"]!!
        assertEquals("Test Artist - House Groove 126.wav", h.filename); assertEquals(13230044, h.size)
        assertEquals(126.0, h.grid!!.bpm); assertEquals(0.367, h.grid!!.firstBeat)
        assertEquals(3, h.marks.size); assertEquals(21, RekordboxANLZ.keyIndex(h.key))
        assertEquals(listOf("Bass", "Wobbles", "Warmup"), x.playlists.map { it.name })
        assertEquals(0, x.playlists[1].parent); assertEquals(null, x.playlists[2].parent)
        assertEquals(listOf("11", "12"), x.playlists[1].tracks)
        assertFailsWith<RekordboxXML.NotRekordbox> { RekordboxXML.parse("<foo/>".toByteArray()) }
    }

    @Test fun exportReadsBack() {
        val t = RekordboxXML.ExportTrack("a", "House Groove 126", "Test Artist", "Test Artist - House Groove 126.wav", "music/Test Artist - House Groove 126.wav",
            13230044, 75.0, 126.0, 0.367, 21, 0.367, listOf(15.6, null, null, 30.0, null, null, null, null))
        val s = RekordboxXML.export(listOf(t), listOf(RekordboxXML.ExportList("f", "Saturday", true, null, 0, emptyList()),
            RekordboxXML.ExportList("p", "Peak time", false, "f", 0, listOf("a", "missing"))), root = "C:\\Users\\jonah\\Music")
        assertTrue(s.contains("Location=\"file://localhost/C:/Users/jonah/Music/Test%20Artist%20-%20House%20Groove%20126.wav\""), s)
        val x = RekordboxXML.parse(s.toByteArray())
        assertEquals(126.0, x.tracks["1"]?.grid?.bpm); assertEquals("Am", x.tracks["1"]?.key)
        assertEquals(listOf("Saturday", "Peak time"), x.playlists.map { it.name }); assertEquals(listOf("1"), x.playlists[1].tracks)
        assertEquals(3, x.tracks["1"]?.marks?.size)
    }
}
