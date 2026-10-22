// Cratebox USB's staged changes (the model half of USBSession.swift): the playlist tree being edited, your edits
// to tracks (cues, grid, info), and the change log. Nothing here touches a stick: the app's USBSession turns these
// into writes (Device Library and OneLibrary rows, USBTrackWriter changes, a rekordbox XML, a fix list CSV).
package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.util.UUID

/** one memory cue or saved loop */
data class USBMemoryCue(val time: Double, val loopEnd: Double? = null, val comment: String = "", val id: String = UUID.randomUUID().toString().uppercase())

/** your changes to one track (null = left as rekordbox has it) */
data class USBTrackEdit(
    val cue: Double? = null,
    val hot: List<Double?>? = null,
    val memory: List<USBMemoryCue>? = null,
    val bpm: Double? = null, val firstBeat: Double? = null,
    val title: String? = null, val artist: String? = null, val album: String? = null, val genre: String? = null,
    val comment: String? = null, val rating: Int? = null,
) {
    val isEmpty get() = this == USBTrackEdit()
    val hasCues get() = cue != null || hot != null || memory != null
    val hasGrid get() = bpm != null || firstBeat != null
    val hasMeta get() = title != null || artist != null || album != null || genre != null || comment != null || rating != null

    fun toChanges() = USBTrackChanges(
        cue = cue, hot = hot?.map { s -> s?.let { USBCue(it) } }, memory = memory?.map { USBCue(it.time, it.loopEnd, it.comment) },
        bpm = bpm, firstBeat = firstBeat, title = title, artist = artist, album = album, genre = genre, comment = comment, rating = rating,
    )

    // JSON with the iOS app's Codable keys (nil left out, as Swift's JSONEncoder does)
    fun json(): JsonObject = buildJsonObject {
        cue?.let { put("cue", it) }
        hot?.let { h -> put("hot", JsonArray(h.map { v -> v?.let(::JsonPrimitive) ?: JsonNull })) }
        memory?.let { m ->
            put("memory", JsonArray(m.map { q -> buildJsonObject {
                put("id", q.id); put("time", q.time); q.loopEnd?.let { put("loopEnd", it) }; put("comment", q.comment)
            } }))
        }
        bpm?.let { put("bpm", it) }; firstBeat?.let { put("firstBeat", it) }
        title?.let { put("title", it) }; artist?.let { put("artist", it) }; album?.let { put("album", it) }
        genre?.let { put("genre", it) }; comment?.let { put("comment", it) }; rating?.let { put("rating", it) }
    }

    companion object {
        private fun JsonObject.d(k: String) = (this[k] as? JsonPrimitive)?.doubleOrNull
        private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun parse(o: JsonObject) = USBTrackEdit(
            cue = o.d("cue"),
            hot = (o["hot"] as? JsonArray)?.map { (it as? JsonPrimitive)?.doubleOrNull },
            memory = (o["memory"] as? JsonArray)?.mapNotNull { e ->
                val q = e as? JsonObject ?: return@mapNotNull null
                USBMemoryCue(q.d("time") ?: return@mapNotNull null, q.d("loopEnd"), q.s("comment") ?: "", q.s("id") ?: UUID.randomUUID().toString().uppercase())
            },
            bpm = o.d("bpm"), firstBeat = o.d("firstBeat"), title = o.s("title"), artist = o.s("artist"), album = o.s("album"),
            genre = o.s("genre"), comment = o.s("comment"), rating = (o["rating"] as? JsonPrimitive)?.intOrNull,
        )
        fun encodeAll(m: Map<String, USBTrackEdit>): String = JsonObject(m.mapValues { it.value.json() }).toString()
        fun parseAll(text: String?): Map<String, USBTrackEdit> = try {
            (text?.let { Json.parseToJsonElement(it) } as? JsonObject)?.mapNotNull { (k, v) -> (v as? JsonObject)?.let { k to parse(it) } }?.toMap()
        } catch (_: Exception) { null } ?: emptyMap()
    }
}

