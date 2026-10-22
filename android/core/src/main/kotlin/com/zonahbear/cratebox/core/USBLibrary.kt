// Cratebox USB: one view of a rekordbox stick that may carry two libraries at once, the Device Library
// (export.pdb, read by most players) and OneLibrary (exportLibrary.db, read by the newer ones). A port of
// USBLibrary.swift. Tracks are matched between the two by their path on the stick; playlists by their place
// in the tree (folder names down to the playlist's own name). Where the two disagree, that's a sync conflict:
// a player reading the other library would see something different from what you prepared.
package com.zonahbear.cratebox.core

import kotlin.math.abs

data class USBTrack(
    val key: String,                        // the path on the stick, lower-cased, leading "/" kept
    val path: String,                       // as stored ("/Contents/Artist/Album/file.mp3")
    val title: String, val artist: String, val album: String, val genre: String, val label: String, val keyName: String, val comment: String,
    val bpm: Double, val duration: Double,  // seconds
    val fileSize: Long, val sampleRate: Int, val bitrate: Int, val bitDepth: Int,
    val anlzPath: String,
    val rating: Int, val color: Int,
    val pdbId: Long?, val olId: Long?,
) {
    val id get() = key
    val fileName: String get() = path.trimEnd('/').substringAfterLast('/')
    val ext: String get() = fileName.let { n -> if (n.contains('.') && !n.startsWith('.')) n.substringAfterLast('.').lowercase() else "" }
    companion object { fun key(path: String) = (if (path.startsWith("/")) path else "/$path").lowercase() }
}

data class USBPlaylist(
    val name: String,
    val folder: Boolean,
    val treePath: List<String>,             // names from the top level down, this one last
    val tracks: List<String>,               // track keys, in order
    val pdbId: Long?, val olId: Long?,
) {
    val id: String get() = treePath.joinToString("\u001f")
    val depth get() = treePath.size - 1
}

enum class USBLibraryKind(val label: String) { DEVICE_LIBRARY("Device Library"), ONE_LIBRARY("OneLibrary") }

data class USBSyncDifference(val kind: Kind, val subject: String, val detail: String) {
    enum class Kind(val raw: String) {
        TRACK_ONLY_IN_DEVICE_LIBRARY("trackOnlyInDeviceLibrary"), TRACK_ONLY_IN_ONE_LIBRARY("trackOnlyInOneLibrary"),
        METADATA_DIFFERS("metadataDiffers"), PLAYLIST_ONLY_IN_DEVICE_LIBRARY("playlistOnlyInDeviceLibrary"),
        PLAYLIST_ONLY_IN_ONE_LIBRARY("playlistOnlyInOneLibrary"), PLAYLIST_CONTENT_DIFFERS("playlistContentDiffers");
        val isPlaylist get() = this == PLAYLIST_ONLY_IN_DEVICE_LIBRARY || this == PLAYLIST_ONLY_IN_ONE_LIBRARY || this == PLAYLIST_CONTENT_DIFFERS
    }
    val id get() = kind.raw + "|" + subject      // subject: track key or playlist id
}

class USBLibrary(val pdb: PDBDatabase?, val one: OneLibraryDatabase?, val oneError: String? = null) {
    val hasDeviceLibrary get() = pdb != null
    val hasOneLibrary get() = one != null
    var tracks: List<USBTrack> = emptyList(); private set
    var playlists: List<USBPlaylist> = emptyList(); private set      // tree order (folders before their contents)
    var byKey: Map<String, Int> = emptyMap(); private set
    var differences: List<USBSyncDifference> = emptyList(); private set

    init { merge() }

    fun track(key: String): USBTrack? = byKey[key]?.let { tracks[it] }

