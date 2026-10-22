// rekordbox's OneLibrary (formerly Device Library Plus) on a USB stick: PIONEER/rekordbox/exportLibrary.db,
// an SQLCipher-encrypted SQLite database. Newer players (CDJ-3000X, OPUS-QUAD, XDJ-AZ, OMNIS-DUO, …) read it
// instead of export.pdb. Tables and columns follow pyrekordbox's onelibrary models (MIT licence). A port of
// OneLibrary.swift and OneLibraryWrite.swift.
//
// Reading is complete for what Cratebox USB needs (tracks, playlists, cues). Writing works on a decrypted copy
// and is checked by reading it back, but has NOT been proven on hardware yet: callers keep it locked (see
// USBWriteGate) until it has been. Guesses in the track/cue writer are listed at the top of OneLibraryWrite.swift.
package com.zonahbear.cratebox.core

import java.io.File
import java.util.UUID
import kotlin.math.abs

data class OLTrack(
    val id: Long,
    val title: String, val artist: String, val album: String, val genre: String, val label: String, val key: String, val comment: String,
    val bpm: Double, val durationMs: Long,
    val path: String, val fileName: String, val fileSize: Long, val fileType: Long,
    val bitrate: Long, val bitDepth: Long, val sampleRate: Long,
    val anlzPath: String, val rating: Long, val color: Long,
)
data class OLPlaylist(val id: Long, val parent: Long, val seq: Long, val folder: Boolean, val name: String, val tracks: List<Long>, val attribute: Long)
data class OLCue(val id: Long, val track: Long, val kind: Long, val inMs: Double, val outMs: Double?, val comment: String, val color: Long)

data class OneLibraryDatabase(
    val tracks: List<OLTrack> = emptyList(),
    val playlists: List<OLPlaylist> = emptyList(),          // tree order: by parent, then sequence
    val cues: List<OLCue> = emptyList(),
    val deviceName: String = "",
    val dbVersion: Long = 0,
    val integrity: List<String> = emptyList(),              // SQLite's integrity_check ("ok" when fine)
)

class OneLibraryError(message: String) : Exception(message) {
    companion object {
        fun missingTable(t: String) = OneLibraryError("OneLibrary: no $t table (not a OneLibrary database, or a newer layout)")
        fun readBack(s: String) = OneLibraryError("OneLibrary: $s")
        fun cantWrite(s: String) = OneLibraryError("OneLibrary: $s")
    }
}

data class OLTrackEdit(
    val title: String? = null, val artist: String? = null, val album: String? = null, val genre: String? = null,
    val comment: String? = null, val rating: Int? = null, val bpm: Double? = null,
) {
    val isEmpty get() = this == OLTrackEdit()
}

object OneLibrary {
    /** where decrypted copies go while they're read or edited (the app's cache dir on Android) */
    @Volatile var tempDir: File = File(System.getProperty("java.io.tmpdir"))

    class Copy(val db: SQLiteDB, val codec: SQLCipherCodec?, val file: File) {
        fun dispose() { db.close(); file.delete() }
    }

    /** decrypt (or take as is, for a plain test database) and open a temporary copy */
    fun openCopy(data: ByteArray, passphrase: String = SQLCipherCodec.oneLibraryPassphrase): Copy {
        var plain = data; var codec: SQLCipherCodec? = null
        if (!SQLCipherCodec.isPlainSQLite(data)) {
            if (data.size < 16) throw SQLCipherError.tooSmall()
            val c = SQLCipherCodec(passphrase, data.copyOfRange(0, 16))
            plain = c.decrypt(data); codec = c
        }
        val f = File(tempDir, "cratebox-ol-${UUID.randomUUID()}.sqlite")
        f.writeBytes(plain)
        return try { Copy(SQLite.open(f.path), codec, f) } catch (e: Throwable) { f.delete(); throw e }
    }

    fun read(data: ByteArray, passphrase: String = SQLCipherCodec.oneLibraryPassphrase, integrity: Boolean = true): OneLibraryDatabase {
        val c = openCopy(data, passphrase)
        try { return read(c.db, integrity) } finally { c.dispose() }
    }

