// export.pdb: writing track info (title, artist, album, genre, comment, rating, BPM) into the track rows.
// A port of PDBWrite.swift. Row layouts follow crate-digger (rekordbox_pdb.ksy). Fixed-size fields (rating,
// BPM, the artist / album / genre ids) are patched in place; a changed title or comment rebuilds that track row
// (the other strings are copied byte for byte, ISRC's odd encoding included) and repacks the track table the
// way writePlaylists repacks the playlist tables, keeping each page's flags. A new artist, album or genre name
// gets a new row. Read back before returning: the edits as asked, every other track, playlist and file format
// as it was. Not proven on a player yet: callers keep it locked (USBWriteGate, METADATA / BEATGRID).
package com.zonahbear.cratebox.core

import kotlin.math.abs
import kotlin.math.max

data class PDBTrackEdit(
    val title: String? = null, val artist: String? = null, val album: String? = null, val genre: String? = null,
    val comment: String? = null, val rating: Int? = null, val bpm: Double? = null,
) {
    val isEmpty get() = this == PDBTrackEdit()
}

object PDBWrite {
    private const val TRACK_ROW_HEADER = 0x5e + 2 * 21

    /** bytes a DeviceSQL string takes at `pos`, its header included */
    internal fun stringLength(d: Bytes, pos: Int): Int {
        if (pos >= d.count) return 0
        val lk = d.u8(pos)
        if (lk == 0x40 || lk == 0x90) return if (pos + 3 <= d.count) d.u16(pos + 1) else 0
        return if (lk and 1 == 1) lk shr 1 else 0
    }

    internal class Row(val at: Int, var bytes: ByteArray)

    /** every present row of a table, in reading order, as its own bytes */
    internal fun rowBytes(d: Bytes, type: PDBPage): MutableList<Row> {
        val out = ArrayList<Row>()
        PDB.rows(d, type.raw) { o ->
            val end = when (type) {
                PDBPage.TRACKS -> o + (0 until 21).maxOf { k -> val s = d.u16(o + 0x5e + 2 * k); s + stringLength(d, o + s) }
                PDBPage.ARTISTS -> { val far = d.u16(o) and 0x04 != 0; val s = if (far) d.u16(o + 0x0a) else d.u8(o + 9); o + s + stringLength(d, o + s) }
                PDBPage.ALBUMS -> { val far = d.u16(o) and 0x04 != 0; val s = if (far) d.u16(o + 0x16) else d.u8(o + 21); o + s + stringLength(d, o + s) }
                PDBPage.GENRES -> o + 4 + stringLength(d, o + 4)
                else -> o
            }
            out.add(Row(o, d.b.copyOfRange(o, minOf(d.count, max(end, o)))))
        }
        return out
    }

    private fun le32(v: Long) = PDB.le32(v)

