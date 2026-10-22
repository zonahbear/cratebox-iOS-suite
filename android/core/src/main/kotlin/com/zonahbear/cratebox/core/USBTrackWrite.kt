// Cratebox USB: your edits to tracks (cues, beat grid, track info) as writes to a stick. A port of
// USBTrackWrite.swift. `plan` works out every file that changes and builds each new version in memory with the
// writers (which check themselves); nothing touches the stick until `apply`, which writes them one by one
// through USBSafeWrite and puts back the ones already written if a later one fails. Only the kinds
// USBWriteGate allows are planned.
//
//  cues  → the track's ANLZ .DAT and .EXT (PCOB / PCO2), and OneLibrary's cue table
//  grid  → the .DAT and .EXT (PQTZ; PQT2 dropped), and the BPM in both libraries' track rows
//  info  → export.pdb's track rows and OneLibrary's content table
package com.zonahbear.cratebox.core

import java.io.File

data class USBCue(val time: Double, val loopEnd: Double? = null, val comment: String = "")

/** what to change on one track; null = leave it as it is on the stick */
data class USBTrackChanges(
    /** the main cue: the earliest memory cue moves here (or one is added) */
    val cue: Double? = null,
    val hot: List<USBCue?>? = null,          // A-H
    val memory: List<USBCue>? = null,
    val bpm: Double? = null, val firstBeat: Double? = null,
    val title: String? = null, val artist: String? = null, val album: String? = null, val genre: String? = null,
    val comment: String? = null, val rating: Int? = null,
) {
    val hasCues get() = cue != null || hot != null || memory != null
    val hasGrid get() = bpm != null || firstBeat != null
    val hasInfo get() = title != null || artist != null || album != null || genre != null || comment != null || rating != null
    /** the write kinds this change needs */
    val kinds: Set<USBWriteKind> get() {
        val k = LinkedHashSet<USBWriteKind>()
        if (hasCues) k.add(USBWriteKind.CUES)
        if (hasGrid) k.add(USBWriteKind.BEATGRID)
        if (hasInfo) k.add(USBWriteKind.METADATA)
        return k
    }
}

class USBWritePlan {
    /** rel: relative to the stick's root */
    class FileChange(val rel: String, var old: ByteArray, val new: ByteArray)
    var files: MutableList<FileChange> = ArrayList()
    val tracks = ArrayList<String>()           // track keys this plan writes
    val summary = ArrayList<String>()
    val isEmpty get() = files.isEmpty()
}

object USBTrackWriter {
    const val PDB_REL = "PIONEER/rekordbox/export.pdb"; const val OL_REL = "PIONEER/rekordbox/exportLibrary.db"

    internal fun ms(t: Double): Long {
        if (!(t.isFinite() && t >= 0 && t * 1000 < 4294967294.0)) throw ANLZWriteError.badCue("time $t s")
        return Math.round(t * 1000)
    }
    private fun rel(path: String) = path.dropWhile { it == '/' }

