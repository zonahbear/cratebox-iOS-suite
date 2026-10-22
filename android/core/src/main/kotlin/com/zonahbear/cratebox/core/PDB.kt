// rekordbox USB/SD exports: export.pdb, read and (playlists only) written. A port of PDB.swift, which ports
// tools/rekordbox.js (RB.parsePdb, RB.writePlaylists); the layout follows Deep Symmetry's crate-digger
// (rekordbox_pdb.ksy). The writer must give byte-for-byte the same file as the JS one (tests compare against
// files the JS writer made). UInt32 fields are Longs here.
package com.zonahbear.cratebox.core

import kotlin.math.max
import kotlin.math.min

class PDBError(message: String) : Exception(message) {
    companion object {
        fun notPDB() = PDBError("not an export.pdb")
        fun brokenChain(t: Long) = PDBError("export.pdb: broken page chain in table $t")
        fun noTable(t: Long) = PDBError("export.pdb has no table $t")
        fun noDataPages(t: Long) = PDBError("export.pdb: table $t has no data pages")
        fun noFreePage(t: Long) = PDBError("export.pdb: no free page for table $t")
        fun badId(i: Long) = PDBError("bad playlist id $i")
        fun missingParent() = PDBError("playlist parent missing")
        fun rowTooBig() = PDBError("row too big")
        fun readBack(s: String) = PDBError("export.pdb: $s")
    }
}

data class PDBTrack(
    val id: Long,
    val title: String, val artist: String, val album: String, val genre: String, val label: String, val key: String,
    val bpm: Double, val duration: Int, val size: Long, val sampleRate: Long, val rating: Int, val color: Int,
    val path: String, val filename: String, val anlzPath: String, val comment: String, val dateAdded: String,
)

data class PDBPlaylist(
    val id: Long, val parent: Long = 0, val unk: Long = 0, val sort: Long = 0,
    val folder: Boolean = false, val name: String, val tracks: List<Long> = emptyList(),
)

data class PDBDatabase(val tracks: List<PDBTrack>, val playlists: List<PDBPlaylist>)

enum class PDBPage(val raw: Long, val label: String) {
    TRACKS(0, "tracks"), GENRES(1, "genres"), ARTISTS(2, "artists"), ALBUMS(3, "albums"), LABELS(4, "labels"),
    KEYS(5, "keys"), COLORS(6, "colors"), PLAYLIST_TREE(7, "playlistTree"), PLAYLIST_ENTRIES(8, "playlistEntries"),
}

/** little-endian reads of a file's bytes */
class Bytes(val b: ByteArray) {
    val count get() = b.size
    fun u8(o: Int): Int = b[o].toInt() and 0xff
    fun u16(o: Int): Int = u8(o) or (u8(o + 1) shl 8)
    fun u32(o: Int): Long = (u8(o).toLong()) or (u8(o + 1).toLong() shl 8) or (u8(o + 2).toLong() shl 16) or (u8(o + 3).toLong() shl 24)
}

object PDB {
    // ---- strings ----
    private fun latin1(b: ByteArray, from: Int, to: Int): String {
        val sb = StringBuilder()
        for (i in from until to) sb.append((b[i].toInt() and 0xff).toChar())
        return sb.toString()
    }

    fun string(d: Bytes, pos: Int): String {
        if (pos >= d.count) return ""
        val lk = d.u8(pos)
        if (lk == 0x40 || lk == 0x90) {
            val len = d.u16(pos + 1)
            val n = max(0, len - 4)
            val from = min(d.count, pos + 4)
            val to = min(d.count, pos + 4 + n)
            var out = if (lk == 0x40) latin1(d.b, from, to) else {
                val sb = StringBuilder()
                var i = from
                while (i + 1 < to) { sb.append((d.u8(i) or (d.u8(i + 1) shl 8)).toChar()); i += 2 }
                sb.toString()
            }
            while (out.endsWith("\u0000")) out = out.dropLast(1)
            return out
        }
        val n = (lk shr 1) - 1
        if (n <= 0) return ""
        return latin1(d.b, min(d.count, pos + 1), min(d.count, pos + 1 + n))
    }

