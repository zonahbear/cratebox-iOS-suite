package com.zonahbear.cratebox.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PDBTreeTest {
    @Test fun editsAndWriteOrder() {
        var t = listOf(PDBPlaylist(1, 0, sort = 1, folder = true, name = "F"), PDBPlaylist(2, 1, sort = 1, name = "A", tracks = listOf(10, 11, 12)))
        val (t2, id) = PDBTree.newNode(t, "B", folder = false, parent = 1)
        assertEquals(3L, id); t = t2
        t = PDBTree.moveTracks(t, 2, setOf(2), 0)
        assertEquals(listOf(12L, 10, 11), t.first { it.id == 2L }.tracks)
        assertNull(PDBTree.moveNode(t, 1, 2), "a folder can't go inside itself")
        t = PDBTree.duplicate(t, 2)
        assertEquals("A copy", t.last().name); assertEquals(listOf(12L, 10, 11), t.last().tracks)
        assertEquals(listOf(1L, 2, 3, 4), PDBTree.forWrite(t).map { it.id })
        assertEquals(emptyList(), PDBTree.delete(t, 1))
    }

    @Test fun editedTreeWritesToTheRealStick() {
        val pdb = Stick.file("PIONEER/rekordbox/export.pdb")
        val db = PDB.parse(pdb)
        val (tree, id) = PDBTree.newNode(db.playlists, "From Android", folder = false)
        val withTracks = PDBTree.addTracks(tree, id, db.tracks.take(3).map { it.id })
        val out = PDB.writePlaylists(pdb, PDBTree.forWrite(withTracks))
        val back = PDB.parse(out).playlists.first { it.id == id }
        assertEquals("From Android", back.name); assertEquals(db.tracks.take(3).map { it.id }, back.tracks)
        assertEquals("${pdb.size}", PDBTree.stamp(pdb).substringBefore(":"))
    }
}