/** the playlist tree being edited: one node per playlist, both libraries' ids where they exist */
data class USBNode(
    val id: String,                     // stable within the session
    val name: String,
    val folder: Boolean,
    val parent: String?,                // null = top level
    val tracks: List<String>,           // track keys
    val pdbId: Long? = null, val olId: Long? = null,
)

class USBEdits {
    var nodes: List<USBNode> = emptyList()
    var originalNodes: List<USBNode> = emptyList(); private set
    var edits: Map<String, USBTrackEdit> = emptyMap()
    val changeLog = ArrayList<String>()
    /** rekordbox's own memory cues per track (read when a track is loaded) */
    val rbMemory = HashMap<String, List<USBMemoryCue>>()
    var syncPending = false
    val playlistsChanged get() = nodes != originalNodes
    val editedTracks get() = edits.filter { !it.value.isEmpty }.keys.sorted()

    companion object {
        const val SEP = "\u001f"
        fun nodes(lib: USBLibrary): List<USBNode> = lib.playlists.map { p ->
            USBNode(p.id, p.name, p.folder, if (p.treePath.size > 1) p.treePath.dropLast(1).joinToString(SEP) else null, p.tracks, p.pdbId, p.olId)
        }
        fun treeOrder(ns: List<USBNode>): List<USBNode> {
            val out = ArrayList<USBNode>()
            fun walk(p: String?) { for (n in ns) if (n.parent == p) { out.add(n); if (n.folder) walk(n.id) } }
            walk(null)
            return out
        }
    }

    /** a fresh read of the stick: the original tree, and the working one unless `keepNodes` */
    fun loaded(lib: USBLibrary, keepNodes: Boolean) {
        val fresh = nodes(lib)
        originalNodes = fresh
        if (!keepNodes || nodes.isEmpty()) nodes = fresh
    }

    fun log(s: String) { changeLog.add(s) }
    fun children(parent: String?) = nodes.filter { it.parent == parent }
    fun node(id: String) = nodes.firstOrNull { it.id == id }
    private fun at(id: String, f: (USBNode) -> USBNode): USBNode? {
        val k = nodes.indexOfFirst { it.id == id }
        if (k < 0) return null
        val n = f(nodes[k]); nodes = nodes.toMutableList().also { it[k] = n }; return n
    }

