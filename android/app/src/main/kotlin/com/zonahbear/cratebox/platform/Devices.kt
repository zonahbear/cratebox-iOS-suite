// rekordbox USB sticks and SD cards (Devices.swift on iOS): picked with the system folder picker (the drive itself,
// the folder holding PIONEER). Their tracks join the library, their playlist tree shows under DEVICES, and a track
// loaded from one gets rekordbox's own grid, phrases and cues. Playlist editing is opt-in (Settings); on Android
// the save goes through USBSafeWrite (backup on the stick and in the app, staged, checked, journalled), and is
// refused if rekordbox wrote the stick since it was opened.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.zonahbear.cratebox.core.MusicFolder
import com.zonahbear.cratebox.core.PDB
import com.zonahbear.cratebox.core.PDBPlaylist
import com.zonahbear.cratebox.core.PDBTree
import com.zonahbear.cratebox.core.RekordboxANLZ
import com.zonahbear.cratebox.core.CueSet
import com.zonahbear.cratebox.core.TrackRecord
import com.zonahbear.cratebox.core.USBSafeWrite
import java.io.File
import java.util.concurrent.Executors

class Device(val id: String, var name: String, val fs: SafStickFS, var tree: List<PDBPlaylist>, var stamp: String) {
    val byRbId = HashMap<Long, LibTrack>()
    var oneLibrary = false
    var saving = false
    var unsaved = false
    var told = false
}