    /** Every file `changes` (by track key) needs written, built and checked in memory. Throws USBWriteError
     *  (LOCKED) if a change needs a write the gate doesn't allow, and the writers' own errors if a file can't be
     *  written as asked. `pdbBytes` / `olBytes`: the libraries as `lib` was read from them. */
    fun plan(lib: USBLibrary, fs: StickFS, changes: Map<String, USBTrackChanges>, gate: USBWriteGate,
             pdbBytes: ByteArray?, olBytes: ByteArray?): USBWritePlan {
        val wanted = changes.filter { it.value.kinds.isNotEmpty() }
        val needs = wanted.values.flatMap { it.kinds }.toSet()
        val locked = USBWriteKind.entries.filter { needs.contains(it) && !gate.allowed(it) }
        if (locked.isNotEmpty())
            throw USBWriteError.locked("Not proven on hardware yet, so locked: ${locked.joinToString("; ") { it.title }}. Your edits are kept in Cratebox.")
        val plan = USBWritePlan()
        val pdbEdits = HashMap<Long, PDBTrackEdit>(); val olEdits = HashMap<Long, OLTrackEdit>(); val olCues = HashMap<Long, List<ANLZCuePoint>>()
        class Pair2(val old: ByteArray, var new: ByteArray)
        val files = HashMap<String, Pair2>(); val order = ArrayList<String>()
        fun load(r: String): ByteArray {
            files[r]?.let { return it.new }
            val b = fs.read(r) ?: throw USBWriteError.changedSinceRead("$r (can't be read)")
            files[r] = Pair2(b, b); order.add(r)
            return b
        }

        for ((key, c) in wanted.entries.sortedBy { it.key }) {
            val t = lib.track(key) ?: throw USBWriteError.verifyFailed("$key isn't on this stick")
            plan.tracks.add(key)
            val what = ArrayList<String>()
            val dat = rel(t.anlzPath)
            val ext = (if (dat.substringAfterLast('/').contains('.')) dat.substringBeforeLast('.') else dat) + ".EXT"
            val anlz = listOf(dat) + (if (fs.exists(ext)) listOf(ext) else emptyList())
            if (c.hasCues || c.hasGrid) {
                if (t.anlzPath.isEmpty() || !fs.exists(dat)) throw USBWriteError.verifyFailed("${t.fileName} has no analysis file on the stick: analyse it in rekordbox and export again")
            }
            if (c.hasGrid) {
                val beats = RekordboxANLZ.parse(load(dat)).beats
                val old = RekordboxANLZ.grid(beats)
                val bpm = c.bpm ?: old?.bpm; val first = c.firstBeat ?: old?.firstBeat
                if (bpm == null || first == null) throw ANLZWriteError.badGrid("${t.fileName} has no grid to start from: give it a BPM and first beat")
                val duration = if (t.duration > 0) t.duration else (beats.lastOrNull()?.ms ?: 0) / 1000.0 + 60 / bpm
                val grid = RekordboxANLZ.constantGrid(bpm, first, duration)
                for (f in anlz) { val b = RekordboxANLZ.writeGrid(load(f), grid); files[f]!!.new = b }
                val rounded = grid[0].bpm
                t.pdbId?.let { pdbEdits[it] = (pdbEdits[it] ?: PDBTrackEdit()).copy(bpm = rounded) }
                if (lib.hasOneLibrary) t.olId?.let { olEdits[it] = (olEdits[it] ?: OLTrackEdit()).copy(bpm = rounded) }
                what.add(fmt("grid %.2f BPM from %.3f s", rounded, first))
            }
            if (c.hasCues) {
                // start from what's on the stick (the .EXT has the comments and colours), then apply the edit
                val src = if (anlz.size > 1) load(ext) else load(dat)
                val existing = RekordboxANLZ.cuePoints(src)
                var hot = existing.filter { it.hot > 0 }
                var memory = existing.filter { it.hot == 0 }.sortedBy { it.ms }.toMutableList()
                c.hot?.let { h ->
                    val list = ArrayList<ANLZCuePoint>()
                    for ((i, q) in h.take(8).withIndex()) {
                        if (q == null) continue
                        list.add(ANLZCuePoint(i + 1, ms(q.time), q.loopEnd?.let(::ms), q.comment, color = hot.firstOrNull { it.hot == i + 1 }?.color))
                    }
                    hot = list
                }
                c.memory?.let { m ->
                    val prev = memory
                    memory = m.map { q ->
                        val at = ms(q.time)
                        ANLZCuePoint(0, at, q.loopEnd?.let(::ms), q.comment, colorId = prev.firstOrNull { it.ms == at }?.colorId)
                    }.toMutableList()
                }
                c.cue?.let { cue ->
                    val at = ms(cue)
                    if (!memory.any { it.loopMs == null && it.ms == at }) {
                        val i = memory.indices.filter { memory[it].loopMs == null }.minByOrNull { memory[it].ms }
                        if (c.memory == null && i != null) memory[i] = memory[i].copy(ms = at)
                        else memory.add(ANLZCuePoint(0, at))
                    }
                }
                val all = hot + memory
                for (f in anlz) { val b = RekordboxANLZ.writeCues(load(f), all); files[f]!!.new = b }
                if (lib.hasOneLibrary) t.olId?.let { olCues[it] = all }
                what.add("${hot.size} hot cues, ${memory.size} memory cues")
            }
            if (c.hasInfo) {
                t.pdbId?.let { id ->
                    pdbEdits[id] = (pdbEdits[id] ?: PDBTrackEdit()).copy(title = c.title, artist = c.artist, album = c.album, genre = c.genre, comment = c.comment, rating = c.rating)
                }
                if (lib.hasOneLibrary) t.olId?.let { id ->
                    olEdits[id] = (olEdits[id] ?: OLTrackEdit()).copy(title = c.title, artist = c.artist, album = c.album, genre = c.genre, comment = c.comment, rating = c.rating)
                }
                what.add("track info")
            }
            plan.summary.add("${t.title}: " + what.joinToString(", "))
        }
        if (pdbEdits.isNotEmpty()) {
            val cur = pdbBytes ?: throw USBWriteError.verifyFailed("the Device Library wasn't read")
            files[PDB_REL] = Pair2(cur, PDB.writeTracks(cur, pdbEdits)); order.add(PDB_REL)
        }
        if (olEdits.isNotEmpty() || olCues.isNotEmpty()) {
            val cur = olBytes ?: throw USBWriteError.verifyFailed("OneLibrary wasn't read")
            var b = cur
            if (olEdits.isNotEmpty()) b = OneLibrary.writeTracks(b, olEdits)
            if (olCues.isNotEmpty()) b = OneLibrary.writeCues(b, olCues)
            files[OL_REL] = Pair2(cur, b); order.add(OL_REL)
        }
        plan.files = order.mapNotNull { r -> files[r]?.let { if (it.old.contentEquals(it.new)) null else USBWritePlan.FileChange(r, it.old, it.new) } }.toMutableList()
        return plan
    }