    private fun merge() {
        val list = ArrayList<USBTrack>(); val idx = HashMap<String, Int>()
        fun add(t: USBTrack) {
            val i = idx[t.key]
            if (i != null) { if (list[i].olId == null) list[i] = list[i].copy(olId = t.olId) } else { idx[t.key] = list.size; list.add(t) }
        }
        val pdbKeyOf = HashMap<Long, String>(); val olKeyOf = HashMap<Long, String>()
        pdb?.let { p ->
            for (r in p.tracks) {
                val k = USBTrack.key(r.path)
                pdbKeyOf[r.id] = k
                add(USBTrack(k, r.path, r.title.ifEmpty { r.filename }, r.artist, r.album, r.genre, r.label, r.key, r.comment, r.bpm, r.duration.toDouble(),
                    r.size, r.sampleRate.toInt(), 0, 0, r.anlzPath, r.rating, r.color, r.id, null))
            }
        }
        one?.let { o ->
            for (r in o.tracks) {
                val k = USBTrack.key(r.path)
                olKeyOf[r.id] = k
                val i = idx[k]
                if (i != null) {
                    var t = list[i].copy(olId = r.id)
                    if (t.bitDepth == 0) t = t.copy(bitDepth = r.bitDepth.toInt())
                    if (t.bitrate == 0) t = t.copy(bitrate = r.bitrate.toInt())
                    list[i] = t
                } else {
                    add(USBTrack(k, r.path, r.title.ifEmpty { r.fileName }, r.artist, r.album, r.genre, r.label, r.key, r.comment, r.bpm, r.durationMs / 1000.0,
                        r.fileSize, r.sampleRate.toInt(), r.bitrate.toInt(), r.bitDepth.toInt(), r.anlzPath, r.rating.toInt(), r.color.toInt(), null, r.id))
                }
            }
        }
        tracks = list; byKey = idx
        // playlists: Device Library's tree first, OneLibrary's merged in by tree path
        val pls = ArrayList<USBPlaylist>(); val pidx = HashMap<String, Int>()
        pdb?.let { p ->
            val byParent = p.playlists.groupBy { it.parent }
            fun go(parent: Long, path: List<String>) {
                for (n in (byParent[parent] ?: emptyList()).sortedBy { it.sort }) {
                    var u = USBPlaylist(n.name, n.folder, path + n.name, n.tracks.mapNotNull { pdbKeyOf[it] }, n.id, null)
                    if (pidx[u.id] != null) u = u.copy(treePath = u.treePath.dropLast(1) + (u.treePath.last() + " (${n.id})"))
                    pidx[u.id] = pls.size; pls.add(u)
                    if (n.folder) go(n.id, u.treePath)
                }
            }
            go(0, emptyList())
        }
        one?.let { o ->
            val byParent = o.playlists.groupBy { it.parent }
            fun go(parent: Long, path: List<String>) {
                for (n in (byParent[parent] ?: emptyList()).sortedBy { it.seq }) {
                    val tp = path + n.name
                    val id = tp.joinToString("\u001f")
                    val i = pidx[id]
                    if (i != null && pls[i].olId == null && pls[i].folder == n.folder) pls[i] = pls[i].copy(olId = n.id)
                    else {
                        pidx[id] = pls.size
                        pls.add(USBPlaylist(n.name, n.folder, tp, n.tracks.mapNotNull { olKeyOf[it] }, null, n.id))
                    }
                    if (n.folder) go(n.id, tp)
                }
            }
            go(0, emptyList())
        }
        playlists = pls
        // differences, only when both libraries are there
        val diffs = ArrayList<USBSyncDifference>()
        val p = pdb; val o = one
        if (p != null && o != null) {
            val pk = p.tracks.map { USBTrack.key(it.path) }.toSet(); val ok = o.tracks.map { USBTrack.key(it.path) }.toSet()
            for (k in (pk - ok).sorted()) diffs.add(USBSyncDifference(USBSyncDifference.Kind.TRACK_ONLY_IN_DEVICE_LIBRARY, k, "Only in the Device Library: players reading OneLibrary won't list it"))
            for (k in (ok - pk).sorted()) diffs.add(USBSyncDifference(USBSyncDifference.Kind.TRACK_ONLY_IN_ONE_LIBRARY, k, "Only in OneLibrary: players reading the Device Library won't list it"))
            val olByKey = HashMap<String, OLTrack>()
            for (t in o.tracks) olByKey.putIfAbsent(USBTrack.key(t.path), t)
            for (r in p.tracks) {
                val q = olByKey[USBTrack.key(r.path)] ?: continue
                val what = ArrayList<String>()
                if (r.title.isNotEmpty() && q.title.isNotEmpty() && r.title != q.title) what.add("title")
                if (r.artist != q.artist && !(r.artist.isEmpty() || q.artist.isEmpty())) what.add("artist")
                if (r.bpm > 0 && q.bpm > 0 && abs(r.bpm - q.bpm) > 0.011) what.add(fmt("BPM %.2f vs %.2f", r.bpm, q.bpm))
                if (r.key.isNotEmpty() && q.key.isNotEmpty() && RekordboxANLZ.keyIndex(r.key) != RekordboxANLZ.keyIndex(q.key)) what.add("key ${r.key} vs ${q.key}")
                if (what.isNotEmpty()) diffs.add(USBSyncDifference(USBSyncDifference.Kind.METADATA_DIFFERS, USBTrack.key(r.path), "The two libraries disagree on " + what.joinToString(", ")))
            }
            for (u in pls) {
                val pi = u.pdbId; val oi = u.olId
                if (pi != null && oi == null) diffs.add(USBSyncDifference(USBSyncDifference.Kind.PLAYLIST_ONLY_IN_DEVICE_LIBRARY, u.id, "\"${u.name}\" is only in the Device Library"))
                else if (oi != null && pi == null) diffs.add(USBSyncDifference(USBSyncDifference.Kind.PLAYLIST_ONLY_IN_ONE_LIBRARY, u.id, "\"${u.name}\" is only in OneLibrary"))
                else if (pi != null && oi != null && !u.folder) {
                    val a = p.playlists.firstOrNull { it.id == pi }?.tracks?.mapNotNull { pdbKeyOf[it] } ?: emptyList()
                    val b = o.playlists.firstOrNull { it.id == oi }?.tracks?.mapNotNull { olKeyOf[it] } ?: emptyList()
                    if (a != b) {
                        val sa = a.toSet(); val sb = b.toSet()
                        val why = if (sa == sb) "same tracks in a different order" else "${a.size} tracks vs ${b.size}, ${((sa - sb) + (sb - sa)).size} differ"
                        diffs.add(USBSyncDifference(USBSyncDifference.Kind.PLAYLIST_CONTENT_DIFFERS, u.id, "\"${u.name}\": $why"))
                    }
                }
            }
        }
        differences = diffs
    }

    /** bit rate / bit depth from export.pdb's track rows (PDB.trackFormats), where the merge left them unknown */
    fun setFormats(f: Map<Long, PDB.TrackFormat>) {
        tracks = tracks.map { t ->
            val x = t.pdbId?.let { f[it] } ?: return@map t
            t.copy(bitDepth = if (t.bitDepth == 0) x.bitDepth else t.bitDepth, bitrate = if (t.bitrate == 0) x.bitrate else t.bitrate,
                sampleRate = if (t.sampleRate == 0) x.sampleRate else t.sampleRate)
        }
    }

    val inSync get() = differences.isEmpty()
    fun playlist(id: String): USBPlaylist? = playlists.firstOrNull { it.id == id }

    /** tracks of a playlist, or of a folder and everything under it */
    fun trackKeys(id: String): List<String> {
        val p = playlist(id) ?: return emptyList()
        if (!p.folder) return p.tracks
        val seen = HashSet<String>(); val out = ArrayList<String>()
        for (q in playlists) {
            if (q.folder || q.treePath.size <= p.treePath.size || q.treePath.take(p.treePath.size) != p.treePath) continue
            for (k in q.tracks) if (seen.add(k)) out.add(k)
        }
        return out
    }
}