    private fun names(db: SQLiteDB, table: String, idCol: String, have: Set<String>): Map<Long, String> {
        if (!have.contains(table)) return emptyMap()
        val m = HashMap<Long, String>()
        for (r in db.query("SELECT $idCol AS i, name AS n FROM \"$table\"")) r["i"]?.int?.let { m[it] = r["n"]?.string ?: "" }
        return m
    }

    fun read(db: SQLiteDB, integrity: Boolean = true): OneLibraryDatabase {
        val have = db.tables()
        for (t in listOf("content", "playlist", "playlist_content")) if (!have.contains(t)) throw OneLibraryError.missingTable(t)
        val artists = names(db, "artist", "artist_id", have); val albums = names(db, "album", "album_id", have)
        val genres = names(db, "genre", "genre_id", have); val keys = names(db, "key", "key_id", have)
        val labels = names(db, "label", "label_id", have)
        val cols = db.columns("content")
        fun col(c: String, fallback: String = "NULL") = if (cols.contains(c)) "\"$c\"" else fallback
        val sql = """
        SELECT content_id, ${col("title")} AS title, ${col("artist_id_artist")} AS artist, ${col("album_id")} AS album, ${col("genre_id")} AS genre,
               ${col("label_id")} AS label, ${col("key_id")} AS key, ${col("djComment")} AS comment, ${col("bpmx100")} AS bpm, ${col("length")} AS length,
               ${col("path")} AS path, ${col("fileName")} AS fileName, ${col("fileSize")} AS fileSize, ${col("fileType")} AS fileType,
               ${col("bitrate")} AS bitrate, ${col("bitDepth")} AS bitDepth, ${col("samplingRate")} AS samplingRate,
               ${col("analysisDataFilePath")} AS anlz, ${col("rating")} AS rating, ${col("color_id")} AS color
        FROM content ORDER BY content_id
        """.trimIndent()
        val tracks = db.query(sql).map { r ->
            fun i(k: String) = r[k]?.int
            fun s(k: String) = r[k]?.string ?: ""
            OLTrack(
                id = i("content_id") ?: 0, title = s("title"),
                artist = artists[i("artist") ?: -1] ?: "", album = albums[i("album") ?: -1] ?: "",
                genre = genres[i("genre") ?: -1] ?: "", label = labels[i("label") ?: -1] ?: "",
                key = keys[i("key") ?: -1] ?: "", comment = s("comment"),
                bpm = (i("bpm") ?: 0).toDouble() / 100, durationMs = i("length") ?: 0,
                path = s("path"), fileName = s("fileName"), fileSize = i("fileSize") ?: 0,
                fileType = i("fileType") ?: 0, bitrate = i("bitrate") ?: 0, bitDepth = i("bitDepth") ?: 0,
                sampleRate = i("samplingRate") ?: 0, anlzPath = s("anlz"),
                rating = i("rating") ?: 0, color = i("color") ?: 0)
        }
        val entries = HashMap<Long, MutableList<Pair<Long, Long>>>()
        for (r in db.query("SELECT playlist_id, content_id, sequenceNo FROM playlist_content"))
            entries.getOrPut(r["playlist_id"]?.int ?: 0) { ArrayList() }.add((r["sequenceNo"]?.int ?: 0) to (r["content_id"]?.int ?: 0))
        val playlists = db.query("SELECT playlist_id, sequenceNo, name, attribute, playlist_id_parent FROM playlist").map { r ->
            val id = r["playlist_id"]?.int ?: 0; val attr = r["attribute"]?.int ?: 0
            OLPlaylist(id, r["playlist_id_parent"]?.int ?: 0, r["sequenceNo"]?.int ?: 0, attr == 1L, r["name"]?.string ?: "",
                (entries[id] ?: emptyList()).sortedBy { it.first }.map { it.second }, attr)
        }.sortedWith(compareBy<OLPlaylist> { it.parent }.thenBy { it.seq })
        val cues = ArrayList<OLCue>()
        if (have.contains("cue")) {
            val cc = db.columns("cue")
            val comment = if (cc.contains("cueComment")) "cueComment" else "NULL"; val color = if (cc.contains("colorTableIndex")) "colorTableIndex" else "0"
            for (r in db.query("SELECT cue_id, content_id, kind, inUsec, outUsec, $comment AS cm, $color AS col FROM cue")) {
                val o = r["outUsec"]?.int ?: -1
                cues.add(OLCue(r["cue_id"]?.int ?: 0, r["content_id"]?.int ?: 0, r["kind"]?.int ?: 0,
                    (r["inUsec"]?.int ?: 0).toDouble() / 1000, if (o > 0) o.toDouble() / 1000 else null,
                    r["cm"]?.string ?: "", r["col"]?.int ?: 0))
            }
        }
        var deviceName = ""; var dbVersion = 0L
        if (have.contains("property")) db.query("SELECT * FROM property LIMIT 1").firstOrNull()?.let { p ->
            deviceName = p["deviceName"]?.string ?: ""; dbVersion = p["dbVersion"]?.int ?: 0
        }
        val check = if (integrity) (runCatching { db.integrityCheck() }.getOrNull() ?: listOf("integrity check couldn't run")) else emptyList()
        return OneLibraryDatabase(tracks, playlists, cues, deviceName, dbVersion, check)
    }