class Devices(context: Context, private val library: Library) {
    companion object { const val PDB_REL = "PIONEER/rekordbox/export.pdb" }
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "cratebox-devices") }

    val list = ArrayList<Device>()
    var status: (String, Double) -> Unit = { _, _ -> }
    var onChange: () -> Unit = {}
    /** is a deck playing (or holding) one of these tracks? */
    var inUse: (Device) -> Boolean = { false }
    var editable: Boolean
        get() = prefs.getBoolean("cb.rbEdit", false)
        set(v) { prefs.edit().putBoolean("cb.rbEdit", v).apply(); onChange() }

    init { library.devices = this }

    fun restore() {
        for (f in library.folders.filter { it.device }) library.fs(f)?.let { mount(it, f) }
        // sticks added as plain music folders: open them as rekordbox devices now
        for (f in library.folders.filter { !it.device }) {
            val s = library.fs(f) ?: continue
            if (s.exists(PDB_REL)) { library.removeFolder(f); open(Uri.parse(f.uri)) }
        }
    }

    fun open(tree: Uri) {
        val f = library.addFolder(tree, device = true) ?: return
        library.fs(f)?.let { mount(it, f) }
    }

    fun mount(fs: SafStickFS, folder: MusicFolder) {
        val bytes = fs.read(PDB_REL) ?: run {
            status("\"${fs.displayName()}\" doesn't look like a rekordbox USB/SD export (no PIONEER/rekordbox/export.pdb). Pick the drive itself.", 9.0)
            return
        }
        val db = PDB.parse(bytes)
        val id = folder.id
        list.removeAll { it.id == id }
        val dev = Device(id, prefs.getString("cb.devName.$id", null) ?: fs.displayName(), fs, db.playlists, PDBTree.stamp(bytes))
        dev.oneLibrary = fs.exists("PIONEER/rekordbox/exportLibrary.db")
        val tracks = ArrayList<LibTrack>()
        for (r in db.tracks) {
            val tid = "$id|${r.path}"
            val rec = library.track(tid)?.rec ?: TrackRecord(tid, id, r.path, r.title.ifEmpty { r.filename }, r.artist, r.size, 0.0,
                bpm = if (r.bpm > 0) r.bpm else null, key = RekordboxANLZ.keyIndex(r.key), duration = r.duration.toDouble())
            val t = LibTrack(rec)
            t.device = id; t.rb = r
            t.info.keyFromRekordbox = t.info.key >= 0
            dev.byRbId[r.id] = t
            tracks.add(t)
        }
        library.setDeviceTracks(id, tracks)
        list.add(dev)
        status("${dev.name}: ${db.tracks.size} tracks, ${db.playlists.count { !it.folder }} playlists", 4.0)
        onChange()
    }

    /** a name for the stick in Cratebox only (the drive's own label is left alone) */
    fun nickname(d: Device, n: String) {
        val t = n.trim()
        if (t.isEmpty()) { prefs.edit().remove("cb.devName.${d.id}").apply(); d.name = d.fs.displayName() }
        else { prefs.edit().putString("cb.devName.${d.id}", t).apply(); d.name = t }
        onChange()
    }

    /** Eject: finish any playlist save, then let go of the stick. Android's own "Eject" (in the notification or
     *  Settings → Storage) still unmounts it; Cratebox's writes are already synced to the stick when they return. */
    fun eject(d: Device) {
        if (inUse(d)) { status("A deck is playing from ${d.name}: load something else (or stop and unload) first", 7.0); return }
        if (d.unsaved && !d.saving) write(d)
        if (d.saving || d.unsaved) {
            status("Finishing the save to ${d.name}…", 3.0)
            var tries = 0
            fun again() {
                tries++
                if (!d.saving && !d.unsaved) eject(d)
                else if (tries > 40 || (!d.saving && d.unsaved)) status("Couldn't finish saving to ${d.name}. Not ejected: it's not safe to unplug yet.", 10.0)
                else main.postDelayed(::again, 250)
            }
            main.postDelayed(::again, 250)
            return
        }
        forget(d)
        status("${d.name} let go: eject it from Android's notification, then unplug. (Add it again with + USB.)", 8.0)
    }
    fun close(d: Device) {
        if (inUse(d)) { status("Load something else on the decks first", 4.0); return }
        if (d.saving || d.unsaved) { status(if (d.saving) "Saving to ${d.name}, one moment" else "${d.name} has playlist changes that aren't saved", 7.0); return }
        forget(d)
    }
    private fun forget(d: Device) {
        list.remove(d)
        library.setDeviceTracks(d.id, emptyList())
        library.folders.firstOrNull { it.id == d.id }?.let(library::removeFolder)
        onChange()
    }

    fun device(t: LibTrack) = list.firstOrNull { it.id == t.device }
    fun uri(t: LibTrack): Uri? { val d = device(t) ?: return null; val r = t.rb ?: return null; return d.fs.documentUri(r.path.trimStart('/')) }

    /** rekordbox's own analysis for a stick track: grid, phrases, hot cues and the first memory cue */
    fun readAnalysis(t: LibTrack) {
        val d = device(t) ?: return
        val r = t.rb ?: return
        if (r.anlzPath.isEmpty()) return
        val datRel = r.anlzPath.trimStart('/')
        val dat = d.fs.read(datRel) ?: return
        val a = RekordboxANLZ.parse(dat)
        val g = RekordboxANLZ.grid(a.beats) ?: return
        val extRel = (if (datRel.substringAfterLast('/').contains('.')) datRel.substringBeforeLast('.') else datRel) + ".EXT"
        val ext = RekordboxANLZ.parse(d.fs.read(extRel) ?: ByteArray(0)).copy(beats = a.beats)
        if (!t.info.gridManual) { t.info.bpm = g.bpm; t.info.firstBeat = g.firstBeat; t.info.autoBpm = g.bpm; t.info.autoFirst = g.firstBeat }
        t.info.rbGrid = true
        // beat by beat only when rekordbox's grid actually changes tempo: an even grid is exact as BPM + first beat
        if (a.beats.map { it.bpm }.toSet().size > 1) {
            t.info.rbBeats = a.beats.map { it.ms / 1000.0 }
            t.info.rbBeat0 = a.beats.indexOfFirst { it.n == 1 }.coerceAtLeast(0)
        } else t.info.rbBeats = null
        RekordboxANLZ.phrases(ext)?.let { t.info.phrases = it }
        val c = RekordboxANLZ.cues(if (ext.hot.isNotEmpty() || ext.memory.isNotEmpty()) ext else a)
        t.info.rbCues = CueSet(c.cue, c.hot)
        t.rec.ver = Library.ANALYSIS_VER
    }

    // ---- editing a stick's playlists ----

    fun tracks(n: PDBPlaylist, d: Device): List<LibTrack> = n.tracks.mapNotNull { d.byRbId[it] }

    private val pending = HashMap<String, Runnable>()
    fun edit(d: Device, change: (List<PDBPlaylist>) -> List<PDBPlaylist>?) {
        if (!editable) { status("Turn on Settings → rekordbox USB playlists → Editable to change a stick's playlists", 7.0); return }
        d.tree = change(d.tree) ?: run { status("Can't move a folder into itself", 4.0); return }
        d.unsaved = true
        pending[d.id]?.let(main::removeCallbacks)
        val w = Runnable { write(d) }
        pending[d.id] = w
        main.postDelayed(w, 700)
        onChange()
    }
    fun add(tracks: List<LibTrack>, to: Long, d: Device) {
        val ok = tracks.filter { it.device == d.id && it.rb != null }
        if (ok.size < tracks.size) status("Only tracks on ${d.name} can go in its playlists" + if (ok.isEmpty()) "" else ": added the ${ok.size} that are", 7.0)
        if (ok.isEmpty()) return
        edit(d) { PDBTree.addTracks(it, to, ok.map { t -> t.rb!!.id }) }
    }
    fun remove(positions: Set<Int>, from: Long, d: Device) = edit(d) { PDBTree.removeTracks(it, from, positions) }
    fun move(from: Set<Int>, to: Int, inList: Long, d: Device) = edit(d) { PDBTree.moveTracks(it, inList, from, to) }
    fun rename(id: Long, name: String, d: Device) = edit(d) { PDBTree.rename(it, id, name) }
    fun delete(id: Long, d: Device) = edit(d) { PDBTree.delete(it, id) }
    fun moveNode(id: Long, into: Long, d: Device) = edit(d) { PDBTree.moveNode(it, id, into) }
    fun duplicate(id: Long, d: Device) = edit(d) { PDBTree.duplicate(it, id) }
    fun newNode(name: String, folder: Boolean, parent: Long = 0, d: Device): Long {
        var made = 0L
        edit(d) { t -> PDBTree.newNode(t, name, folder, parent).let { made = it.second; it.first } }
        return made
    }

    fun write(d: Device) {
        if (d.saving) { pending[d.id]?.let(main::removeCallbacks); val w = Runnable { write(d) }; pending[d.id] = w; main.postDelayed(w, 500); return }
        d.saving = true; onChange()
        val nodes = PDBTree.forWrite(d.tree)
        val stamp = d.stamp
        val backups = File(app.filesDir, "Cratebox/usb-backups/${d.id}")
        io.execute {
            var msg: String? = null; var newStamp: String? = null
            try {
                val cur = d.fs.read(PDB_REL) ?: throw IllegalStateException("export.pdb can't be read")
                if (PDBTree.stamp(cur) != stamp) msg = "Not saved: ${d.name} changed since Cratebox opened it (rekordbox exported to it?). Close it and open it again, then redo the change."
                else {
                    val out = PDB.writePlaylists(cur, nodes)          // checks itself: throws rather than write anything wrong
                    USBSafeWrite.write(out, d.fs, PDB_REL, USBSafeWrite.hash(cur), backups) { staged ->
                        val p = PDB.problems(staged); if (p.isNotEmpty()) throw IllegalStateException(p[0])
                    }
                    newStamp = PDBTree.stamp(out)
                }
            } catch (e: Exception) { msg = "Not saved to ${d.name}: ${e.message}" }
            main.post {
                d.saving = false
                val s = newStamp
                if (s != null) {
                    d.stamp = s; d.unsaved = false
                    if (!d.told) {
                        d.told = true
                        status("Saved to ${d.name}. Syncing these playlists from rekordbox again replaces the changes." +
                            if (d.oneLibrary) " Newer players that read the stick's OneLibrary database won't see them (only the older export.pdb is updated)." else "", 14.0)
                    } else status("Saved to ${d.name}", 3.0)
                } else { d.unsaved = true; status(msg ?: "Not saved", 12.0) }
                onChange()
            }
        }
    }
}
