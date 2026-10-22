package com.zonahbear.cratebox.core

import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/** SQLCipher against a real rekordbox database and SQLCipher's own output, and OneLibrary read and write: the
 *  matching parts of USBTests.swift and USBWriterTests.swift. */
class OneLibraryTest {
    @BeforeTest fun sqlite() = JdbcSQLite.install()

    companion object {
        val rb6Key: String by lazy {
            val m = intArrayOf(0x77, 0x42, 0x53, 0x12, 0x01, 0x56, 0x57, 0x4a, 0x43, 0x47, 0x5d, 0x4b, 0x45, 0x74, 0x11, 0x52, 0x41, 0x03, 0x04, 0x0e, 0x40, 0x46, 0x12, 0x07, 0x4b, 0x17, 0x74, 0x16, 0x58, 0x47, 0x54, 0x56,
                0x5c, 0x1a, 0x17, 0x40, 0x5c, 0x16, 0x43, 0x27, 0x41, 0x50, 0x41, 0x01, 0x04, 0x58, 0x19, 0x18, 0x45, 0x52, 0x40, 0x46, 0x22, 0x43, 0x07, 0x12, 0x51, 0x51, 0x59, 0x48, 0x18, 0x40, 0x5c, 0x44)
            val mask = "Cratebox test".toByteArray()
            String(ByteArray(m.size) { (m[it] xor mask[it % mask.size].toInt()).toByte() })
        }
        val cues = listOf(
            ANLZCuePoint(hot = 1, ms = 15000, comment = "Drop"),
            ANLZCuePoint(hot = 2, ms = 30000, loopMs = 31875),
            ANLZCuePoint(hot = 4, ms = 45000, comment = "Ünïcödé 🎧", color = ANLZHotCueColor(0x2a, 0xff, 0x80, 0x00)),
            ANLZCuePoint(hot = 8, ms = 60000),
            ANLZCuePoint(hot = 0, ms = 25),
            ANLZCuePoint(hot = 0, ms = 90000, loopMs = 93750, comment = "Breakdown loop"),
        )
    }

    @Test fun decryptsARealRekordboxDatabase() {
        val enc = Fixtures.bytes("sqlcipher/rekordbox6-master-4pages.enc"); val plain = Fixtures.bytes("sqlcipher/rekordbox6-master-4pages.plain")
        val c = SQLCipherCodec(rb6Key, enc.copyOfRange(0, 16))
        assertContentEquals(plain, c.decrypt(enc))
        // and back, with the file's own IVs: byte for byte
        val ivs = (0 until enc.size / 4096).map { p -> enc.copyOfRange(p * 4096 + 4096 - 80, p * 4096 + 4096 - 64) }
        assertContentEquals(enc, c.encrypt(plain, ivs))
        // a wrong key is caught by the page check, not read as garbage
        val wrong = SQLCipherCodec("not the key", enc.copyOfRange(0, 16))
        val e = assertFailsWith<SQLCipherError> { wrong.decrypt(enc) }
        assertEquals(SQLCipherError.badHMAC(1), e)
    }

    @Test fun readsOneLibraryMadeBySQLCipher() {
        val one = OneLibrary.read(Fixtures.bytes("onelibrary/exportLibrary.db"))
        assertEquals(listOf("ok"), one.integrity)
        assertEquals(6, one.tracks.size)
        val d1 = one.tracks.first { it.title == "Demo Track 1" }
        assertEquals("Loopmasters", d1.artist); assertEquals("Fm", d1.key); assertEquals(128.0, d1.bpm)
        assertEquals("/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3", d1.path)
        assertEquals(listOf("Playlist 1", "Folder", "Sub Playlist"), one.playlists.map { it.name })
        assertEquals(listOf(1L, 2L), one.playlists.first { it.name == "Sub Playlist" }.tracks)
        assertEquals(2, one.cues.size)
        assertEquals("CRATEBOX TEST", one.deviceName)
    }

