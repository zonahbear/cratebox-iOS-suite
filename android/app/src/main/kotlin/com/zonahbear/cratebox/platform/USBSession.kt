// Cratebox USB (USBSession.swift on iOS): the stick that's open, both its libraries, the preflight scan, your edits
// (kept as staged changes until they can go somewhere), and every write to the stick (through USBSafeWrite, and
// only the kinds USBWriteGate lets through: nothing is proven by default, so cue/grid/info writes stay locked
// until Proving Ground says otherwise). The staged-edit rules are core's USBEdits; this is the I/O and threads.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.zonahbear.cratebox.core.CueStore
import com.zonahbear.cratebox.core.OneLibrary
import com.zonahbear.cratebox.core.OneLibraryDatabase
import com.zonahbear.cratebox.core.OneLibraryError
import com.zonahbear.cratebox.core.PDB
import com.zonahbear.cratebox.core.PDBError
import com.zonahbear.cratebox.core.Preflight
import com.zonahbear.cratebox.core.QuickFix
import com.zonahbear.cratebox.core.Readiness
import com.zonahbear.cratebox.core.ScanIssue
import com.zonahbear.cratebox.core.ScanMode
import com.zonahbear.cratebox.core.ScanOptions
import com.zonahbear.cratebox.core.ScanReport
import com.zonahbear.cratebox.core.IssueSeverity
import com.zonahbear.cratebox.core.USBEdits
import com.zonahbear.cratebox.core.USBLibrary
import com.zonahbear.cratebox.core.USBSafeWrite
import com.zonahbear.cratebox.core.USBTrackEdit
import com.zonahbear.cratebox.core.USBTrackWriter
import com.zonahbear.cratebox.core.USBWriteGate
import com.zonahbear.cratebox.core.USBWriteKind
import java.io.File
import java.util.concurrent.Executors

