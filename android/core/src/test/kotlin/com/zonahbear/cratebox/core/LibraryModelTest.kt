package com.zonahbear.cratebox.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class LibraryModelTest {
    @Test fun trackRecordsRoundTripAndReadIOS() {
        val r = TrackRecord.fresh("dir-Music", "House/Artist - Some - Title.mp3", 1234, 1.7e9)
        assertEquals("Artist", r.artist); assertEquals("Some - Title", r.title); assertEquals("dir-Music|House/Artist - Some - Title.mp3|1234", r.id)
        r.bpm = 124.0; r.firstBeat = 0.12; r.key = 5; r.phrases = listOf(Phrase(0.12, 16, "Intro")); r.ver = 7
        assertEquals(listOf(r), TrackRecord.parseAll(TrackRecord.encodeAll(listOf(r))))
        // Swift's JSONEncoder leaves nil optionals out
        val ios = """[{"id":"a","folder":"f","rel":"x.wav","title":"x","artist":"","size":10,"mtime":0,"key":-1,"duration":0,"phrases":[],"gridManual":false,"ver":0}]"""
        val p = TrackRecord.parseAll(ios).single()
        assertNull(p.bpm); assertEquals("x.wav", p.rel)
        assertEquals(emptyList(), TrackRecord.parseAll("not json"))
    }

    @Test fun playlistsRules() {
        var saved = ""
        val pl = Playlists(null) { saved = it }
        val folder = pl.new("Gigs", folder = true)
        val a = pl.new(pl.nextName("Playlist"), parent = folder.id)
        assertEquals("Playlist 1", a.name)
        pl.add(listOf(listOf("t1", "One", "A", "1.mp3"), listOf("t2", "Two", "B", "2.mp3"), listOf("t3", "Three", "C", "3.mp3")), a.id)
        pl.move(setOf(0), 3, a.id)
        assertEquals(listOf("t2", "t3", "t1"), pl.get(a.id)!!.items)
        pl.remove(setOf(1), a.id)
        assertEquals(listOf("t2", "t1"), pl.get(a.id)!!.items)
        assertEquals("Gigs / Playlist 1", pl.path(pl.get(a.id)!!))
        pl.moveList(folder.id, a.id)                                       // a folder can't go inside its own child
        assertNull(pl.get(folder.id)!!.parent)
        val reread = Playlists(saved) {}
        assertEquals(pl.lists, reread.lists)
        pl.delete(folder.id)
        assertEquals(emptyList(), pl.lists)
    }
}