    fun newNode(name: String, folder: Boolean, parent: String? = null): String {
        val id = "new-" + UUID.randomUUID().toString().uppercase().take(8)
        val atIx = nodes.indexOfLast { it.parent == parent }.let { if (it >= 0) it + 1 else nodes.size }
        nodes = nodes.toMutableList().also { it.add(atIx, USBNode(id, name, folder, parent, emptyList())) }
        log("New ${if (folder) "folder" else "playlist"} \"$name\"")
        return id
    }
    fun rename(id: String, name: String) {
        if (name.isEmpty()) return
        val old = node(id)?.name ?: return
        at(id) { it.copy(name = name) }; log("Rename \"$old\" → \"$name\"")
    }
    /** returns the ids removed */
    fun delete(id: String): Set<String> {
        val kill = mutableSetOf(id); var grew = true
        while (grew) { grew = false; for (n in nodes) if (n.parent != null && n.parent in kill && n.id !in kill) { kill.add(n.id); grew = true } }
        log("Delete \"${node(id)?.name ?: ""}\"" + if (kill.size > 1) " and what's in it" else "")
        nodes = nodes.filter { it.id !in kill }
        return kill
    }
    fun moveTracks(id: String, from: Set<Int>, to: Int) {
        val n = at(id) { p ->
            val moving = p.tracks.filterIndexed { i, _ -> i in from }
            val rest = p.tracks.filterIndexed { i, _ -> i !in from }.toMutableList()
            rest.addAll((to - from.count { it < to }).coerceIn(0, rest.size), moving)
            p.copy(tracks = rest)
        } ?: return
        log("Reorder \"${n.name}\"")
    }
    fun removeTracks(id: String, at: Set<Int>) {
        val n = at(id) { p -> p.copy(tracks = p.tracks.filterIndexed { i, _ -> i !in at }) } ?: return
        log("Remove ${at.size} from \"${n.name}\"")
    }
    fun add(keys: List<String>, to: String) {
        if (node(to)?.folder != false) return
        val n = at(to) { it.copy(tracks = it.tracks + keys) } ?: return
        log("Add ${keys.size} to \"${n.name}\"")
    }
    /** siblings in a new order */
    fun moveNodes(parent: String?, from: Set<Int>, to: Int) {
        val sib = children(parent)
        val moving = sib.filterIndexed { i, _ -> i in from }
        val rest = sib.filterIndexed { i, _ -> i !in from }.toMutableList()
        rest.addAll((to - from.count { it < to }).coerceIn(0, rest.size), moving)
        nodes = treeOrder(nodes.filter { it.parent != parent } + rest)
        log("Reorder playlists")
    }
    fun removeEverywhere(key: String, name: String) {
        var n = 0
        nodes = nodes.map { p -> if (key in p.tracks) { n++; p.copy(tracks = p.tracks.filter { it != key }) } else p }
        if (n > 0) log("Take $name out of $n playlist${if (n == 1) "" else "s"}")
    }
    fun markAllForSync() { syncPending = true; log("Make both libraries' playlists the same") }
    fun discardPlaylistChanges() { nodes = originalNodes; syncPending = false; changeLog.removeAll { !it.startsWith("Edit ") } }
    fun playlistsSaved() { changeLog.removeAll { !it.startsWith("Edit ") }; syncPending = false }

    // ---- track edits ----
    fun edit(key: String, change: (USBTrackEdit) -> USBTrackEdit) {
        val e = change(edits[key] ?: USBTrackEdit())
        edits = if (e.isEmpty) edits - key else edits + (key to e)
    }
    fun memoryCues(key: String): List<USBMemoryCue> = edits[key]?.memory ?: rbMemory[key] ?: emptyList()
    fun addMemory(key: String, name: String, time: Double, loopEnd: Double? = null) {
        val m = (memoryCues(key) + USBMemoryCue(time, loopEnd)).sortedBy { it.time }
        edit(key) { it.copy(memory = m) }
        log("Edit $name: ${if (loopEnd == null) "memory cue" else "saved loop"} at ${String.format(java.util.Locale.US, "%.2f", time)} s")
    }
    fun deleteMemory(key: String, id: String) { val m = memoryCues(key).filter { it.id != id }; edit(key) { it.copy(memory = m) } }
    fun trackEditsSaved(written: List<String>) { edits = edits - written.toSet(); changeLog.removeAll { it.startsWith("Edit ") } }

    fun trackChanges(): Map<String, USBTrackChanges> = edits.filter { !it.value.isEmpty }.mapValues { it.value.toChanges() }

    /** null when the edits can be written; otherwise why not */
    fun trackEditBlocker(lib: USBLibrary?, gate: USBWriteGate): String? {
        if (lib == null) return "No stick open"
        val needs = trackChanges().values.flatMap { it.kinds }.toSet()
        val locked = USBWriteKind.entries.filter { it in needs && !gate.allowed(it) }
        if (locked.isEmpty()) return null
        val names = mapOf(USBWriteKind.CUES to "cues", USBWriteKind.BEATGRID to "beat grids", USBWriteKind.METADATA to "track info")
        return "Writing ${locked.mapNotNull { names[it] }.joinToString(", ")} isn't proven on hardware yet, so it's locked (Proving Ground in settings). Your edits are kept as staged changes."
    }

    // ---- the tree as each library's rows ----