    /** Writes a plan's files, each through USBSafeWrite (backed up, staged, checked, swapped). If one fails, the
     *  ones already written are put back and the error is thrown. Returns the backups made (paths on the stick). */
    fun apply(plan: USBWritePlan, fs: StickFS, appBackupDir: File?): List<String> {
        val done = ArrayList<USBWritePlan.FileChange>(); val backups = ArrayList<String>()
        try {
            for (f in plan.files) {
                val b = USBSafeWrite.write(f.new, fs, f.rel, USBSafeWrite.hash(f.old), appBackupDir) { staged -> check(f.rel, staged) }
                backups.add(b); done.add(f)
            }
        } catch (error: Exception) {
            val undo = ArrayList<String>()
            for (f in done.reversed()) {
                try { USBSafeWrite.write(f.old, fs, f.rel, USBSafeWrite.hash(f.new), null) { } }
                catch (e: Exception) { undo.add("${f.rel.substringAfterLast('/')} (${e.message})") }
            }
            if (done.isEmpty()) throw error
            if (undo.isEmpty()) throw USBWriteError.verifyFailed("${error.message}. The files already written were put back as they were.")
            throw USBWriteError.swapFailed("${error.message}. Putting back failed for ${undo.joinToString(", ")}: restore from the backups in Cratebox USB")
        }
        return backups
    }

    /** the check each staged file gets, as read back from the stick: parsed the way a player would */
    internal fun check(rel: String, b: ByteArray) {
        when (rel) {
            PDB_REL -> { val p = PDB.problems(b); if (p.isNotEmpty()) throw PDBError.readBack(p[0]) }
            OL_REL -> { val o = OneLibrary.read(b); if (o.integrity != listOf("ok")) throw OneLibraryError.readBack("integrity") }
            else -> RekordboxANLZ.split(b)
        }
    }
}