    /** Rewrites the playlist and playlist_content tables to `nodes` (in tree order, siblings numbered from 1 in
     *  that order), in one transaction on a decrypted copy, then reads it back and re-encrypts it with the file's
     *  own salt. Returns the new file. Throws (writing nothing) if anything doesn't read back as asked. */
    fun writePlaylists(data: ByteArray, nodes: List<OLPlaylist>, passphrase: String = SQLCipherCodec.oneLibraryPassphrase): ByteArray {
        val c = openCopy(data, passphrase)
        try {
            val db = c.db
            val before = read(db, integrity = false)
            val known = before.tracks.map { it.id }.toSet()
            val ids = HashSet<Long>()
            for (n in nodes) {
                if (n.id <= 0 || ids.contains(n.id)) throw OneLibraryError.cantWrite("bad playlist id ${n.id}")
                ids.add(n.id)
            }
            for (n in nodes) if (n.parent != 0L && !ids.contains(n.parent)) throw OneLibraryError.cantWrite("playlist parent missing")
            for (n in nodes) if (!n.folder) for (t in n.tracks) if (!known.contains(t)) throw OneLibraryError.cantWrite("track $t isn't in this library")
            // keep each existing playlist's image and attribute; new ones get 0 (playlist) / 1 (folder)
            val old = HashMap<Long, OLPlaylist>()
            for (p in before.playlists) old.putIfAbsent(p.id, p)
            val pcols = db.columns("playlist")
            val images = HashMap<Long, SQLValue>()
            if (pcols.contains("image_id")) for (r in db.query("SELECT playlist_id, image_id FROM playlist")) images[r["playlist_id"]?.int ?: 0] = r["image_id"] ?: SQLValue.Null
            val seq = HashMap<Long, Long>()
            db.transaction {
                db.run("DELETE FROM playlist_content")
                db.run("DELETE FROM playlist")
                for (n in nodes) {
                    val s = (seq[n.parent] ?: 0) + 1; seq[n.parent] = s
                    val attr: Long = if (n.folder) 1 else (old[n.id]?.let { if (it.folder) 0 else it.attribute } ?: 0)
                    val parent = if (n.parent == 0L) SQLValue.Null else SQLValue.I(n.parent)
                    if (pcols.contains("image_id"))
                        db.run("INSERT INTO playlist (playlist_id, sequenceNo, name, image_id, attribute, playlist_id_parent) VALUES (?, ?, ?, ?, ?, ?)",
                            listOf(SQLValue.I(n.id), SQLValue.I(s), SQLValue.T(n.name), images[n.id] ?: SQLValue.Null, SQLValue.I(attr), parent))
                    else
                        db.run("INSERT INTO playlist (playlist_id, sequenceNo, name, attribute, playlist_id_parent) VALUES (?, ?, ?, ?, ?)",
                            listOf(SQLValue.I(n.id), SQLValue.I(s), SQLValue.T(n.name), SQLValue.I(attr), parent))
                    if (!n.folder) for ((i, t) in n.tracks.withIndex())
                        db.run("INSERT INTO playlist_content (playlist_id, content_id, sequenceNo) VALUES (?, ?, ?)", listOf(SQLValue.I(n.id), SQLValue.I(t), SQLValue.I(i + 1L)))
                }
            }
            // read back: the playlists as asked, the tracks untouched, SQLite happy
            val after = read(db, integrity = true)
            if (after.integrity != listOf("ok")) throw OneLibraryError.readBack("integrity check: ${after.integrity.take(3).joinToString("; ")}")
            if (after.tracks != before.tracks) throw OneLibraryError.readBack("tracks changed")
            val got = HashMap<Long, OLPlaylist>()
            for (p in after.playlists) got.putIfAbsent(p.id, p)
            if (got.size != nodes.size) throw OneLibraryError.readBack("playlist count didn't read back")
            for (n in nodes) {
                val g = got[n.id]
                if (g == null || g.parent != n.parent || g.folder != n.folder || g.name != n.name || g.tracks != (if (n.folder) emptyList() else n.tracks))
                    throw OneLibraryError.readBack("playlist didn't read back: ${n.name}")
            }
            return seal(c)
        } finally { c.dispose() }
    }

