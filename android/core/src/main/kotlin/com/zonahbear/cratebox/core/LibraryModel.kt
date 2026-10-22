// The library's saved state, as plain data (TrackRecord / MusicFolder from Library.swift, Playlist / Playlists
// from Playlists.swift). JSON keys are the iOS app's Codable names, so the files read the same on both.
// The app layer does the file I/O; this is the shape and the playlist rules, with tests.
package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.UUID

private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.dbl(k: String) = (this[k] as? JsonPrimitive)?.doubleOrNull
private fun JsonObject.lng(k: String) = (this[k] as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }
private fun JsonObject.bool(k: String) = (this[k] as? JsonPrimitive)?.booleanOrNull
private fun num(v: Double?): JsonElement = if (v == null || !v.isFinite()) JsonNull else JsonPrimitive(v)
private fun parseArray(text: String?): JsonArray? = try { text?.let { Json.parseToJsonElement(it) as? JsonArray } } catch (_: Exception) { null }

data class TrackRecord(
    val id: String,
    val folder: String,          // the folder's key (or a stick's id)
    val rel: String,             // path inside the folder
    var title: String, var artist: String,
    val size: Long, val mtime: Double,
    var bpm: Double? = null, var firstBeat: Double? = null, var key: Int = -1, var duration: Double = 0.0,
    var phrases: List<Phrase> = emptyList(),
    var gridManual: Boolean = false, var autoBpm: Double? = null, var autoFirst: Double? = null,
    var ver: Int = 0,
) {
    fun json(): JsonObject = buildJsonObject {
        put("id", id); put("folder", folder); put("rel", rel); put("title", title); put("artist", artist)
        put("size", size); put("mtime", mtime)
        put("bpm", num(bpm)); put("firstBeat", num(firstBeat)); put("key", key); put("duration", duration)
        put("phrases", buildJsonArray { for (p in phrases) add(buildJsonObject { put("start", p.start); put("bars", p.bars); put("label", p.label) }) })
        put("gridManual", gridManual); put("autoBpm", num(autoBpm)); put("autoFirst", num(autoFirst)); put("ver", ver)
    }

    companion object {
        fun parse(o: JsonObject): TrackRecord? {
            val id = o.str("id") ?: return null
            val phrases = (o["phrases"] as? JsonArray)?.mapNotNull { e ->
                val p = e as? JsonObject ?: return@mapNotNull null
                Phrase(p.dbl("start") ?: return@mapNotNull null, p.lng("bars")?.toInt() ?: return@mapNotNull null, p.str("label") ?: "")
            } ?: emptyList()
            return TrackRecord(id, o.str("folder") ?: "", o.str("rel") ?: "", o.str("title") ?: "", o.str("artist") ?: "",
                o.lng("size") ?: 0, o.dbl("mtime") ?: 0.0, o.dbl("bpm"), o.dbl("firstBeat"), o.lng("key")?.toInt() ?: -1,
                o.dbl("duration") ?: 0.0, phrases, o.bool("gridManual") ?: false, o.dbl("autoBpm"), o.dbl("autoFirst"), o.lng("ver")?.toInt() ?: 0)
        }
        fun encodeAll(list: List<TrackRecord>): String = JsonArray(list.map { it.json() }).toString()
        fun parseAll(text: String?): List<TrackRecord> = parseArray(text)?.mapNotNull { (it as? JsonObject)?.let(::parse) } ?: emptyList()

        /** a new file's record: "Artist - Title.mp3" gives both, otherwise the name is the title */
        fun fresh(folder: String, rel: String, size: Long, mtime: Double): TrackRecord {
            val stem = rel.substringAfterLast('/').let { if (it.contains('.')) it.substringBeforeLast('.') else it }
            val parts = stem.split(" - ")
            return TrackRecord("$folder|$rel|$size", folder, rel,
                if (parts.size > 1) parts.drop(1).joinToString(" - ") else stem, if (parts.size > 1) parts[0] else "", size, mtime)
        }
        val AUDIO_EXT = setOf("mp3", "wav", "wave", "flac", "m4a", "aac", "aif", "aiff", "caf", "mp4", "alac", "ogg", "opus")
    }
}

/** a music folder the user picked; `uri`: Android's tree URI (iOS keeps a bookmark there instead) */
data class MusicFolder(val id: String, val name: String, val uri: String, val device: Boolean) {
    fun json() = buildJsonObject { put("id", id); put("name", name); put("uri", uri); put("device", device) }
    companion object {
        fun encodeAll(list: List<MusicFolder>): String = JsonArray(list.map { it.json() }).toString()
        fun parseAll(text: String?): List<MusicFolder> = parseArray(text)?.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            MusicFolder(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "", o.str("uri") ?: return@mapNotNull null, o.bool("device") ?: false)
        } ?: emptyList()
    }
}

