// The library (Library.swift on iOS): music folders picked with the system folder picker (the permission is
// kept, so they come back after a restart), their audio files with tags, and each track's analysis, cached on
// the phone. Like the web app, Cratebox reads the files in place: nothing is copied. rekordbox sticks are
// opened through Devices and their tracks join the list while they're open.
package com.zonahbear.cratebox.platform

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.zonahbear.cratebox.core.Analysis
import com.zonahbear.cratebox.core.MusicFolder
import com.zonahbear.cratebox.core.PDBTrack
import com.zonahbear.cratebox.core.TrackInfo
import com.zonahbear.cratebox.core.TrackRecord
import java.io.File
import java.util.concurrent.Executors

class LibTrack(var rec: TrackRecord) {
    val info = TrackInfo(rec.id, rec.title, rec.artist, rec.bpm, rec.firstBeat, rec.key, rec.duration, rec.phrases).also {
        it.gridManual = rec.gridManual; it.autoBpm = rec.autoBpm; it.autoFirst = rec.autoFirst
    }
    val id get() = rec.id
    /** rekordbox stick tracks: the stick and the track's row in its export.pdb */
    var device: String? = null
    var rb: PDBTrack? = null
    fun sync() {
        rec.bpm = info.bpm; rec.firstBeat = info.firstBeat; rec.key = info.key; rec.duration = info.duration; rec.phrases = info.phrases
        rec.gridManual = info.gridManual; rec.autoBpm = info.autoBpm; rec.autoFirst = info.autoFirst
    }
    val analysed get() = rec.ver == Library.ANALYSIS_VER && (rec.bpm ?: 0.0) > 0
}