    /** closes the edited copy and gives back the file to write: re-encrypted with the original's salt (a plain
     *  test database stays plain), and checked to decrypt to exactly what was checked */
    internal fun seal(c: Copy): ByteArray {
        c.db.close()
        var plain = c.file.readBytes()
        val codec = c.codec ?: return plain
        // SQLite may have grown the file by whole pages
        val P = SQLCipherCodec.PAGE_SIZE
        if (plain.size % P != 0) plain = plain.copyOf(plain.size + P - plain.size % P)
        val enc = codec.encrypt(plain)
        if (!codec.decrypt(enc).contentEquals(plain)) throw OneLibraryError.readBack("re-encrypted file didn't decrypt back")
        return enc
    }

    // ---- track info and cues (OneLibraryWrite.swift) ----

    /** Writes `edits` (by content_id). Throws, writing nothing, if a track isn't there or anything doesn't read
     *  back as asked. */
    fun writeTracks(data: ByteArray, edits: Map<Long, OLTrackEdit>, passphrase: String = SQLCipherCodec.oneLibraryPassphrase): ByteArray {
        val c = openCopy(data, passphrase)
        try {
            val db = c.db
            val before = read(db, integrity = false)
            val known = before.tracks.map { it.id }.toSet()
            for (id in edits.keys) if (!known.contains(id)) throw OneLibraryError.cantWrite("track $id isn't in this library")
            for ((id, e) in edits) {
                e.rating?.let { if (it < 0 || it > 5) throw OneLibraryError.cantWrite("track $id: rating $it") }
                e.bpm?.let { if (!(it > 0 && it < 10000)) throw OneLibraryError.cantWrite("track $id: BPM $it") }
            }
            val have = db.tables()
            val cols = db.columns("content")
            fun need(col: String) { if (!cols.contains(col)) throw OneLibraryError.cantWrite("content has no $col column") }
            /** the id for a name in artist / album / genre, adding a row when there's none */
            fun nameId(table: String, idCol: String, name: String, extra: Map<String, SQLValue> = emptyMap()): SQLValue {
                if (name.isEmpty()) return SQLValue.Null
                if (!have.contains(table)) throw OneLibraryError.missingTable(table)
                var whereSql = "name = ?"; val args = arrayListOf<SQLValue>(SQLValue.T(name))
                for ((k, v) in extra.entries.sortedBy { it.key }) { whereSql += " AND \"$k\" IS ?"; args.add(v) }
                db.query("SELECT $idCol AS i FROM \"$table\" WHERE $whereSql ORDER BY $idCol LIMIT 1", args).firstOrNull()?.get("i")?.let { return it }
                val tc = db.columns(table)
                val next = db.query("SELECT COALESCE(MAX($idCol), 0) + 1 AS n FROM \"$table\"").firstOrNull()?.get("n")?.int ?: 1
                val names = arrayListOf(idCol, "name"); val vals = arrayListOf<SQLValue>(SQLValue.I(next), SQLValue.T(name))
                if (tc.contains("nameForSearch")) { names.add("nameForSearch"); vals.add(SQLValue.T(name)) }
                for ((k, v) in extra.entries.sortedBy { it.key }) if (tc.contains(k)) { names.add(k); vals.add(v) }
                db.run("INSERT INTO \"$table\" (${names.joinToString(", ") { "\"$it\"" }}) VALUES (${names.joinToString(", ") { "?" }})", vals)
                return SQLValue.I(next)
            }
            db.transaction {
                for ((id, e) in edits.entries.sortedBy { it.key }) {
                    if (e.isEmpty) continue
                    val set = ArrayList<Pair<String, SQLValue>>()
                    e.title?.let { need("title"); set.add("title" to SQLValue.T(it)); if (cols.contains("titleForSearch")) set.add("titleForSearch" to SQLValue.T(it)) }
                    var artist: SQLValue? = null
                    e.artist?.let { need("artist_id_artist"); val v = nameId("artist", "artist_id", it); artist = v; set.add("artist_id_artist" to v) }
                    e.album?.let { al ->
                        need("album_id")
                        val a = artist ?: (db.query("SELECT artist_id_artist AS a FROM content WHERE content_id = ?", listOf(SQLValue.I(id))).firstOrNull()?.get("a") ?: SQLValue.Null)
                        set.add("album_id" to nameId("album", "album_id", al, mapOf("artist_id" to a)))
                    }
                    e.genre?.let { need("genre_id"); set.add("genre_id" to nameId("genre", "genre_id", it)) }
                    e.comment?.let { need("djComment"); set.add("djComment" to SQLValue.T(it)) }
                    e.rating?.let { need("rating"); set.add("rating" to SQLValue.I(it.toLong())) }
                    e.bpm?.let { need("bpmx100"); set.add("bpmx100" to SQLValue.I(Math.round(it * 100))) }
                    db.run("UPDATE content SET ${set.joinToString(", ") { "\"${it.first}\" = ?" }} WHERE content_id = ?", set.map { it.second } + SQLValue.I(id))
                }
            }
            val after = read(db, integrity = true)
            if (after.integrity != listOf("ok")) throw OneLibraryError.readBack("integrity check: ${after.integrity.take(3).joinToString("; ")}")
            if (after.playlists != before.playlists) throw OneLibraryError.readBack("playlists changed")
            if (after.cues != before.cues) throw OneLibraryError.readBack("cues changed")
            val got = HashMap<Long, OLTrack>()
            for (t in after.tracks) got.putIfAbsent(t.id, t)
            if (got.size != before.tracks.size) throw OneLibraryError.readBack("track count changed")
            for (t in before.tracks) {
                var g = got[t.id] ?: throw OneLibraryError.readBack("track ${t.id} went missing")
                val e = edits[t.id]
                if (e != null) {
                    e.title?.let { if (g.title != it) throw OneLibraryError.readBack("title didn't read back: $it") }
                    e.artist?.let { if (g.artist != it) throw OneLibraryError.readBack("artist didn't read back: $it") }
                    e.album?.let { if (g.album != it) throw OneLibraryError.readBack("album didn't read back: $it") }
                    e.genre?.let { if (g.genre != it) throw OneLibraryError.readBack("genre didn't read back: $it") }
                    e.comment?.let { if (g.comment != it) throw OneLibraryError.readBack("comment didn't read back") }
                    e.rating?.let { if (g.rating != it.toLong()) throw OneLibraryError.readBack("rating didn't read back") }
                    e.bpm?.let { if (abs(g.bpm - Math.round(it * 100) / 100.0) > 1e-9) throw OneLibraryError.readBack("BPM didn't read back") }
                    g = g.copy(title = t.title, artist = t.artist, album = t.album, genre = t.genre, comment = t.comment, rating = t.rating, bpm = t.bpm)
                }
                if (g != t) throw OneLibraryError.readBack("track ${t.id} changed in a field that wasn't edited")
            }
            return seal(c)
        } finally { c.dispose() }
    }

    /** Replaces the cue rows of each track in `cues` (by content_id) with the given cues; other tracks' cues stay
     *  as they are. */
    fun writeCues(data: ByteArray, cues: Map<Long, List<ANLZCuePoint>>, passphrase: String = SQLCipherCodec.oneLibraryPassphrase): ByteArray {
        val c = openCopy(data, passphrase)
        try {
            val db = c.db
            val before = read(db, integrity = false)
            if (!db.tables().contains("cue")) throw OneLibraryError.missingTable("cue")
            val known = before.tracks.map { it.id }.toSet()
            for (id in cues.keys) if (!known.contains(id)) throw OneLibraryError.cantWrite("track $id isn't in this library")
            for (list in cues.values) for (q in list)
                if (q.hot < 0 || q.hot > 8 || (q.loopMs?.let { it <= q.ms } ?: false)) throw OneLibraryError.cantWrite("bad cue at ${q.ms} ms")
            val cc = db.columns("cue")
            for (col in listOf("cue_id", "content_id", "kind", "inUsec", "outUsec")) if (!cc.contains(col)) throw OneLibraryError.cantWrite("cue has no $col column")
            db.transaction {
                var next = db.query("SELECT COALESCE(MAX(cue_id), 0) + 1 AS n FROM cue").firstOrNull()?.get("n")?.int ?: 1
                for ((id, list) in cues.entries.sortedBy { it.key }) {
                    db.run("DELETE FROM cue WHERE content_id = ?", listOf(SQLValue.I(id)))
                    for (q in list.sortedWith(compareBy<ANLZCuePoint> { if (it.hot == 0) 1 else 0 }.thenBy { it.hot }.thenBy { it.ms })) {
                        val row = arrayListOf<Pair<String, SQLValue>>("cue_id" to SQLValue.I(next), "content_id" to SQLValue.I(id), "kind" to SQLValue.I(q.hot.toLong()),
                            "inUsec" to SQLValue.I(q.ms * 1000), "outUsec" to SQLValue.I(q.loopMs?.let { it * 1000 } ?: -1))
                        val optional = listOf<Pair<String, SQLValue>>(
                            "colorTableIndex" to SQLValue.I((if (q.hot > 0) q.color?.code ?: 0 else q.colorId ?: 0).toLong()),
                            "cueComment" to SQLValue.T(q.comment), "isActiveLoop" to SQLValue.I(0),
                            "beatLoopNumerator" to SQLValue.I(0), "beatLoopDenominator" to SQLValue.I(0),
                            "in150FramePerSec" to SQLValue.I(Math.round(q.ms * 0.15)),
                            "out150FramePerSec" to SQLValue.I(q.loopMs?.let { Math.round(it * 0.15) } ?: -1),
                        )
                        row += optional.filter { cc.contains(it.first) }
                        db.run("INSERT INTO cue (${row.joinToString(", ") { "\"${it.first}\"" }}) VALUES (${row.joinToString(", ") { "?" }})", row.map { it.second })
                        next += 1
                    }
                }
            }
            val after = read(db, integrity = true)
            if (after.integrity != listOf("ok")) throw OneLibraryError.readBack("integrity check: ${after.integrity.take(3).joinToString("; ")}")
            if (after.tracks != before.tracks) throw OneLibraryError.readBack("tracks changed")
            if (after.playlists != before.playlists) throw OneLibraryError.readBack("playlists changed")
            fun key(q: OLCue) = "${q.track}|${q.kind}|${Math.round(q.inMs)}|${q.outMs?.let { Math.round(it).toString() } ?: "-"}|${q.comment}"
            fun untouched(q: OLCue) = cues[q.track] == null
            if (after.cues.filter(::untouched) != before.cues.filter(::untouched)) throw OneLibraryError.readBack("another track's cues changed")
            val want = cues.flatMap { (id, list) -> list.map { "$id|${it.hot}|${it.ms}|${it.loopMs?.toString() ?: "-"}|${it.comment}" } }.sorted()
            if (after.cues.filter { !untouched(it) }.map(::key).sorted() != want) throw OneLibraryError.readBack("cues didn't read back")
            return seal(c)
        } finally { c.dispose() }
    }
}
