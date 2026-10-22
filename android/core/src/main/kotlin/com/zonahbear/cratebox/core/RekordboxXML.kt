// rekordbox XML (File → Export Collection in xml format): reading it (RB.parseXml in tools/rekordbox.js) and
// writing one (exportXml in cratebox.html), so playlists, grids, keys and cues go both ways. A port of
// RekordboxXML.swift; the reader is a SAX parser with DTDs and external entities off.
package com.zonahbear.cratebox.core

import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import javax.xml.XMLConstants
import javax.xml.parsers.SAXParserFactory

data class XMLGrid(val bpm: Double, val firstBeat: Double, val beat: Int)
data class XMLMark(val num: Int, val start: Double, val end: Double?, val type: Int, val name: String)
data class XMLTrack(
    var id: String = "", var title: String = "", var artist: String = "", var album: String = "", var genre: String = "", var key: String = "",
    var bpm: Double = 0.0, var duration: Double = 0.0, var size: Int = 0, var location: String = "", var filename: String = "",
    var grid: XMLGrid? = null, val marks: MutableList<XMLMark> = ArrayList(),
)
data class XMLNodeEntry(val name: String, val folder: Boolean, val parent: Int?, val tracks: MutableList<String>, val key: Int)
data class XMLLibrary(val tracks: Map<String, XMLTrack>, val order: List<String>, val playlists: List<XMLNodeEntry>)

object RekordboxXML {
    class NotRekordbox : Exception("not a rekordbox XML file")

    /** %XX → UTF-8, '+' left alone (Foundation's removingPercentEncoding); null when malformed */
    internal fun percentDecode(s: String): String? {
        if (!s.contains('%')) return s
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        val bytes = s.toByteArray(Charsets.UTF_8)
        while (i < bytes.size) {
            val c = bytes[i]
            if (c == '%'.code.toByte()) {
                if (i + 2 >= bytes.size) return null
                val h = String(bytes, i + 1, 2, Charsets.US_ASCII).toIntOrNull(16) ?: return null
                out.write(h); i += 3
            } else { out.write(c.toInt()); i += 1 }
        }
        val dec = Charsets.UTF_8.newDecoder()
        return try { dec.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString() } catch (_: Exception) { null }
    }

    private class P : DefaultHandler() {
        val tracks = HashMap<String, XMLTrack>(); val order = ArrayList<String>()
        val lists = ArrayList<XMLNodeEntry>()
        var inCollection = false; var inPlaylists = false; var sawRoot = false; var seenDJ = false
        var cur: XMLTrack? = null
        val stack = ArrayList<Int?>()                           // playlist node keys (null = ROOT)

        override fun startElement(uri: String?, localName: String?, el: String, a: Attributes) {
            fun at(n: String): String? = a.getValue(n)
            val c = cur
            when {
                el == "DJ_PLAYLISTS" -> seenDJ = true
                el == "COLLECTION" -> inCollection = true
                el == "PLAYLISTS" -> inPlaylists = true
                el == "TRACK" && inCollection && c == null -> {
                    val t = XMLTrack()
                    t.id = at("TrackID") ?: ""; t.title = at("Name") ?: ""; t.artist = at("Artist") ?: ""; t.album = at("Album") ?: ""; t.genre = at("Genre") ?: ""; t.key = at("Tonality") ?: ""
                    t.bpm = at("AverageBpm")?.toDoubleOrNull() ?: 0.0; t.duration = at("TotalTime")?.toDoubleOrNull() ?: 0.0; t.size = at("Size")?.toIntOrNull() ?: 0
                    var loc = at("Location") ?: ""
                    if (loc.startsWith("file://localhost")) loc = loc.removePrefix("file://localhost")
                    loc = percentDecode(loc) ?: loc
                    t.location = loc
                    t.filename = loc.split('/', '\\').lastOrNull { it.isNotEmpty() } ?: loc
                    cur = t
                }
                el == "TEMPO" && c != null && c.grid == null ->
                    c.grid = XMLGrid(at("Bpm")?.toDoubleOrNull() ?: 0.0, at("Inizio")?.toDoubleOrNull() ?: 0.0, (at("Battito") ?: "1").toIntOrNull() ?: 1)
                el == "POSITION_MARK" && c != null ->
                    c.marks.add(XMLMark(at("Num")?.toIntOrNull() ?: -1, at("Start")?.toDoubleOrNull() ?: 0.0, at("End")?.toDoubleOrNull(),
                        (at("Type") ?: "0").toIntOrNull() ?: 0, at("Name") ?: ""))
                el == "NODE" && inPlaylists -> {
                    if (!sawRoot) { sawRoot = true; stack.add(null); return }
                    val e = XMLNodeEntry(at("Name") ?: "", at("Type") == "0", stack.lastOrNull(), ArrayList(), lists.size)
                    lists.add(e)
                    stack.add(e.key)
                }
                el == "TRACK" && inPlaylists -> {
                    val k = stack.lastOrNull()
                    val key = at("Key")
                    if (k != null && !lists[k].folder && key != null) lists[k].tracks.add(key)
                }
            }
        }