    /** A DeviceSQL string: short ASCII (up to 126 chars), long ASCII (0x40) or long UTF-16LE (0x90). */
    fun stringBytes(s: String): ByteArray {
        val units = s.toCharArray()
        val ascii = units.all { it.code < 0x80 }
        if (ascii && units.size <= 126) {
            val b = ByteArray(1 + units.size)
            b[0] = (((units.size + 1) shl 1) or 1).toByte()
            for ((i, c) in units.withIndex()) b[1 + i] = c.code.toByte()
            return b
        }
        val n = if (ascii) units.size else units.size * 2
        val b = ByteArray(4 + n)
        b[0] = (if (ascii) 0x40 else 0x90).toByte()
        b[1] = ((n + 4) and 0xff).toByte(); b[2] = (((n + 4) shr 8) and 0xff).toByte(); b[3] = 0
        for ((i, c) in units.withIndex()) {
            if (ascii) b[4 + i] = c.code.toByte()
            else { b[4 + 2 * i] = (c.code and 0xff).toByte(); b[5 + 2 * i] = (c.code shr 8).toByte() }
        }
        return b
    }

    // ---- rows ----
    /** Every present row of one table: calls fn(rowOffsetInFile). */
    internal fun rows(d: Bytes, type: Long, fn: (Int) -> Unit) {
        if (d.count < 28) return
        val lenPage = d.u32(4).toInt(); val numTables = d.u32(8).toInt()
        if (lenPage <= 0) return
        for (t in 0 until numTables) {
            val tp = 28 + t * 16
            if (tp + 16 > d.count || d.u32(tp) != type) continue
            var page = d.u32(tp + 8)
            val last = d.u32(tp + 12)
            val seen = HashSet<Long>()
            while (!seen.contains(page) && (page + 1) * lenPage <= d.count) {
                seen.add(page)
                val p = (page * lenPage).toInt()
                if (d.u32(p + 8) != type) break
                val packed = d.u8(p + 24) or (d.u8(p + 25) shl 8) or (d.u8(p + 26) shl 16)
                val numOffsets = packed and 0x1fff; val flags = d.u8(p + 27)
                if (flags and 0x40 == 0 && numOffsets > 0) {
                    val groups = (numOffsets - 1) / 16 + 1
                    for (g in 0 until groups) {
                        val base = p + lenPage - g * 0x24
                        val present = d.u16(base - 4)
                        var r = 0
                        while (r < 16 && g * 16 + r < numOffsets) {
                            if ((present shr r) and 1 == 1) {
                                val ofs = d.u16(base - (6 + 2 * r))
                                val at = p + 40 + ofs
                                if (at < d.count) fn(at)
                            }
                            r += 1
                        }
                    }
                }
                if (page == last) break
                page = d.u32(p + 12)
            }
        }
    }

    fun parse(data: ByteArray): PDBDatabase {
        val d = Bytes(data)
        fun named(type: PDBPage, idAt: Int, name: (Int) -> String): Map<Long, String> {
            val m = HashMap<Long, String>()
            rows(d, type.raw) { o -> if (o + idAt + 4 <= d.count) m[d.u32(o + idAt)] = name(o) }
            return m
        }
        fun nearFar(nearAt: Int, farAt: Int): (Int) -> String = { o ->
            val sub = d.u16(o)
            string(d, o + if (sub and 0x04 != 0) d.u16(o + farAt) else d.u8(o + nearAt))
        }
        val artists = named(PDBPage.ARTISTS, 4, nearFar(9, 0x0a))
        val albums = named(PDBPage.ALBUMS, 12, nearFar(21, 0x16))
        val genres = named(PDBPage.GENRES, 0) { string(d, it + 4) }
        val keys = named(PDBPage.KEYS, 0) { string(d, it + 8) }
        val labels = named(PDBPage.LABELS, 0) { string(d, it + 4) }
        val tracks = ArrayList<PDBTrack>()
        rows(d, PDBPage.TRACKS.raw) { o ->
            if (o + 94 + 2 * 21 > d.count) return@rows
            fun str(k: Int) = string(d, o + d.u16(o + 94 + 2 * k))
            tracks.add(PDBTrack(
                id = d.u32(o + 72), title = str(17), artist = artists[d.u32(o + 68)] ?: "", album = albums[d.u32(o + 64)] ?: "",
                genre = genres[d.u32(o + 60)] ?: "", label = labels[d.u32(o + 40)] ?: "", key = keys[d.u32(o + 32)] ?: "",
                bpm = d.u32(o + 56).toDouble() / 100, duration = d.u16(o + 84), size = d.u32(o + 16), sampleRate = d.u32(o + 8),
                rating = d.u8(o + 89), color = d.u8(o + 88),
                path = str(20), filename = str(19), anlzPath = str(14), comment = str(16), dateAdded = str(10)))
        }
        var tree = ArrayList<PDBPlaylist>()
        rows(d, PDBPage.PLAYLIST_TREE.raw) { o ->
            if (o + 21 > d.count) return@rows
            tree.add(PDBPlaylist(id = d.u32(o + 12), parent = d.u32(o), unk = d.u32(o + 4), sort = d.u32(o + 8),
                folder = d.u32(o + 16) != 0L, name = string(d, o + 20)))
        }
        val byList = HashMap<Long, MutableList<Pair<Long, Long>>>()
        rows(d, PDBPage.PLAYLIST_ENTRIES.raw) { o ->
            if (o + 12 > d.count) return@rows
            byList.getOrPut(d.u32(o + 8)) { ArrayList() }.add(d.u32(o) to d.u32(o + 4))
        }
        for (i in tree.indices) {
            if (tree[i].folder) continue
            // stable sort by entry index, like the JS Array.sort
            tree[i] = tree[i].copy(tracks = (byList[tree[i].id] ?: emptyList()).sortedBy { it.first }.map { it.second })
        }
        tree = ArrayList(tree.sortedWith(compareBy<PDBPlaylist> { it.parent }.thenBy { it.sort }))
        return PDBDatabase(tracks, tree)
    }

