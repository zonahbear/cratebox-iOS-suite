package com.zonahbear.cratebox.core

import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class USBEditsTest {
    @BeforeTest fun sqlite() = JdbcSQLite.install()
    private fun lib() = USBLibrary(PDB.parse(Fixtures.bytes("export.pdb")), OneLibrary.read(Fixtures.bytes("onelibrary/exportLibrary.db")))

    @Test fun stagedPlaylistsWriteToBothLibraries() {
        val lib = lib()
        val e = USBEdits().apply { loaded(lib, keepNodes = false) }
        assertFalse(e.playlistsChanged)
        val id = e.newNode("Gig", folder = false)
        e.add(lib.tracks.take(2).map { it.key }, id)
        e.moveTracks(id, setOf(1), 0)
        assertTrue(e.playlistsChanged)
        assertEquals(listOf("New playlist \"Gig\"", "Add 2 to \"Gig\"", "Reorder \"Gig\""), e.changeLog)

        val (pn, why) = e.pdbNodes(lib)
        assertNull(why)
        val pdbOut = PDB.writePlaylists(Fixtures.bytes("export.pdb"), pn!!)
        val gig = PDB.parse(pdbOut).playlists.first { it.name == "Gig" }
        assertEquals(lib.tracks.take(2).reversed().map { it.pdbId }, gig.tracks)

        val (on, why2) = e.olNodes(lib)
        assertNull(why2)
        val olOut = OneLibrary.writePlaylists(Fixtures.bytes("onelibrary/exportLibrary.db"), on!!)
        val both = USBLibrary(PDB.parse(pdbOut), OneLibrary.read(olOut))
        assertTrue(both.inSync, "${both.differences}")
        assertEquals(e.nodes.map { it.name }.sorted(), both.playlists.map { it.name }.sorted())
    }

    @Test fun trackEditsAreGatedAndRoundTrip() {
        val lib = lib()
        val e = USBEdits()
        val k = lib.tracks[0].key
        e.addMemory(k, "x", 12.5, loopEnd = 16.5)
        e.edit(k) { it.copy(hot = listOf(1.0, null, 3.0), bpm = 125.0) }
        assertEquals(setOf(USBWriteKind.CUES, USBWriteKind.BEATGRID), e.trackChanges()[k]!!.kinds)
        assertNotNull(e.trackEditBlocker(lib, USBWriteGate(emptySet())), "locked until proven")
        assertNull(e.trackEditBlocker(lib, USBWriteGate(setOf(USBWriteKind.CUES, USBWriteKind.BEATGRID))))
        assertEquals(e.edits, USBTrackEdit.parseAll(USBTrackEdit.encodeAll(e.edits)))
        // an iOS edits file: Codable keys, nils left out
        val ios = """{"/contents/a.mp3":{"hot":[1.5,null],"memory":[{"id":"ABC","time":2,"comment":""}],"rating":3}}"""
        val p = USBTrackEdit.parseAll(ios).getValue("/contents/a.mp3")
        assertEquals(listOf(1.5, null), p.hot); assertEquals("ABC", p.memory!![0].id); assertEquals(3, p.rating); assertNull(p.bpm)
        e.edit(k) { USBTrackEdit() }
        assertTrue(e.edits.isEmpty(), "an emptied edit goes away")
    }

    @Test fun xmlAndFixList() {
        val lib = lib()
        val e = USBEdits().apply { loaded(lib, keepNodes = false) }
        val x = e.exportXML(lib, "file://localhost/Volumes/USB/")
        val back = RekordboxXML.parse(x.toByteArray())
        assertEquals(lib.playlists.count { !it.folder }, back.playlists.count { !it.folder })
        val csv = e.fixListCSV(lib, "USB", listOf(lib.tracks[0].key), emptyList())
        assertTrue(csv.lines()[2].startsWith("\"${lib.tracks[0].path}\""))
    }
}