    @Test fun writesOneLibraryPlaylistsAndReadsThemBack() {
        val src = Fixtures.bytes("onelibrary/exportLibrary.db")
        val nodes = OneLibrary.read(src).playlists.toMutableList()
        nodes[0] = nodes[0].copy(name = "Peak time", tracks = listOf(2, 1, 5))
        nodes.add(OLPlaylist(20, 0, 0, false, "Warm up", listOf(3), 0))
        val out = OneLibrary.writePlaylists(src, nodes)
        assertFalse(SQLCipherCodec.isPlainSQLite(out), "still encrypted")
        assertContentEquals(src.copyOfRange(0, 16), out.copyOfRange(0, 16), "same salt")
        val back = OneLibrary.read(out)
        assertEquals(listOf("ok"), back.integrity)
        assertEquals("Peak time", back.playlists.first { it.id == nodes[0].id }.name)
        assertEquals(listOf(2L, 1L, 5L), back.playlists.first { it.id == nodes[0].id }.tracks)
        assertEquals(listOf(3L), back.playlists.first { it.id == 20L }.tracks)
        assertEquals(OneLibrary.read(src).tracks, back.tracks, "tracks untouched")
        // refuses what it can't do, writing nothing
        assertFailsWith<OneLibraryError> { OneLibrary.writePlaylists(src, listOf(OLPlaylist(1, 0, 0, false, "x", listOf(999), 0))) }
        assertFailsWith<OneLibraryError> { OneLibrary.writePlaylists(src, listOf(OLPlaylist(2, 77, 0, false, "x", emptyList(), 0))) }
    }

    @Test fun writesOneLibraryTrackInfo() {
        val src = Fixtures.bytes("onelibrary/exportLibrary.db")
        val before = OneLibrary.read(src)
        val out = OneLibrary.writeTracks(src, mapOf(
            1L to OLTrackEdit(title = "Demo Track 1 (Cratebox Edit)", artist = "New Artist", album = "Demo Album", genre = "House", comment = "peak time", rating = 4, bpm = 127.5),
            2L to OLTrackEdit(artist = "Loopmasters")))
        assertFalse(SQLCipherCodec.isPlainSQLite(out)); assertContentEquals(src.copyOfRange(0, 16), out.copyOfRange(0, 16))
        val after = OneLibrary.read(out)
        assertEquals(listOf("ok"), after.integrity)
        val t = after.tracks.first { it.id == 1L }
        assertEquals("Demo Track 1 (Cratebox Edit)", t.title); assertEquals("New Artist", t.artist); assertEquals("Demo Album", t.album)
        assertEquals("House", t.genre); assertEquals("peak time", t.comment); assertEquals(4L, t.rating); assertEquals(127.5, t.bpm)
        assertEquals(before.tracks.first { it.id == 2L }, after.tracks.first { it.id == 2L }, "same artist: nothing changes")
        assertEquals(before.playlists, after.playlists); assertEquals(before.cues, after.cues)
        assertFailsWith<OneLibraryError> { OneLibrary.writeTracks(src, mapOf(99L to OLTrackEdit(title = "x"))) }
    }

    @Test fun writesOneLibraryCues() {
        val src = Fixtures.bytes("onelibrary/exportLibrary.db")
        val before = OneLibrary.read(src)
        val after = OneLibrary.read(OneLibrary.writeCues(src, mapOf(1L to cues)))
        assertEquals(listOf("ok"), after.integrity)
        val mine = after.cues.filter { it.track == 1L }
        assertEquals(cues.size, mine.size)
        assertEquals(listOf(1L, 2L, 4L, 8L), mine.filter { it.kind > 0 }.map { it.kind })
        assertEquals(31875.0, mine.first { it.kind == 2L }.outMs)
        assertEquals("Drop", mine.first { it.kind == 1L }.comment)
        assertEquals(before.tracks, after.tracks); assertEquals(before.playlists, after.playlists)
        assertEquals(emptyList(), OneLibrary.read(OneLibrary.writeCues(src, mapOf(1L to emptyList()))).cues.filter { it.track == 1L })
        assertFailsWith<OneLibraryError> { OneLibrary.writeCues(src, mapOf(99L to cues)) }
    }
}