    /** Writes `edits` (by track id) into a copy of export.pdb. Throws, writing nothing, when a track isn't there
     *  or the result doesn't read back as asked. */
    fun writeTracks(input: ByteArray, edits: Map<Long, PDBTrackEdit>): ByteArray {
        if (input.size < 28) throw PDBError.notPDB()
        val d = Bytes(input)
        val PS = d.u32(4); val NT = d.u32(8)
        if (PS < 512 || PS > 65536 || NT < 9 || NT > 64) throw PDBError.notPDB()
        val before = PDB.parse(input)
        val trackRows = rowBytes(d, PDBPage.TRACKS)
        if (trackRows.size != before.tracks.size) throw PDBError.readBack("couldn't read every track row")
        val index = HashMap<Long, Int>()
        for ((i, r) in trackRows.withIndex()) index.putIfAbsent(d.u32(r.at + 72), i)
        for (id in edits.keys) if (index[id] == null) throw PDBError.readBack("track $id isn't in the Device Library")
        for ((id, e) in edits) {
            e.rating?.let { r -> if (r < 0 || r > 5) throw PDBError.readBack("track $id: rating $r") }
            e.bpm?.let { b -> if (!(b > 0 && b * 100 < 4294967295.0)) throw PDBError.readBack("track $id: BPM $b") }
        }

        // names → ids, adding rows for names the library doesn't have yet
        val artistRows = rowBytes(d, PDBPage.ARTISTS); val albumRows = rowBytes(d, PDBPage.ALBUMS); val genreRows = rowBytes(d, PDBPage.GENRES)
        fun artistName(r: ByteArray): String { val b = Bytes(r); return PDB.string(b, if (b.u16(0) and 0x04 != 0) b.u16(0x0a) else b.u8(9)) }
        fun albumName(r: ByteArray): String { val b = Bytes(r); return PDB.string(b, if (b.u16(0) and 0x04 != 0) b.u16(0x16) else b.u8(21)) }
        val artists = HashMap<String, Long>(); val albums = HashMap<String, Long>(); val genres = HashMap<String, Long>()
        var maxArtist = 0L; var maxAlbum = 0L; var maxGenre = 0L
        for (r in artistRows) { val id = Bytes(r.bytes).u32(4); maxArtist = max(maxArtist, id); artists.putIfAbsent(artistName(r.bytes), id) }
        for (r in albumRows) { val b = Bytes(r.bytes); val id = b.u32(12); maxAlbum = max(maxAlbum, id); albums.putIfAbsent(albumName(r.bytes) + "\u001f${b.u32(8)}", id) }
        for (r in genreRows) { val b = Bytes(r.bytes); val id = b.u32(0); maxGenre = max(maxGenre, id); genres.putIfAbsent(PDB.string(b, 4), id) }
        val addedArtists = artistRows.size; val addedAlbums = albumRows.size; val addedGenres = genreRows.size
        fun artistId(name: String): Long {
            if (name.isEmpty()) return 0
            artists[name]?.let { return it }
            maxArtist += 1; artists[name] = maxArtist
            val row = byteArrayOf(0x60, 0, 0, 0) + le32(maxArtist) + byteArrayOf(0x03, 0x0a) + PDB.stringBytes(name)
            artistRows.add(Row(-1, row))
            return maxArtist
        }
        fun albumId(name: String, artist: Long): Long {
            if (name.isEmpty()) return 0
            val k = name + "\u001f$artist"
            albums[k]?.let { return it }
            maxAlbum += 1; albums[k] = maxAlbum
            val row = byteArrayOf(0x80.toByte(), 0, 0, 0) + le32(0) + le32(artist) + le32(maxAlbum) + le32(0) + byteArrayOf(0x03, 0x16) + PDB.stringBytes(name)
            albumRows.add(Row(-1, row))
            return maxAlbum
        }
        fun genreId(name: String): Long {
            if (name.isEmpty()) return 0
            genres[name]?.let { return it }
            maxGenre += 1; genres[name] = maxGenre
            genreRows.add(Row(-1, le32(maxGenre) + PDB.stringBytes(name)))
            return maxGenre
        }

        var resized = false
        for ((id, e) in edits.entries.sortedBy { it.key }) {
            if (e.isEmpty) continue
            val i = index[id]!!
            var r = trackRows[i].bytes.copyOf()
            fun put32(o: Int, v: Long) { le32(v).copyInto(r, o) }
            val row = Bytes(r.copyOf())
            e.artist?.let { put32(68, artistId(it)) }
            e.album?.let { put32(64, albumId(it, Bytes(r).u32(68))) }
            e.genre?.let { put32(60, genreId(it)) }
            e.rating?.let { r[89] = it.toByte() }
            e.bpm?.let { put32(56, Math.round(it * 100)) }
            if (e.title != null || e.comment != null) {
                // rebuild: the fixed part, then the 21 strings in their order, offsets pointing at them
                val strings = (0 until 21).map { k ->
                    val s = row.u16(0x5e + 2 * k)
                    row.b.copyOfRange(s, s + stringLength(row, s))
                }.toMutableList()
                e.title?.let { strings[17] = PDB.stringBytes(it) }
                e.comment?.let { strings[16] = PDB.stringBytes(it) }
                val order = (0 until 21).sortedWith(compareBy<Int> { row.u16(0x5e + 2 * it) }.thenBy { it })
                var nr = r.copyOfRange(0, TRACK_ROW_HEADER)
                val ofs = IntArray(21)
                for (k in order) { ofs[k] = nr.size; nr += strings[k] }
                for (k in 0 until 21) { nr[0x5e + 2 * k] = (ofs[k] and 0xff).toByte(); nr[0x5f + 2 * k] = (ofs[k] shr 8).toByte() }
                if (nr.size > 0xffff) throw PDBError.rowTooBig()
                if (nr.size != trackRows[i].bytes.size) resized = true
                r = nr
            }
            trackRows[i].bytes = r
        }

        var out = input.copyOf()
        if (resized) out = PDB.pack(out, PDBPage.TRACKS.raw, trackRows.map { it.bytes }, keepFlags = true, indexShift = true)
        else for (r in trackRows) r.bytes.copyInto(out, r.at)
        if (artistRows.size > addedArtists) out = PDB.pack(out, PDBPage.ARTISTS.raw, artistRows.map { it.bytes }, keepFlags = true, indexShift = true)
        if (albumRows.size > addedAlbums) out = PDB.pack(out, PDBPage.ALBUMS.raw, albumRows.map { it.bytes }, keepFlags = true, indexShift = true)
        if (genreRows.size > addedGenres) out = PDB.pack(out, PDBPage.GENRES.raw, genreRows.map { it.bytes }, keepFlags = true)

        // read back
        val after = PDB.parse(out)
        val problems = PDB.problems(out)
        if (problems.isNotEmpty()) throw PDBError.readBack(problems[0])
        if (after.playlists != before.playlists) throw PDBError.readBack("playlists changed")
        if (after.tracks.size != before.tracks.size) throw PDBError.readBack("track count changed")
        val got = HashMap<Long, PDBTrack>()
        for (t in after.tracks) got.putIfAbsent(t.id, t)
        for (t in before.tracks) {
            var g = got[t.id] ?: throw PDBError.readBack("track ${t.id} went missing")
            val e = edits[t.id]
            if (e != null) {
                e.title?.let { if (g.title != it) throw PDBError.readBack("title didn't read back: $it") }
                e.artist?.let { if (g.artist != it) throw PDBError.readBack("artist didn't read back: $it") }
                e.album?.let { if (g.album != it) throw PDBError.readBack("album didn't read back: $it") }
                e.genre?.let { if (g.genre != it) throw PDBError.readBack("genre didn't read back: $it") }
                e.comment?.let { if (g.comment != it) throw PDBError.readBack("comment didn't read back") }
                e.rating?.let { if (g.rating != it) throw PDBError.readBack("rating didn't read back") }
                e.bpm?.let { if (abs(g.bpm - Math.round(it * 100) / 100.0) > 1e-9) throw PDBError.readBack("BPM didn't read back") }
                // the rest of the row as it was
                g = g.copy(title = t.title, artist = t.artist, album = t.album, genre = t.genre, comment = t.comment, rating = t.rating, bpm = t.bpm)
            }
            if (g != t) throw PDBError.readBack("track ${t.id} changed in a field that wasn't edited")
        }
        if (PDB.trackFormats(out) != PDB.trackFormats(input)) throw PDBError.readBack("file formats changed")
        return out
    }
}

/** PDB.writeTracks, as the Swift calls it */
fun PDB.writeTracks(input: ByteArray, edits: Map<Long, PDBTrackEdit>): ByteArray = PDBWrite.writeTracks(input, edits)