/** Your own playlists and folders. A playlist remembers each track's title and file name, so it can show (and later
 *  re-find) tracks whose folder isn't connected right now. */
data class Playlist(
    val id: String, val name: String, val folder: Boolean, val parent: String?, val order: Int,
    val items: List<String>, val meta: Map<String, Map<String, String>>,     // track id → title, artist, file
) {
    fun json() = buildJsonObject {
        put("id", id); put("name", name); put("folder", folder); put("parent", parent?.let(::JsonPrimitive) ?: JsonNull); put("order", order)
        put("items", JsonArray(items.map(::JsonPrimitive)))
        put("meta", JsonObject(meta.mapValues { (_, m) -> JsonObject(m.mapValues { JsonPrimitive(it.value) }) }))
    }
    companion object {
        fun parse(o: JsonObject): Playlist? {
            val id = o.str("id") ?: return null
            return Playlist(id, o.str("name") ?: "", o.bool("folder") ?: false, o.str("parent"), o.lng("order")?.toInt() ?: 0,
                (o["items"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList(),
                (o["meta"] as? JsonObject)?.mapValues { (_, v) -> (v as? JsonObject)?.mapValues { (it.value as? JsonPrimitive)?.content ?: "" } ?: emptyMap() } ?: emptyMap())
        }
    }
}

class Playlists(text: String?, private val store: (String) -> Unit) {
    var lists: List<Playlist> = parseArray(text)?.mapNotNull { (it as? JsonObject)?.let(Playlist::parse) } ?: emptyList(); private set

    private fun save() = store(JsonArray(lists.map { it.json() }).toString())
    fun get(id: String) = lists.firstOrNull { it.id == id }
    fun children(parent: String?) = lists.filter { it.parent == parent }.sortedWith(compareBy({ it.order }, { it.name }))
    fun nextName(base: String): String { var n = 1; while (lists.any { it.name == "$base $n" }) n++; return "$base $n" }

    fun new(name: String, folder: Boolean = false, parent: String? = null): Playlist {
        val p = Playlist("pl" + UUID.randomUUID().toString().uppercase().take(8), name, folder, parent, children(parent).size, emptyList(), emptyMap())
        lists = lists + p; save(); return p
    }
    private fun update(id: String, f: (Playlist) -> Playlist) {
        val k = lists.indexOfFirst { it.id == id }
        if (k < 0) return
        lists = lists.toMutableList().also { it[k] = f(it[k]) }; save()
    }
    fun rename(id: String, name: String) = update(id) { it.copy(name = name) }
    /** tracks as (id, title, artist, file name) */
    fun add(tracks: List<List<String>>, to: String, at: Int? = null) = update(to) { p ->
        if (p.folder) return@update p
        val meta = p.meta.toMutableMap()
        for (t in tracks) meta[t[0]] = mapOf("title" to t[1], "artist" to t[2], "file" to t[3])
        val items = p.items.toMutableList()
        items.addAll(minOf(at ?: items.size, items.size), tracks.map { it[0] })
        p.copy(items = items, meta = meta)
    }
    fun remove(at: Set<Int>, from: String) = update(from) { p -> p.copy(items = p.items.filterIndexed { i, _ -> i !in at }) }
    /** SwiftUI's move(fromOffsets:toOffset:): `to` counts positions in the list before the move */
    fun move(from: Set<Int>, to: Int, inList: String) = update(inList) { p ->
        val moving = p.items.filterIndexed { i, _ -> i in from }
        val rest = p.items.filterIndexed { i, _ -> i !in from }.toMutableList()
        val at = to - from.count { it < to }
        rest.addAll(at.coerceIn(0, rest.size), moving)
        p.copy(items = rest)
    }
    fun moveList(id: String, into: String?) {
        var x = into
        while (x != null) { if (x == id) return; x = get(x)?.parent }          // no folder into itself
        update(id) { it.copy(parent = into, order = children(into).size) }
    }
    fun delete(id: String) {
        val kill = mutableSetOf(id)
        var grew = true
        while (grew) { grew = false; for (x in lists) if (x.parent != null && x.parent in kill && x.id !in kill) { kill.add(x.id); grew = true } }
        lists = lists.filter { it.id !in kill }; save()
    }
    fun path(p: Playlist): String {
        val parts = mutableListOf(p.name); var x = p.parent
        while (x != null) { val q = get(x) ?: break; parts.add(0, q.name); x = q.parent }
        return parts.joinToString(" / ")
    }
}