class Library(context: Context) {
    companion object { const val ANALYSIS_VER = 7 }
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val dir = File(app.filesDir, "Cratebox").apply { mkdirs() }
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "cratebox-library").apply { priority = Thread.MIN_PRIORITY + 1 } }

    var tracks: List<LibTrack> = emptyList(); private set
    var folders: List<MusicFolder> = MusicFolder.parseAll(read("folders.json")); private set
    var progress = ""; private set
    var status: (String) -> Unit = {}
    var isPlaying: () -> Boolean = { false }
    var onChange: () -> Unit = {}
    /** rekordbox sticks: Devices supplies their files and analysis */
    var devices: Devices? = null
    private var byId = HashMap<String, LibTrack>()
    private val fs = HashMap<String, SafStickFS>()
    private val queue = ArrayList<LibTrack>()
    private var analysing = false

    init {
        tracks = TrackRecord.parseAll(read("library.json")).map(::LibTrack)
        for (t in tracks) byId[t.id] = t
    }

    private fun read(name: String) = runCatching { File(dir, name).takeIf { it.exists() }?.readText() }.getOrNull()
    private fun write(name: String, text: String) {
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(text)
        tmp.renameTo(File(dir, name))
    }
    private fun changed() = onChange()

    fun track(id: String) = byId[id]

    // ---- folders ----

    /** the folder as a file tree, or null when the permission was lost */
    fun fs(f: MusicFolder): SafStickFS? = fs[f.id] ?: runCatching {
        val u = Uri.parse(f.uri)
        if (app.contentResolver.persistedUriPermissions.none { it.uri == u }) null else SafStickFS(app, u).also { fs[f.id] = it }
    }.getOrNull()

    /** from the folder picker (ACTION_OPEN_DOCUMENT_TREE): keep the permission, then scan it, or open it as a stick */
    fun addFolder(tree: Uri, device: Boolean = false): MusicFolder? {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try { app.contentResolver.takePersistableUriPermission(tree, flags) }
        catch (e: SecurityException) {
            runCatching { app.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                .onFailure { status("Couldn't keep access to that folder"); return null }
        }
        val s = SafStickFS(app, tree)
        // a rekordbox USB/SD picked as a music folder: open it as the device it is (playlists, grids, keys, cues)
        if (!device && s.exists("PIONEER/rekordbox/export.pdb")) { devices?.open(tree); return null }
        val name = s.displayName()
        val id = (if (device) "usb-" else "dir-") + name + "-" + Integer.toHexString(tree.toString().hashCode())
        val f = MusicFolder(id, name, tree.toString(), device)
        folders = folders.filter { it.id != id } + f
        fs[id] = s
        saveFolders()
        if (!device) scan(f)
        changed()
        return f
    }

    fun removeFolder(f: MusicFolder) {
        folders = folders.filter { it.id != f.id }
        fs.remove(f.id)
        // the permission goes too, unless another folder entry uses the same tree
        if (folders.none { it.uri == f.uri }) runCatching {
            app.contentResolver.releasePersistableUriPermission(Uri.parse(f.uri), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        tracks = tracks.filter { it.rec.folder != f.id }
        byId = HashMap(tracks.associateBy { it.id })
        saveFolders(); save(); changed()
    }
    private fun saveFolders() = write("folders.json", MusicFolder.encodeAll(folders))

    fun scan(f: MusicFolder) {
        val root = fs(f) ?: run { status("${f.name}: pick it again (Cratebox lost access)"); return }
        progress = "Scanning ${f.name}…"; changed()
        worker.execute {
            val found = runCatching { root.walk("", TrackRecord.AUDIO_EXT) }.getOrElse { emptyList() }
            main.post { merge(f, found) }
        }
    }

    private fun merge(f: MusicFolder, found: List<Triple<String, Long, Double>>) {
        val keep = ArrayList<LibTrack>(); val fresh = ArrayList<LibTrack>()
        for ((rel, size, mtime) in found) {
            val r = TrackRecord.fresh(f.id, rel, size, mtime)
            val t = byId[r.id]
            if (t != null) { keep.add(t); continue }
            val n = LibTrack(r); keep.add(n); fresh.add(n)
        }
        tracks = tracks.filter { it.rec.folder != f.id } + keep
        byId = HashMap<String, LibTrack>().apply { for (t in tracks) putIfAbsent(t.id, t) }
        progress = ""
        status("${f.name}: ${keep.size} tracks" + if (fresh.isEmpty()) "" else ", ${fresh.size} new")
        save()
        readTags(fresh)
        for (t in keep) if (!t.analysed) queue.add(t)
        runQueue()
        changed()
    }

    private fun readTags(list: List<LibTrack>) {
        if (list.isEmpty()) return
        worker.execute {
            for (t in list) {
                val u = fileUri(t) ?: continue
                val mmr = MediaMetadataRetriever()
                try {
                    mmr.setDataSource(app, u)
                    val title = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                    val artist = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    main.post {
                        if (!title.isNullOrBlank()) { t.rec.title = title; t.info.title = title }
                        if (!artist.isNullOrBlank()) { t.rec.artist = artist; t.info.artist = artist }
                    }
                } catch (_: Exception) {
                } finally { runCatching { mmr.release() } }
            }
            main.post { save(); changed() }
        }
    }

    /** where a track's file is: its music folder, or the stick it's on */
    fun fileUri(t: LibTrack): Uri? {
        if (t.device != null) return devices?.uri(t)
        val f = folders.firstOrNull { it.id == t.rec.folder } ?: return null
        return fs(f)?.documentUri(t.rec.rel)
    }

    /** tracks on a rekordbox stick join the library while it's open */
    fun setDeviceTracks(dev: String, list: List<LibTrack>) {
        tracks = tracks.filter { it.device != dev } + list
        byId = HashMap<String, LibTrack>().apply { for (t in tracks) putIfAbsent(t.id, t) }
        changed()
    }

    fun changed(t: LibTrack) { t.sync(); save() }

    private val saveRun = Runnable {
        val recs = tracks.filter { it.device == null }.map { it.rec.copy(phrases = it.rec.phrases.toList()) }
        worker.execute { runCatching { write("library.json", TrackRecord.encodeAll(recs)) } }
    }
    fun save() { main.removeCallbacks(saveRun); main.postDelayed(saveRun, 500) }

    // ---- analysis in the background (one at a time, paused while the decks play on small devices) ----

    fun enqueue(t: LibTrack) { if (queue.none { it === t }) queue.add(t); runQueue() }

    fun runQueue() {
        if (analysing) return
        val t = queue.firstOrNull() ?: run { if (!progress.startsWith("Scanning")) { progress = ""; changed() }; return }
        if (Runtime.getRuntime().availableProcessors() <= 4 && isPlaying()) {
            progress = "Analysis paused while playing"; changed()
            main.postDelayed({ runQueue() }, 2000)
            return
        }
        queue.removeAt(0)
        if (t.analysed) { runQueue(); return }
        // rekordbox USB tracks: rekordbox already analysed them; use that (Cratebox analyses only if it's missing)
        if (t.device != null) {
            devices?.readAnalysis(t)
            if ((t.info.bpm ?: 0.0) > 0 && t.info.firstBeat != null) { t.rec.ver = ANALYSIS_VER; changed(t); main.post { runQueue() }; return }
        }
        analysing = true
        progress = "Analysing ${queue.size + 1} track${if (queue.isEmpty()) "" else "s"}…"; changed()
        val uri = fileUri(t)
        val grid = if (t.rec.gridManual) (t.rec.bpm ?: 0.0) to (t.rec.firstBeat ?: 0.0) else null
        worker.execute {
            val res = runCatching {
                val pcm = AudioDecoder.decode(app, uri ?: throw AudioDecoder.Failure("no file"))
                val (x, fs) = AudioDecoder.mono(pcm, 11025.0)
                Analysis.analyze(x, fs, noWave = true, grid = grid) to pcm.count / pcm.sampleRate
            }.getOrNull()
            main.post {
                analysing = false
                if (res != null) {
                    val (r, dur) = res
                    t.info.bpm = r.bpm; t.info.firstBeat = r.firstBeat; t.info.phrases = r.phrases; t.info.duration = dur
                    if (!t.info.keyFromRekordbox) t.info.key = r.key
                    if (!t.info.gridManual) { t.info.autoBpm = r.bpm; t.info.autoFirst = r.firstBeat }
                } else t.info.bpm = 0.0
                t.rec.ver = ANALYSIS_VER
                changed(t); changed()
                runQueue()
            }
        }
    }
}