    /** Device Library rows (null + why, if a track isn't in that library) */
    fun pdbNodes(lib: USBLibrary): Pair<List<PDBPlaylist>?, String?> {
        val p = lib.pdb ?: return null to "no Device Library"
        var next = (p.playlists.maxOfOrNull { it.id } ?: 0) + 1
        val idOf = HashMap<String, Long>()
        for (n in nodes) idOf[n.id] = n.pdbId ?: next++
        val out = ArrayList<PDBPlaylist>()
        for (n in treeOrder(nodes)) {
            val tr = ArrayList<Long>()
            for (k in n.tracks) tr.add(lib.track(k)?.pdbId ?: return null to "${lib.track(k)?.fileName ?: k} isn't in the Device Library")
            val unk = p.playlists.firstOrNull { it.id == n.pdbId }?.unk ?: 0
            out.add(PDBPlaylist(idOf[n.id]!!, n.parent?.let { idOf[it] } ?: 0, unk = unk, folder = n.folder, name = n.name, tracks = if (n.folder) emptyList() else tr))
        }
        return out to null
    }
    /** OneLibrary rows (null + why) */
    fun olNodes(lib: USBLibrary): Pair<List<OLPlaylist>?, String?> {
        val o = lib.one ?: return null to "no OneLibrary"
        var next = (o.playlists.maxOfOrNull { it.id } ?: 0) + 1
        val idOf = HashMap<String, Long>()
        for (n in nodes) idOf[n.id] = n.olId ?: next++
        val out = ArrayList<OLPlaylist>()
        for (n in treeOrder(nodes)) {
            val tr = ArrayList<Long>()
            for (k in n.tracks) tr.add(lib.track(k)?.olId ?: return null to "${lib.track(k)?.fileName ?: k} isn't in OneLibrary")
            val attr = o.playlists.firstOrNull { it.id == n.olId }?.attribute ?: if (n.folder) 1 else 0
            out.add(OLPlaylist(idOf[n.id]!!, n.parent?.let { idOf[it] } ?: 0, 0, n.folder, n.name, if (n.folder) emptyList() else tr, attr))
        }
        return out to null
    }

    /** rekordbox XML with your edits and the playlists as they are now (rekordbox shows it beside its collection) */
    fun exportXML(lib: USBLibrary, base: String): String {
        val used = nodes.flatMap { it.tracks }.toSet() + edits.keys
        val ts = lib.tracks.filter { it.key in used }.map { t ->
            val e = edits[t.key] ?: USBTrackEdit()
            RekordboxXML.ExportTrack(t.key, e.title ?: t.title, e.artist ?: t.artist, t.fileName, t.path.trimStart('/'), t.fileSize.toInt(),
                t.duration, e.bpm ?: t.bpm, e.firstBeat, RekordboxANLZ.keyIndex(t.keyName), e.cue, e.hot ?: emptyList())
        }
        val order = HashMap<String, Int>()
        val ls = nodes.map { n ->
            val o = order[n.parent ?: ""] ?: 0; order[n.parent ?: ""] = o + 1
            RekordboxXML.ExportList(n.id, n.name, n.folder, n.parent, o, n.tracks)
        }
        return RekordboxXML.export(ts, ls, base)
    }

    /** the tracks to sort out in rekordbox, as CSV */
    fun fixListCSV(lib: USBLibrary, stickName: String, fixList: List<String>, issues: List<ScanIssue>): String {
        val lines = arrayListOf("# Cratebox USB fix list for $stickName: sort these out in rekordbox, then export again", "path,title,artist,why")
        for (k in fixList) {
            val t = lib.track(k) ?: continue
            val why = issues.filter { it.trackKey == k }.joinToString("; ") { it.title.substringBefore(':') }
            lines.add(listOf(t.path, t.title, t.artist, why).joinToString(",") { "\"" + it.replace("\"", "\"\"") + "\"" })
        }
        return lines.joinToString("\n")
    }
}