        override fun endElement(uri: String?, localName: String?, el: String) {
            when {
                el == "COLLECTION" -> inCollection = false
                el == "PLAYLISTS" -> inPlaylists = false
                el == "TRACK" && inCollection -> { cur?.let { tracks[it.id] = it; order.add(it.id) }; cur = null }
                el == "NODE" && inPlaylists -> if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
            }
        }
    }

    fun parse(data: ByteArray): XMLLibrary {
        val p = P()
        try {
            val f = SAXParserFactory.newInstance()
            f.isNamespaceAware = false
            runCatching { f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { f.setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { f.setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            runCatching { f.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true) }
            f.newSAXParser().parse(ByteArrayInputStream(data), p)
        } catch (e: Exception) { throw NotRekordbox() }
        if (!p.seenDJ) throw NotRekordbox()
        return XMLLibrary(p.tracks, p.order, p.lists)
    }

    // ---- writing ----
    data class ExportTrack(val id: String, val title: String, val artist: String, val file: String, val rel: String, val size: Int,
                           val duration: Double, val bpm: Double, val firstBeat: Double?, val key: Int, val cue: Double?, val hot: List<Double?>)
    data class ExportList(val id: String, val name: String, val folder: Boolean, val parent: String?, val order: Int, val items: List<String>)

    private val keyXML = listOf("C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B")
    fun keyName(k: Int): String = if (k < 0) "" else keyXML[k % 12] + if (k >= 12) "m" else ""
    internal fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    /** CharacterSet.urlPathAllowed without # and ? */
    private const val PATH_ALLOWED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!$&'()*+,-./:;=@_~"
    internal fun pathEncode(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            if (c < 0x80 && PATH_ALLOWED.indexOf(c.toChar()) >= 0) sb.append(c.toChar()) else sb.append(fmt("%%%02X", c))
        }
        return sb.toString()
    }

    /** root: where the music folder lives on the computer rekordbox runs on (rekordbox needs full paths) */
    fun export(tracks: List<ExportTrack>, lists: List<ExportList>, root: String): String {
        val tid = HashMap<String, Int>()
        for ((i, t) in tracks.withIndex()) tid[t.id] = i + 1
        val base = root.replace("\\", "/")
        fun loc(t: ExportTrack): String {
            val rel = t.rel.split("/").filter { it.isNotEmpty() }.drop(1).joinToString("/")
            val full = if (base.isEmpty()) t.rel else "$base/${if (rel.isEmpty()) t.rel else rel}"
            return "file://localhost/" + pathEncode(full.dropWhile { it == '/' })
        }
        val out = arrayListOf("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<DJ_PLAYLISTS Version=\"1.0.0\">",
            "  <PRODUCT Name=\"Cratebox\" Version=\"1\" Company=\"Cratebox\"/>", "  <COLLECTION Entries=\"${tracks.size}\">")
        for (t in tracks) {
            val name = t.file.substringAfterLast('/')
            val ext = if (name.contains('.') && !name.startsWith('.')) name.substringAfterLast('.').uppercase() else ""
            val attrs = listOf("TrackID" to "${tid[t.id]}", "Name" to t.title, "Artist" to t.artist, "Kind" to "$ext File", "Size" to "${t.size}",
                "TotalTime" to "${jsRound(t.duration).toInt()}", "AverageBpm" to fmt("%.2f", t.bpm), "Tonality" to keyName(t.key), "Location" to loc(t))
            out.add("    <TRACK " + attrs.joinToString(" ") { "${it.first}=\"${esc(it.second)}\"" } + ">")
            if (t.bpm > 0 && t.firstBeat != null) out.add(fmt("      <TEMPO Inizio=\"%.3f\" Bpm=\"%.2f\" Metro=\"4/4\" Battito=\"1\"/>", t.firstBeat, t.bpm))
            t.cue?.let { out.add(fmt("      <POSITION_MARK Name=\"\" Type=\"0\" Start=\"%.3f\" Num=\"-1\"/>", it)) }
            for ((i, h) in t.hot.withIndex()) if (h != null) out.add(fmt("      <POSITION_MARK Name=\"\" Type=\"0\" Start=\"%.3f\" Num=\"%d\"/>", h, i))
            out.add("    </TRACK>")
        }
        out += listOf("  </COLLECTION>", "  <PLAYLISTS>")
        fun node(parent: String?, ind: String) {
            for (p in lists.filter { it.parent == parent }.sortedBy { it.order }) {
                if (p.folder) {
                    out.add("$ind<NODE Type=\"0\" Name=\"${esc(p.name)}\" Count=\"${lists.count { it.parent == p.id }}\">")
                    node(p.id, "$ind  ")
                    out.add("$ind</NODE>")
                } else {
                    val items = p.items.filter { tid[it] != null }
                    out.add("$ind<NODE Name=\"${esc(p.name)}\" Type=\"1\" KeyType=\"0\" Entries=\"${items.size}\">")
                    for (id in items) out.add("$ind  <TRACK Key=\"${tid[id]}\"/>")
                    out.add("$ind</NODE>")
                }
            }
        }
        out.add("    <NODE Type=\"0\" Name=\"ROOT\" Count=\"${lists.count { it.parent == null }}\">")
        node(null, "      ")
        out += listOf("    </NODE>", "  </PLAYLISTS>", "</DJ_PLAYLISTS>")
        return out.joinToString("\n")
    }
}