class USBSession(context: Context, audio: AudioHost, prefs: AndroidPrefs, private val appLibrary: Library, private val devices: Devices,
                 private val performanceCues: CueStore) {
    companion object {
        const val PDB_REL = "PIONEER/rekordbox/export.pdb"
        const val OL_REL = "PIONEER/rekordbox/exportLibrary.db"
    }
    val context: Context = context.applicationContext
    private val sp = prefs.sp
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "cratebox-usb") }
    val preview = USBPreview(audio, prefs).also { it.session = this }
    var onChange: () -> Unit = {}
    var status: (String, Double) -> Unit = { _, _ -> }
    fun changed() = onChange()

    // ---- the stick ----
    var tree: Uri? = null; private set
    var fs: SafStickFS? = null; private set
    var name = ""; private set
    var library: USBLibrary? = null; private set
    var loading = false; private set
    var lastMessage = ""; private set           // the last thing that happened, for the status line
    private var pdbBytes: ByteArray? = null; private var olBytes: ByteArray? = null
    val stickId get() = tree?.let { "usb-" + name + "-" + Integer.toHexString(it.toString().hashCode()) } ?: ""

    // ---- the scan ----
    var players: List<String> = sp.getString("cb.usb.players", null)?.split(',')?.filter { it.isNotEmpty() } ?: listOf("unknown")
        set(v) { field = v; sp.edit().putString("cb.usb.players", v.joinToString(",")).apply(); changed() }
    var setPlaylist: String? = null
        set(v) { field = v; if (stickId.isNotEmpty()) sp.edit().putString("cb.usb.set.$stickId", v).apply(); changed() }
    var mode = ScanMode.STANDARD
    var report: ScanReport? = null; private set
    var scanning = false; private set
    var scanProgress = 0.0; private set
    var scanText = ""; private set
    var skipped: Set<String> = emptySet()
        set(v) { field = v; if (stickId.isNotEmpty()) sp.edit().putStringSet("cb.usb.skipped.$stickId", v).apply(); changed() }
    val fixList = ArrayList<String>()            // track keys to sort out in rekordbox
    @Volatile private var cancelScan = false
    val readiness: Readiness get() {
        val r = report ?: return Readiness.Unknown
        if (r.pdbHash != pdbBytes?.let(USBSafeWrite::hash) || r.olHash != olBytes?.let(USBSafeWrite::hash)) return Readiness.Unknown   // the stick changed since
        return r.readiness(skipped)
    }
    fun issues(key: String): List<ScanIssue> = report?.issues?.filter { it.trackKey == key && it.id !in skipped } ?: emptyList()

    // ---- edits ----
    val edits = USBEdits()

    // ---- writing ----
    var proven: Set<USBWriteKind> = sp.getStringSet("cb.usb.proven", emptySet())!!.mapNotNull { r -> USBWriteKind.entries.firstOrNull { it.raw == r } }.toSet()
        set(v) { field = v; sp.edit().putStringSet("cb.usb.proven", v.map { it.raw }.toSet()).apply(); changed() }
    val gate get() = USBWriteGate(proven)
    var writing = false; private set
    var ejected = false; private set
    val playlistBlocker: String? get() {
        val l = library ?: return "No stick open"
        return gate.playlistWriteBlocker(l.hasDeviceLibrary, l.hasOneLibrary)
    }

    private var reopened = false
    fun setActive(on: Boolean) {
        preview.setActive(on)
        if (on && !reopened) {
            reopened = true
            val saved = sp.getString("cb.usb.tree", null)?.let(Uri::parse)
            if (tree == null && saved != null && context.contentResolver.persistedUriPermissions.any { it.uri == saved }) {
                val s = SafStickFS(context, saved)
                if (runCatching { s.list("PIONEER") != null }.getOrDefault(false)) open(saved, remember = false)
            }
        }
    }

    // ---- opening ----

    /** a stick picked with ACTION_OPEN_DOCUMENT_TREE (the drive itself) */
    fun open(t: Uri, remember: Boolean = true) {
        if (remember) {
            runCatching { context.contentResolver.takePersistableUriPermission(t, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            sp.edit().putString("cb.usb.tree", t.toString()).apply()
        }
        val s = SafStickFS(context, t)
        tree = t; fs = s; ejected = false
        name = s.displayName()
        skipped = sp.getStringSet("cb.usb.skipped.$stickId", emptySet())!!.toSet()
        setPlaylist = sp.getString("cb.usb.set.$stickId", null)
        loadEdits()
        loading = true; changed()
        io.execute {
            // a save that was cut off last time comes first
            val rec = runCatching { USBSafeWrite.recover(s) }.getOrElse { emptyList() }
            main.post {
                for (r in rec) when (r) {
                    is USBSafeWrite.Recovery.Restored -> note(r.what)
                    is USBSafeWrite.Recovery.CleanedUp -> note(r.what)
                    is USBSafeWrite.Recovery.NeedsAttention -> note("Needs attention: ${r.what}")
                    USBSafeWrite.Recovery.Nothing -> {}
                }
                reload()
            }
        }
    }

    /** (re)read both libraries off the stick */
    fun reload(keepNodes: Boolean = false) {
        val s = fs ?: return
        loading = true; changed()
        io.execute {
            val pdb = s.read(PDB_REL); val ol = s.read(OL_REL)
            var one: OneLibraryDatabase? = null; var oneErr: String? = null
            if (ol != null) try { one = OneLibrary.read(ol) } catch (e: Exception) { oneErr = e.message ?: e.toString() }
            val lib = USBLibrary(pdb?.let(PDB::parse), one, oneErr)
            if (pdb != null) lib.setFormats(PDB.trackFormats(pdb))
            main.post {
                pdbBytes = pdb; olBytes = ol
                library = lib
                loading = false
                edits.loaded(lib, keepNodes)
                setPlaylist?.let { if (lib.playlist(it) == null) setPlaylist = null }
                if (pdb == null && ol == null) note("$name has no rekordbox library (no PIONEER/rekordbox/export.pdb or exportLibrary.db)")
                else note("$name: ${lib.tracks.size} tracks, ${lib.playlists.count { !it.folder }} playlists · " +
                    listOfNotNull(if (lib.hasDeviceLibrary) "Device Library" else null, if (lib.hasOneLibrary) "OneLibrary" else null).joinToString(" + ") +
                    if (oneErr != null) " (OneLibrary unreadable)" else "")
            }
        }
    }

    fun message(s: String) { lastMessage = s; changed() }
    fun note(s: String) { lastMessage = s; status(s, 8.0); changed() }

    // ---- scanning ----
    fun scan(m: ScanMode? = null) {
        val lib = library ?: return; val s = fs ?: return
        if (scanning) return
        val opts = ScanOptions(m ?: mode, players, setPlaylist, null)
        scanning = true; cancelScan = false; scanProgress = 0.0; scanText = "Starting…"; changed()
        val pdb = pdbBytes; val ol = olBytes
        val decode: ((String) -> String?)? = if (opts.mode == ScanMode.DEEP) { path ->
            s.documentUri(path.trimStart('/'))?.let { AudioDecoder.decodeCheck(context, it) } ?: "the file isn't on the stick"
        } else null
        io.execute {
            val r = Preflight.run(lib, s, opts, pdb, ol,
                progress = { p, t -> main.post { scanProgress = p; scanText = t; changed() } },
                cancelled = { cancelScan }, decode = decode)
            main.post {
                report = r; scanning = false
                note("${opts.mode.title} scan: ${r.tracksChecked} tracks · ${readiness.label}")
            }
        }
    }
    fun stopScan() { cancelScan = true }

    // ---- quick fixes ----
    class QuickFixGroup(val fix: QuickFix, val count: Int)
    val quickFixes: List<QuickFixGroup> get() {
        val r = report ?: return emptyList()
        val open = r.issues.filter { it.id !in skipped }
        val out = ArrayList<QuickFixGroup>()
        for (f in listOf(QuickFix.RECOVER_WRITE, QuickFix.RESTORE_BACKUP, QuickFix.REMOVE_FROM_PLAYLISTS, QuickFix.SYNC_PLAYLISTS, QuickFix.EXPORT_FIX_LIST)) {
            val n = open.count { it.fix == f }
            if (n > 0) out.add(QuickFixGroup(f, n))
        }
        val info = open.count { it.severity == IssueSeverity.INFO }
        if (info > 0) out.add(QuickFixGroup(QuickFix.SKIP, info))
        return out
    }
    fun runQuickFix(f: QuickFix) {
        val r = report ?: return
        val open = r.issues.filter { it.id !in skipped }
        if (f == QuickFix.SKIP) { skipped = skipped + open.filter { it.severity == IssueSeverity.INFO }.map { it.id }; return }
        for (i in open) if (i.fix == f) fix(i, batch = true)
        if (f == QuickFix.REMOVE_FROM_PLAYLISTS || f == QuickFix.SYNC_PLAYLISTS) stagedPlaylistsNote()
        if (f == QuickFix.EXPORT_FIX_LIST) note("${fixList.size} track${if (fixList.size == 1) "" else "s"} on the fix list (Staged → Share fix list)")
    }
    private fun stagedPlaylistsNote() = note(playlistBlocker?.let { "Staged. $it" } ?: "Staged: Staged changes → Write to stick when you're ready")

    /** one issue's fix */
    fun fix(i: ScanIssue, batch: Boolean = false) {
        when (i.fix) {
            QuickFix.RECOVER_WRITE -> {
                val s = fs ?: return
                for (r in USBSafeWrite.recover(s)) when (r) {
                    is USBSafeWrite.Recovery.Restored -> note(r.what)
                    is USBSafeWrite.Recovery.CleanedUp -> note(r.what)
                    is USBSafeWrite.Recovery.NeedsAttention -> note(r.what)
                    USBSafeWrite.Recovery.Nothing -> {}
                }
                reload(); skipped = skipped + i.id
            }
            QuickFix.RESTORE_BACKUP -> restoreBackup(if (i.id.contains("ol")) OL_REL else PDB_REL)
            QuickFix.REMOVE_FROM_PLAYLISTS -> {
                i.trackKey?.let { edits.removeEverywhere(it, library?.track(it)?.fileName ?: it) }
                skipped = skipped + i.id
                if (!batch) stagedPlaylistsNote()
            }
            QuickFix.SYNC_PLAYLISTS -> {
                // the tree being edited is already one tree for both libraries: writing it makes them agree
                edits.markAllForSync()
                skipped = skipped + i.id
                if (!batch) stagedPlaylistsNote()
            }
            QuickFix.EXPORT_FIX_LIST -> {
                i.trackKey?.let { if (it !in fixList) fixList.add(it) }
                skipped = skipped + i.id
                if (!batch) note("Added to the fix list")
            }
            QuickFix.SKIP -> skipped = skipped + i.id
            QuickFix.REEXPORT, null -> note("Only rekordbox can fix this: ${i.detail}")
        }
        changed()
    }
    fun skip(i: ScanIssue) { skipped = skipped + i.id }
    fun unskipAll() { skipped = emptySet() }

    // ---- staged edits ----
    fun edit(key: String, change: (USBTrackEdit) -> USBTrackEdit) { edits.edit(key, change); saveEdits(); changed() }
    fun revert(key: String) { edits.edit(key) { USBTrackEdit() }; edits.log("Revert ${library?.track(key)?.fileName ?: key}"); saveEdits(); changed() }
    fun addMemory(key: String, time: Double, loopEnd: Double? = null) { edits.addMemory(key, library?.track(key)?.fileName ?: key, time, loopEnd); saveEdits(); changed() }
    fun deleteMemory(key: String, id: String) { edits.deleteMemory(key, id); saveEdits(); changed() }
    fun deleteNode(id: String) { val k = edits.delete(id); setPlaylist?.let { if (it in k) setPlaylist = null }; changed() }
    fun discardPlaylistChanges() { edits.discardPlaylistChanges(); note("Playlist changes discarded") }

    private fun editsFile(): File? {
        if (stickId.isEmpty()) return null
        val d = File(context.filesDir, "Cratebox/usb").apply { mkdirs() }
        return File(d, stickId.replace("/", "_") + ".edits.json")
    }
    private fun saveEdits() { val f = editsFile() ?: return; val text = USBTrackEdit.encodeAll(edits.edits); io.execute { runCatching { f.writeText(text) } } }
    private fun loadEdits() { edits.edits = USBTrackEdit.parseAll(editsFile()?.takeIf { it.exists() }?.readText()) }

    // ---- where edits can go ----

    /** cues and grids into Cratebox's own library, so Performance Mode plays the stick with them */
    fun applyToPerformance() {
        val lib = library ?: return
        var cues = 0; var grids = 0
        for ((key, e) in edits.edits) {
            if (e.isEmpty) continue
            val t = lib.track(key) ?: continue
            val dev = devices.list.firstOrNull { d -> d.byRbId.values.any { it.rb?.path == t.path } }
            val id = (dev?.id ?: stickId) + "|" + t.path
            if (e.hasCues) {
                val cur = performanceCues.load(id)
                performanceCues.save(id, e.cue ?: e.memory?.firstOrNull()?.time ?: cur?.cue, e.hot ?: cur?.hot ?: List(8) { null })
                cues++
            }
            if (e.hasGrid) appLibrary.track(id)?.let { lt ->
                e.bpm?.let { lt.info.bpm = it }; e.firstBeat?.let { lt.info.firstBeat = it }
                lt.info.gridManual = true
                appLibrary.changed(lt); grids++
            }
        }
        note("Performance Mode now uses your cues for $cues track${if (cues == 1) "" else "s"}" + (if (grids > 0) " and your grids for $grids" else "") +
            if (edits.edits.values.any { it.hasGrid } && grids == 0) " (grids apply once the stick is open in Performance Mode: + USB)" else "")
    }

    /** rekordbox XML with your edits and the playlists as they are now, saved to Music/Cratebox; null on failure */
    fun exportXML(base: String): String? {
        val lib = library ?: return null
        return edits.exportXML(lib, base)
    }
    fun fixListCSV(): String? { val lib = library ?: return null; return edits.fixListCSV(lib, name, fixList, report?.issues ?: emptyList()) }

    // ---- writing to the stick ----
    private fun appBackups() = File(context.filesDir, "Cratebox/usb-backups/$stickId")

    /** Writes the playlist tree to every library on the stick, or to none: Device Library first, then OneLibrary;
     *  if the second fails, the first is put back. */
    fun writePlaylists() {
        val s = fs ?: return; val lib = library ?: return
        if (writing) return
        playlistBlocker?.let { note(it); return }
        val pn = if (lib.hasDeviceLibrary) edits.pdbNodes(lib) else null to null
        val on = if (lib.hasOneLibrary) edits.olNodes(lib) else null to null
        (pn.second ?: on.second)?.let { note("Can't write: $it. Remove it from the playlists, or re-export from rekordbox."); return }
        val pdb = pdbBytes; val ol = olBytes; val backups = appBackups()
        writing = true; changed()
        io.execute {
            var msg: String
            var wrotePdb = false
            try {
                val nodes = pn.first
                if (nodes != null && pdb != null) {
                    val out = PDB.writePlaylists(pdb, nodes)
                    USBSafeWrite.write(out, s, PDB_REL, USBSafeWrite.hash(pdb), backups) { b ->
                        if (PDB.parse(b).playlists.size != nodes.size) throw PDBError.readBack("playlists didn't read back")
                        PDB.problems(b).firstOrNull()?.let { throw PDBError.readBack(it) }
                    }
                    wrotePdb = true
                }
                val oNodes = on.first
                if (oNodes != null && ol != null) {
                    val out = OneLibrary.writePlaylists(ol, oNodes)
                    USBSafeWrite.write(out, s, OL_REL, USBSafeWrite.hash(ol), backups) { b ->
                        if (OneLibrary.read(b).integrity != listOf("ok")) throw OneLibraryError.readBack("integrity")
                    }
                }
                msg = "Saved the playlists to ${if (lib.hasDeviceLibrary && lib.hasOneLibrary) "both libraries" else if (lib.hasOneLibrary) "OneLibrary" else "the Device Library"} on the stick. Backups are in PIONEER/rekordbox/.cratebox."
            } catch (e: Exception) {
                msg = "Not saved: ${e.message}"
                // all or nothing: the Device Library goes back if OneLibrary couldn't follow
                val now = if (wrotePdb) s.read(PDB_REL) else null
                if (wrotePdb && pdb != null && now != null) {
                    msg += try { USBSafeWrite.write(pdb, s, PDB_REL, USBSafeWrite.hash(now), backups) { }; " The Device Library was put back as it was." }
                           catch (e2: Exception) { " Putting the Device Library back failed too (${e2.message}): restore it from the backup in Cratebox USB." }
                }
            }
            main.post {
                writing = false
                note(msg)
                if (msg.startsWith("Saved")) { edits.playlistsSaved(); reload() }
            }
        }
    }

    val trackEditBlocker: String? get() = edits.trackEditBlocker(library, gate)

    /** Writes every track edit to the stick through USBTrackWriter: all the files, or none. */
    fun writeTrackEdits() {
        val s = fs ?: return; val lib = library ?: return
        if (writing) return
        trackEditBlocker?.let { note(it); return }
        val changes = edits.trackChanges(); val g = gate; val pdb = pdbBytes; val ol = olBytes; val backups = appBackups()
        if (changes.isEmpty()) return
        writing = true; changed()
        io.execute {
            var msg: String; var written = emptyList<String>()
            try {
                val plan = USBTrackWriter.plan(lib, s, changes, g, pdb, ol)
                USBTrackWriter.apply(plan, s, backups)
                written = plan.tracks.toList()
                msg = "Saved edits to ${plan.tracks.size} track${if (plan.tracks.size == 1) "" else "s"} (${plan.files.size} files) on the stick. Backups are in PIONEER/rekordbox/.cratebox."
            } catch (e: Exception) { msg = "Not saved: ${e.message}" }
            main.post {
                writing = false
                note(msg)
                if (written.isNotEmpty()) { edits.trackEditsSaved(written); saveEdits(); reload(keepNodes = true) }
            }
        }
    }

    fun restoreBackup(rel: String) {
        val s = fs ?: return
        writing = true; changed()
        io.execute {
            val b = USBSafeWrite.latestBackup(s, rel)
            val bytes = b?.let(s::read)
            val msg = if (b == null || bytes == null) "No Cratebox backup of $rel on this stick" else try {
                val cur = s.read(rel) ?: ByteArray(0)
                USBSafeWrite.write(bytes, s, rel, USBSafeWrite.hash(cur), null) { }
                "Restored ${rel.substringAfterLast('/')} from ${b.substringAfterLast('/')}"
            } catch (e: Exception) { "Couldn't restore: ${e.message}" }
            main.post { writing = false; note(msg); reload() }
        }
    }

    // ---- eject ----
    fun eject() {
        val t = tree ?: return
        if (writing) { note("Still writing to $name: one moment"); return }
        if (scanning) stopScan()
        preview.unload()
        // Performance Mode may have the same stick open
        devices.list.firstOrNull { it.fs.tree == t }?.let { d ->
            devices.eject(d)
            if (d in devices.list) { note("Performance Mode is still using $name (a deck is playing from it). Not ejected."); return }
        }
        val n = name
        tree = null; fs = null; library = null; report = null; pdbBytes = null; olBytes = null
        edits.nodes = emptyList(); edits.loaded(USBLibrary(null, null), keepNodes = false)
        sp.edit().remove("cb.usb.tree").apply()
        ejected = true
        note("$n let go: every write is already on the stick. Eject it from Android's notification, then unplug.")
    }
}