    internal fun le32(v: Long): ByteArray = byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), ((v shr 16) and 0xff).toByte(), ((v shr 24) and 0xff).toByte())

    // ---- writing ----
    /** Rewrites the playlist tree and playlist entry tables (see RB.writePlaylists in tools/rekordbox.js).
     *  nodes in the order they should show; siblings are numbered in that order. */
    fun writePlaylists(input: ByteArray, nodes: List<PDBPlaylist>): ByteArray {
        if (input.size < 28) throw PDBError.notPDB()
        val src = Bytes(input)
        val PS = src.u32(4); val NT = src.u32(8)
        if (PS < 512 || PS > 65536 || NT < 9 || NT > 64) throw PDBError.notPDB()
        val ids = HashSet<Long>()
        for (n in nodes) {
            if (n.id == 0L || ids.contains(n.id)) throw PDBError.badId(n.id)
            ids.add(n.id)
        }
        for (n in nodes) if (n.parent != 0L && !ids.contains(n.parent)) throw PDBError.missingParent()
        val sortOf = HashMap<Long, Long>(); val seenParent = HashMap<Long, Long>()
        for (n in nodes) { val c = seenParent[n.parent] ?: 0; sortOf[n.id] = c; seenParent[n.parent] = c + 1 }
        val treeRows = nodes.map { n ->
            le32(n.parent) + le32(n.unk) + le32(sortOf[n.id]!!) + le32(n.id) + le32(if (n.folder) 1 else 0) + stringBytes(n.name)
        }
        val entryRows = ArrayList<ByteArray>()
        for (n in nodes) if (!n.folder) for ((i, tid) in n.tracks.withIndex()) entryRows.add(le32(i + 1L) + le32(tid) + le32(n.id))
        var out = input.copyOf()
        out = pack(out, PDBPage.PLAYLIST_TREE.raw, treeRows)
        out = pack(out, PDBPage.PLAYLIST_ENTRIES.raw, entryRows)
        // read it back: the playlists must come out as asked and the tracks as they were
        val before = parse(input); val after = parse(out)
        val got = LinkedHashMap<Long, PDBPlaylist>()
        for (p in after.playlists) got.putIfAbsent(p.id, p)
        for (n in nodes) {
            val g = got[n.id]
            if (g == null || g.parent != n.parent || g.folder != n.folder || g.name != n.name || g.tracks != (if (n.folder) emptyList() else n.tracks))
                throw PDBError.readBack("playlist didn't read back: ${n.name}")
        }
        if (after.playlists.size != nodes.size) throw PDBError.readBack("playlist count didn't read back")
        if (after.tracks != before.tracks) throw PDBError.readBack("tracks changed")
        return out
    }

    /** Rewrites every data page of one table with `rows` (in order), allocating pages from the table's
     *  empty-page candidate when they don't fit; returns the file (longer when it grew). keepFlags: keep each
     *  page's flags byte (else 0x24, as the web app's playlist writer does); indexShift: set each row's
     *  index_shift (bytes 2-3) to 0x20 × its slot, as rekordbox numbers track, artist and album rows. */
    internal fun pack(input: ByteArray, type: Long, rows: List<ByteArray>, keepFlags: Boolean = false, indexShift: Boolean = false): ByteArray {
        var out = input
        val PS = Bytes(out).u32(4).toInt(); val NT = Bytes(out).u32(8).toInt()
        val HEAP = 0x28
        fun r32(o: Int): Long = Bytes(out).u32(o)
        fun w32(o: Int, v: Long) { val b = le32(v); for (i in 0..3) out[o + i] = b[i] }
        fun r16(o: Int): Int = Bytes(out).u16(o)
        fun w16(o: Int, v: Int) { out[o] = (v and 0xff).toByte(); out[o + 1] = ((v shr 8) and 0xff).toByte() }
        fun grow(pages: Int) { if (pages * PS > out.size) out = out.copyOf(pages * PS) }
        fun seq(): Long { val s = r32(20); w32(20, (s + 1) and 0xffffffffL); return s }
        var tp = -1
        for (t in 0 until NT) if (r32(28 + t * 16) == type) tp = 28 + t * 16
        if (tp < 0) throw PDBError.noTable(type)
        val pages = ArrayList<Int>(); val seen = HashSet<Int>()
        var page = r32(tp + 8).toInt()
        val last = r32(tp + 12).toInt()
        while (true) {
            if (seen.contains(page) || page < 0 || (page.toLong() + 1) * PS > out.size || r32(page * PS + 8) != type) throw PDBError.brokenChain(type)
            seen.add(page)
            if (out[page * PS + 27].toInt() and 0x40 == 0) pages.add(page)
            if (page == last) break
            page = r32(page * PS + 12).toInt()
        }
        // an empty table (only its header page) gets its first data page from the empty-page candidate below
        // (the track info writer's tables; the playlist writer keeps the web app's behaviour and refuses)
        if (pages.isEmpty() && !keepFlags) throw PDBError.noDataPages(type)
        if (pages.isEmpty() && rows.isEmpty()) return out
        val chainLast = page
        val flagsOf = LinkedHashMap<Int, Int>()
        for (pg in pages) flagsOf[pg] = out[pg * PS + 27].toInt() and 0xff
        fun idxSize(m: Int) = (m / 16) * 36 + (if (m % 16 != 0) 4 + 2 * (m % 16) else 0)
        fun fits(used: Int, n: Int, len: Int) = HEAP + used + ((len + 3) and 3.inv()) + idxSize(n + 1) <= PS
        val plan = arrayListOf(ArrayList<ByteArray>())
        var used = 0
        for (r in rows) {
            if (r.size + HEAP + 6 > PS) throw PDBError.rowTooBig()
            if (!fits(used, plan.last().size, r.size)) { plan.add(ArrayList()); used = 0 }
            plan.last().add(r); used += (r.size + 3) and 3.inv()
        }
        while (plan.size > pages.size) {
            val cand = r32(tp + 4).toInt(); val nextU = r32(12)
            if (seen.contains(cand) || cand <= 0 || cand.toLong() >= nextU) throw PDBError.noFreePage(type)
            grow(cand + 1)
            val prev = pages.lastOrNull() ?: chainLast
            w32(prev * PS + 12, cand.toLong())
            for (i in (cand * PS) until ((cand + 1) * PS)) out[i] = 0
            w32(cand * PS + 4, cand.toLong()); w32(cand * PS + 8, type); w32(cand * PS + 12, nextU)
            w32(tp + 4, nextU); w32(tp + 12, cand.toLong()); w32(12, nextU + 1)
            pages.add(cand); seen.add(cand)
        }
        for ((k, pg) in pages.withIndex()) {
            val o = pg * PS
            val list = if (k < plan.size) plan[k] else emptyList()
            val n = list.size
            for (i in (o + 0x10) until (o + PS)) out[i] = 0
            w32(o + 0x10, seq())
            val packed = n or (n shl 13)
            out[o + 0x18] = (packed and 0xff).toByte(); out[o + 0x19] = ((packed shr 8) and 0xff).toByte(); out[o + 0x1a] = ((packed shr 16) and 0xff).toByte()
            out[o + 0x1b] = (if (keepFlags) flagsOf[pg] ?: flagsOf.values.firstOrNull() ?: 0x24 else 0x24).toByte()
            var at = 0
            for ((i, r) in list.withIndex()) {
                r.copyInto(out, o + HEAP + at)
                if (indexShift) w16(o + HEAP + at + 2, i * 0x20)
                val g = i / 16; val j = i % 16; val base = o + PS - g * 36
                w16(base - 6 - 2 * j, at)
                val bit = r16(base - 4) or (1 shl j)
                w16(base - 4, bit); w16(base - 2, bit)
                at += (r.size + 3) and 3.inv()
            }
            w16(o + 0x1c, PS - HEAP - at - idxSize(n)); w16(o + 0x1e, at)
            w16(o + 0x20, if (n > 0) n else 0x1fff); w16(o + 0x22, if (n > 0) 0 else 0x1fff)
        }
        return out
    }

    // ---- checks (PDBCheck.swift) ----
    data class TrackFormat(val bitrate: Int, val bitDepth: Int, val sampleRate: Int)

    /** per track id: bit rate (kbps), bit depth and sample rate as rekordbox stored them */
    fun trackFormats(data: ByteArray): Map<Long, TrackFormat> {
        val d = Bytes(data)
        val out = HashMap<Long, TrackFormat>()
        rows(d, PDBPage.TRACKS.raw) { o ->
            if (o + 94 > d.count) return@rows
            out[d.u32(o + 72)] = TrackFormat(d.u32(o + 48).toInt(), d.u16(o + 82), d.u32(o + 8).toInt())
        }
        return out
    }

    /** What's structurally wrong with an export.pdb (empty when nothing is): the header, every table's page
     *  chain (in the file, the right type, no loops, ending at its last page) and every row's position, and
     *  each track row's strings. */
    fun problems(data: ByteArray): List<String> {
        val out = ArrayList<String>()
        val d = Bytes(data)
        if (d.count < 28) return listOf("export.pdb is too short to be a rekordbox database (${d.count} bytes)")
        val PSl = d.u32(4); val NTl = d.u32(8)
        if (PSl < 512 || PSl > 65536 || (PSl and (PSl - 1)) != 0L) return listOf("export.pdb has an impossible page size ($PSl)")
        if (NTl < 1 || NTl > 64 || 28 + NTl * 16 > d.count) return listOf("export.pdb has an impossible table count ($NTl)")
        val PS = PSl.toInt(); val NT = NTl.toInt()
        if (d.count % PS != 0) out.add("export.pdb isn't a whole number of pages (${d.count} bytes, pages of $PS): it may have been cut short")
        val pages = (d.count / PS).toLong()
        val types = HashSet<Long>()
        for (t in 0 until NT) {
            val tp = 28 + t * 16
            val type = d.u32(tp); val first = d.u32(tp + 8); val last = d.u32(tp + 12)
            types.add(type)
            var page = first; val seen = HashSet<Long>(); var steps = 0L
            while (true) {
                if (page >= pages) { out.add("table $type: its page chain points past the end of the file (page $page)"); break }
                if (seen.contains(page)) { out.add("table $type: its page chain loops back on itself at page $page"); break }
                seen.add(page)
                val p = (page * PS).toInt()
                if (d.u32(p + 8) != type) { out.add("table $type: page $page belongs to table ${d.u32(p + 8)}"); break }
                val packed = d.u8(p + 24) or (d.u8(p + 25) shl 8) or (d.u8(p + 26) shl 16)
                val numOffsets = packed and 0x1fff; val flags = d.u8(p + 27)
                if (flags and 0x40 == 0 && numOffsets > 0 && numOffsets != 0x1fff) {
                    val groups = (numOffsets - 1) / 16 + 1
                    if (groups * 0x24 > PS - 40) out.add("table $type: page $page claims more rows than fit")
                    else {
                        for (g in 0 until groups) {
                            val base = p + PS - g * 0x24
                            val present = d.u16(base - 4)
                            for (r in 0 until 16) {
                                if (!(g * 16 + r < numOffsets && (present shr r) and 1 == 1)) continue
                                val ofs = d.u16(base - (6 + 2 * r))
                                if (40 + ofs >= PS - groups * 0x24) { out.add("table $type: a row on page $page starts outside the page's data"); break }
                            }
                        }
                    }
                }
                if (page == last) break
                page = d.u32(p + 12); steps += 1
                if (steps > pages) { out.add("table $type: page chain never reaches its last page"); break }
            }
        }
        for (need in listOf(PDBPage.TRACKS, PDBPage.ARTISTS, PDBPage.PLAYLIST_TREE, PDBPage.PLAYLIST_ENTRIES))
            if (!types.contains(need.raw)) out.add("export.pdb has no ${need.label} table")
        // every track row's strings inside the file, and its path present
        rows(d, PDBPage.TRACKS.raw) { o ->
            if (o + 94 + 2 * 21 > d.count) { out.add("a track row is cut off at the end of its page"); return@rows }
            for (k in listOf(14, 17, 19, 20)) {
                val at = o + d.u16(o + 94 + 2 * k)
                if (at >= d.count) { out.add("track ${d.u32(o + 72)}: a text field points outside the file"); return@rows }
            }
            if (string(d, o + d.u16(o + 94 + 2 * 20)).isEmpty()) out.add("track ${d.u32(o + 72)} has no file path")
        }
        return out
    }
}
