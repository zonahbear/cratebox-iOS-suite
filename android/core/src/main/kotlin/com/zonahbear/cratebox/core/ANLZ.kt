// rekordbox analysis files on a stick (ANLZ .DAT / .EXT): beat grid, hot and memory cues, rekordbox's own
// phrase analysis, and writing cues and grids back. A port of ANLZ.swift and ANLZWrite.swift (which port
// RB.parseAnlz / gridFromBeats / phrasesFrom in tools/rekordbox.js). Big-endian. UInt32 times are Longs.
//
// The writer only replaces tags rekordbox already put in the file, leaves every other tag byte for byte as it
// was, and reads its own output back before returning it. What hasn't been confirmed on a player (and is why
// these writes stay locked behind USBWriteGate until they are): see the top of ANLZWrite.swift.
package com.zonahbear.cratebox.core

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

data class ANLZBeat(val n: Int, val bpm: Double, val ms: Long)
data class ANLZCue(val hot: Int, val ms: Long, val loopMs: Long?)
data class ANLZPhraseEntry(val beat: Int, val kind: Int)
data class ANLZPhrases(val mood: Int, val endBeat: Int, val list: List<ANLZPhraseEntry>)
data class ANLZ(
    val beats: List<ANLZBeat> = emptyList(), val hot: List<ANLZCue> = emptyList(), val memory: List<ANLZCue> = emptyList(),
    val phrases: ANLZPhrases? = null,
)

/** one cue as written to the analysis files. hot: 0 = memory cue, 1...8 = hot cue A-H. */
data class ANLZCuePoint(
    val hot: Int, val ms: Long, val loopMs: Long? = null, val comment: String = "",
    /** PCP2's colour bytes: memory cues use colorId (the colours table), hot cues colorCode + RGB. null = none. */
    val colorId: Int? = null, val color: ANLZHotCueColor? = null,
)
data class ANLZHotCueColor(val code: Int, val r: Int, val g: Int, val b: Int)

class ANLZWriteError(message: String) : Exception(message) {
    companion object {
        fun notANLZ() = ANLZWriteError("not a rekordbox analysis file")
        fun missingTag(t: String) = ANLZWriteError("the analysis file has no $t tag (re-analyse the track in rekordbox and export again)")
        fun badCue(s: String) = ANLZWriteError("cue: $s")
        fun badGrid(s: String) = ANLZWriteError("beat grid: $s")
        fun readBack(s: String) = ANLZWriteError("analysis file: $s")
    }
}

object RekordboxANLZ {
    private fun tag(s: String): Long = s.toByteArray(Charsets.UTF_8).fold(0L) { a, c -> (a shl 8) or (c.toLong() and 0xff) }
    private fun bu32(b: ByteArray, o: Int): Long = if (o >= 0 && o + 4 <= b.size)
        ((b[o].toLong() and 0xff) shl 24) or ((b[o + 1].toLong() and 0xff) shl 16) or ((b[o + 2].toLong() and 0xff) shl 8) or (b[o + 3].toLong() and 0xff) else 0
    private fun bu16(b: ByteArray, o: Int): Int = if (o >= 0 && o + 2 <= b.size) ((b[o].toInt() and 0xff) shl 8) or (b[o + 1].toInt() and 0xff) else 0
    private fun u8(b: ByteArray, o: Int) = b[o].toInt() and 0xff

    fun parse(b: ByteArray): ANLZ {
        val beats = ArrayList<ANLZBeat>(); var hot = ArrayList<ANLZCue>(); var memory = ArrayList<ANLZCue>()
        var phrases: ANLZPhrases? = null
        if (b.size < 12 || bu32(b, 0) != tag("PMAI")) return ANLZ()
        var pos = bu32(b, 4).toInt()
        val cues2Hot = ArrayList<ANLZCue>(); val cues2Mem = ArrayList<ANLZCue>()
        while (pos + 12 <= b.size) {
            val four = bu32(b, pos); val lenTag = bu32(b, pos + 8).toInt(); val s = pos + 12
            if (lenTag < 12) break
            if (four == tag("PQTZ")) {
                val n = bu32(b, s + 8).toInt()
                for (i in 0 until n) { val e = s + 12 + i * 8; if (e + 8 > b.size) break; beats.add(ANLZBeat(bu16(b, e), bu16(b, e + 2) / 100.0, bu32(b, e + 4))) }
            } else if (four == tag("PCOB") || four == tag("PCO2")) {
                val ob = four == tag("PCOB")
                val n = bu16(b, s + if (ob) 6 else 4)
                var e = s + if (ob) 12 else 8
                var i = 0
                while (i < n && e + 12 <= pos + lenTag && e + 40 <= b.size) {
                    val lenEntry = bu32(b, e + 8).toInt(); val h = bu32(b, e + 12).toInt()
                    val typ = u8(b, e + if (ob) 28 else 16)
                    val ms = bu32(b, e + if (ob) 32 else 20); val loopMs = bu32(b, e + if (ob) 36 else 24)
                    val cue = ANLZCue(h, ms, if (typ == 2) loopMs else null)
                    if (ob) { if (h != 0) hot.add(cue) else memory.add(cue) }
                    else { if (h != 0) cues2Hot.add(cue) else cues2Mem.add(cue) }
                    e += if (lenEntry != 0) lenEntry else 56; i += 1
                }
            } else if (four == tag("PSSI")) {
                val lenEntries = bu16(b, s + 4); val bodyLen = lenTag - 12 - 6
                if (s + 6 + bodyLen <= b.size && bodyLen >= 14) {
                    val body = b.copyOfRange(s + 6, s + 6 + bodyLen)
                    val raw = bu16(body, 0)
                    if (raw > 20) {
                        val m = intArrayOf(0xcb, 0xe1, 0xee, 0xfa, 0xe5, 0xee, 0xad, 0xee, 0xe9, 0xd2, 0xe9, 0xeb, 0xe1, 0xe9, 0xf3, 0xe8, 0xe9, 0xf4, 0xe1)
                        for (i in body.indices) body[i] = (body[i].toInt() xor ((m[i % m.size] + lenEntries) and 0xff)).toByte()
                    }
                    val list = ArrayList<ANLZPhraseEntry>()
                    for (i in 0 until lenEntries) { val e = 14 + i * 24; if (e + 6 > body.size) break; list.add(ANLZPhraseEntry(bu16(body, e + 2), bu16(body, e + 4))) }
                    phrases = ANLZPhrases(bu16(body, 0), bu16(body, 8), list)
                }
            }
            pos += lenTag
        }
        // the extended (.EXT) cue lists hold all eight hot cues: prefer them when present
        if (cues2Hot.isNotEmpty()) hot = cues2Hot
        if (cues2Mem.isNotEmpty()) memory = cues2Mem
        return ANLZ(beats, hot, memory, phrases)
    }

    fun phraseLabel(mood: Int, kind: Int): String {
        if (mood == 1) return mapOf(1 to "Intro", 2 to "Build", 3 to "Breakdown", 5 to "Drop", 6 to "Outro")[kind] ?: "Groove"
        return mapOf(1 to "Intro", 8 to "Breakdown", 9 to "Drop", 10 to "Outro")[kind] ?: "Groove"
    }

    data class Grid(val bpm: Double, val firstBeat: Double)
    /** constant tempo: the most common BPM and the first downbeat */
    fun grid(beats: List<ANLZBeat>): Grid? {
        if (beats.size < 2) return null
        val count = LinkedHashMap<Double, Int>()
        for (b in beats) count[b.bpm] = (count[b.bpm] ?: 0) + 1
        val bpm = count.keys.sortedByDescending { count[it]!! }[0]
        val down = beats.firstOrNull { it.n == 1 } ?: beats[0]
        return Grid(bpm, down.ms / 1000.0)
    }

    fun phrases(a: ANLZ): List<Phrase>? {
        val p = a.phrases ?: return null
        if (p.list.isEmpty() || a.beats.isEmpty()) return null
        fun at(beat: Int) = a.beats[max(0, min(a.beats.size - 1, beat - 1))].ms / 1000.0
        return p.list.mapIndexed { i, e ->
            val next = if (i + 1 < p.list.size) p.list[i + 1].beat else (if (p.endBeat != 0) p.endBeat else e.beat + 32)
            Phrase(at(e.beat), max(1, jsRound((next - e.beat) / 4.0).toInt()), phraseLabel(p.mood, e.kind))
        }
    }

    data class Cues(val cue: Double?, val hot: List<Double?>)
    /** rekordbox hot cues A-H and the first memory cue, in seconds */
    fun cues(a: ANLZ): Cues {
        val hot = MutableList<Double?>(8) { null }
        for (q in a.hot) if (q.hot in 1..8) hot[q.hot - 1] = q.ms / 1000.0
        val mem = a.memory.minByOrNull { it.ms }
        return Cues(mem?.let { it.ms / 1000.0 }, hot)
    }

    fun keyIndex(s: String): Int {
        val t = s.trim()
        if (t.isEmpty()) return -1
        if (Regex("^(\\d{1,2})\\s*([ABab])$").matches(t)) {
            val num = t.takeWhile { it.isDigit() }.toIntOrNull() ?: 0
            val minor = t.last().uppercaseChar() == 'A'
            for (k in 0 until 24) { val c = Keys.camelot(k); if (c != null && c.num == num && (c.letter == "A") == minor) return k }
            return -1
        }
        var u = t.replace(Regex("maj(or)?$", RegexOption.IGNORE_CASE), "")
        val minorRe = Regex("(m|min|minor)$", RegexOption.IGNORE_CASE)
        val minor = minorRe.containsMatchIn(u)
        u = u.replace(minorRe, "").trim()
        val first = u.firstOrNull() ?: return -1
        var pc = mapOf("C" to 0, "D" to 2, "E" to 4, "F" to 5, "G" to 7, "A" to 9, "B" to 11)[first.toString().uppercase()] ?: return -1
        val acc = u.drop(1)
        if (acc == "#" || acc == "♯") pc += 1 else if (acc == "b" || acc == "♭") pc -= 1 else if (acc.isNotEmpty()) return -1
        return (if (minor) 12 else 0) + (pc + 12) % 12
    }

    /** rekordbox's colour detail waveform (PWV5 in the .EXT file: 150 columns a second, each a colour and a
     *  height), as Cratebox's own Waveform so the existing views draw it straight away, before any decoding.
     *  The colour is spread over the low / mid / high bands (red / green / blue in the RGB style). */
    fun waveform(ext: ByteArray, duration: Double): Waveform? {
        val b = ext
        fun u32(o: Int) = bu32(b, o).toInt()
        if (b.size < 12 || bu32(b, 0) != tag("PMAI")) return null
        var pos = u32(4)
        while (pos + 12 <= b.size) {
            val four = bu32(b, pos); val lenHeader = u32(pos + 4); val lenTag = u32(pos + 8)
            if (lenTag < 12) break
            if (four == tag("PWV5")) {
                val entryBytes = u32(pos + 12); val n = u32(pos + 16); val s = pos + lenHeader
                if (entryBytes != 2 || n <= 0 || s + 2 * n > b.size) return null
                // PWV5 is 150 columns a second; Cratebox's waveform keeps whole columns per second
                val wps = 150
                val peak = ByteArray(n); val low = ByteArray(n); val mid = ByteArray(n); val high = ByteArray(n); val rms = ByteArray(n)
                for (i in 0 until n) {
                    val v = (u8(b, s + 2 * i) shl 8) or u8(b, s + 2 * i + 1)
                    val red = v shr 13 and 7; val green = v shr 10 and 7; val blue = v shr 7 and 7; val height = v shr 2 and 0x1f
                    val h = min(255, height * 255 / 31)
                    peak[i] = h.toByte(); rms[i] = (h * 7 / 10).toByte()
                    low[i] = min(255, red * h / 7).toByte(); mid[i] = min(255, green * h / 7).toByte(); high[i] = min(255, blue * h / 7).toByte()
                }
                return Waveform(if (duration > 0) duration else n.toDouble() / wps, wps, peak, rms, low, mid, high)
            }
            pos += lenTag
        }
        return null
    }

    // ---- writing (ANLZWrite.swift) ----
    internal fun be32(v: Long) = byteArrayOf(((v shr 24) and 0xff).toByte(), ((v shr 16) and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), (v and 0xff).toByte())
    internal fun be16(v: Int) = byteArrayOf(((v shr 8) and 0xff).toByte(), (v and 0xff).toByte())
    private fun fourcc(s: String) = s.toByteArray(Charsets.UTF_8)

    class Tag(val name: String, val bytes: ByteArray)
    class Split(val header: ByteArray, val tags: List<Tag>)

    /** the file header and each tag's bytes (header included), in file order */
    internal fun split(b: ByteArray): Split {
        fun u32(o: Int) = bu32(b, o)
        if (b.size < 12 || !b.copyOfRange(0, 4).contentEquals(fourcc("PMAI"))) throw ANLZWriteError.notANLZ()
        val lenHeader = u32(4)
        if (lenHeader < 12 || lenHeader > b.size || u32(8) != b.size.toLong()) throw ANLZWriteError.notANLZ()
        val tags = ArrayList<Tag>()
        var pos = lenHeader.toInt()
        while (pos < b.size) {
            if (pos + 12 > b.size) throw ANLZWriteError.readBack("a tag is cut off at the end of the file")
            val lenTag = u32(pos + 8); val lenTagHeader = u32(pos + 4)
            if (lenTag < 12 || lenTagHeader < 12 || lenTagHeader > lenTag || pos + lenTag > b.size) throw ANLZWriteError.readBack("a tag runs past the end of the file")
            tags.add(Tag(String(b, pos, 4, Charsets.UTF_8), b.copyOfRange(pos, pos + lenTag.toInt())))
            pos += lenTag.toInt()
        }
        return Split(b.copyOfRange(0, lenHeader.toInt()), tags)
    }

    internal fun join(header: ByteArray, tags: List<ByteArray>): ByteArray {
        var out = header
        for (t in tags) out += t
        be32(out.size.toLong()).copyInto(out, 8)
        return out
    }

    private fun tag(name: String, header: ByteArray, body: ByteArray): ByteArray =
        fourcc(name) + be32(12L + header.size) + be32(12L + header.size + body.size) + header + body

    // ---- cues ----
    private fun pcpt(c: ANLZCuePoint, prev: Int?, next: Int?): ByteArray {
        var e = fourcc("PCPT") + be32(0x1c) + be32(0x38)
        e += be32(c.hot.toLong()) + be32(1) + be32(0x10000)
        e += be16(prev ?: 0xffff) + be16(next ?: 0xffff)
        e += byteArrayOf((if (c.loopMs == null) 1 else 2).toByte(), 0) + be16(1000)
        e += be32(c.ms) + be32(c.loopMs ?: 0xffffffffL)
        e += ByteArray(16)
        return e
    }

    private fun pcp2(c: ANLZCuePoint): ByteArray {
        var comment = ByteArray(0)
        for (u in c.comment) comment += be16(u.code)
        comment += byteArrayOf(0, 0)                            // NUL-terminated, also when empty (rekordcrate)
        var e = ByteArray(0)
        e += be32(c.hot.toLong())
        e += byteArrayOf((if (c.loopMs == null) 1 else 2).toByte(), 0) + be16(1000)
        e += be32(c.ms) + be32(c.loopMs ?: 0xffffffffL)
        e += byteArrayOf((c.colorId ?: 0).toByte()) + ByteArray(7)
        e += be16(0) + be16(0)                                  // loop length in beats: not quantised
        e += be32(comment.size.toLong()) + comment
        val col = c.color ?: ANLZHotCueColor(0, 0, 0, 0)
        e += byteArrayOf(col.code.toByte(), col.r.toByte(), col.g.toByte(), col.b.toByte())
        e += ByteArray(20)                                      // the five unknown words rekordcrate reads after the colour
        return fourcc("PCP2") + be32(0x10) + be32(12L + e.size) + e
    }

    /** PCOB: type, 2 unknown bytes, count, memory_count (-1 when empty, as rekordbox writes it), entries */
    private fun pcob(hot: Boolean, cues: List<ANLZCuePoint>): ByteArray {
        var body = ByteArray(0)
        for ((i, c) in cues.withIndex()) body += pcpt(c, if (i > 0) i - 1 else null, if (i + 1 < cues.size) i + 1 else null)
        return tag("PCOB", be32(if (hot) 1 else 0) + be16(0) + be16(cues.size) + be32(if (cues.isEmpty()) 0xffffffffL else cues.size.toLong()), body)
    }

    private fun pco2(hot: Boolean, cues: List<ANLZCuePoint>): ByteArray {
        var body = ByteArray(0)
        for (c in cues) body += pcp2(c)
        return tag("PCO2", be32(if (hot) 1 else 0) + be16(cues.size) + be16(0), body)
    }

    /** every cue in a file, with the comments and colours from its PCO2 entries where it has them */
    fun cuePoints(b: ByteArray): List<ANLZCuePoint> {
        val tags = try { split(b).tags } catch (_: ANLZWriteError) { return emptyList() }
        val ob = ArrayList<ANLZCuePoint>(); val o2 = ArrayList<ANLZCuePoint>()
        for (tg in tags) {
            val t = tg.bytes
            if (tg.name == "PCOB") {
                var e = 24
                for (k in 0 until bu16(t, 18)) {
                    if (e + 0x38 > t.size) break
                    ob.add(ANLZCuePoint(bu32(t, e + 12).toInt(), bu32(t, e + 32), if (u8(t, e + 28) == 2) bu32(t, e + 36) else null))
                    e += max(0x38, bu32(t, e + 8).toInt())
                }
            } else if (tg.name == "PCO2") {
                var e = 20
                for (k in 0 until bu16(t, 16)) {
                    if (e + 44 > t.size) break
                    val len = bu32(t, e + 8).toInt(); val lc = bu32(t, e + 40).toInt()
                    var c = ANLZCuePoint(bu32(t, e + 12).toInt(), bu32(t, e + 20), if (u8(t, e + 16) == 2) bu32(t, e + 24) else null)
                    c = c.copy(colorId = if (u8(t, e + 28) == 0) null else u8(t, e + 28))
                    if (lc >= 2 && e + 44 + lc <= t.size) {
                        val u = StringBuilder()
                        var i = e + 44
                        while (i + 1 < e + 44 + lc) { u.append(((u8(t, i) shl 8) or u8(t, i + 1)).toChar()); i += 2 }
                        while (u.isNotEmpty() && u.last() == '\u0000') u.setLength(u.length - 1)
                        c = c.copy(comment = u.toString())
                    }
                    if (len - lc >= 48 && e + 48 + lc <= t.size) {
                        val k2 = e + 44 + lc
                        val col = ANLZHotCueColor(u8(t, k2), u8(t, k2 + 1), u8(t, k2 + 2), u8(t, k2 + 3))
                        if (col != ANLZHotCueColor(0, 0, 0, 0)) c = c.copy(color = col)
                    }
                    o2.add(c)
                    e += max(44, len)
                }
            }
        }
        return if (o2.isEmpty()) ob else o2
    }

    private fun listType(t: ByteArray) = bu32(t, 12)

    /** Replaces the cue lists in one analysis file (.DAT or .EXT) with `cues` (hot cues A-H and memory cues /
     *  loops, any order). Both PCOB lists must already be in the file; the PCO2 lists are replaced when the file
     *  has them (the .EXT). Everything else is left as it was. */
    fun writeCues(file: ByteArray, cues: List<ANLZCuePoint>): ByteArray {
        val hotSeen = HashSet<Int>()
        for (c in cues) {
            if (c.hot < 0 || c.hot > 8) throw ANLZWriteError.badCue("hot cue ${c.hot} (only A-H)")
            if (c.hot > 0 && !hotSeen.add(c.hot)) throw ANLZWriteError.badCue("two hot cues in slot ${c.hot}")
            c.loopMs?.let { if (it <= c.ms) throw ANLZWriteError.badCue("a loop has to end after it starts") }
            if (c.ms == 0xffffffffL) throw ANLZWriteError.badCue("cue time")
        }
        val hot = cues.filter { it.hot > 0 }.sortedBy { it.hot }
        val memory = cues.filter { it.hot == 0 }.sortedBy { it.ms }
        val legacyHot = hot.filter { it.hot <= 3 }
        val sp = split(file)
        val pcobs = sp.tags.filter { it.name == "PCOB" }.map { listType(it.bytes) }
        if (!(pcobs.contains(1L) && pcobs.contains(0L))) throw ANLZWriteError.missingTag("PCOB")
        val pco2s = sp.tags.filter { it.name == "PCO2" }.map { listType(it.bytes) }
        if (pco2s.isNotEmpty() && !(pco2s.contains(1L) && pco2s.contains(0L))) throw ANLZWriteError.missingTag("PCO2 (both lists)")
        val hasExtended = pco2s.isNotEmpty()                    // a .DAT only carries A-C; D-H go in the .EXT
        val out = sp.tags.map { t ->
            when (t.name) {
                "PCOB" -> if (listType(t.bytes) == 1L) pcob(true, legacyHot) else pcob(false, memory)
                "PCO2" -> if (listType(t.bytes) == 1L) pco2(true, hot) else pco2(false, memory)
                else -> t.bytes
            }
        }
        val result = join(sp.header, out)
        // read back with the player-side parser and with our own
        val a = parse(result)
        val wantHot = if (hasExtended) hot else legacyHot
        fun key(h: Int, ms: Long, loop: Long?) = "$h|$ms|${loop?.toString() ?: "-"}"
        if (a.hot.map { key(it.hot, it.ms, it.loopMs) } != wantHot.map { key(it.hot, it.ms, it.loopMs) }) throw ANLZWriteError.readBack("hot cues didn't read back")
        if (a.memory.map { key(it.hot, it.ms, it.loopMs) } != memory.map { key(it.hot, it.ms, it.loopMs) }) throw ANLZWriteError.readBack("memory cues didn't read back")
        if (hasExtended) {
            val back = cuePoints(result).map { key(it.hot, it.ms, it.loopMs) + "|" + it.comment }.sorted()
            if (back != (hot + memory).map { key(it.hot, it.ms, it.loopMs) + "|" + it.comment }.sorted()) throw ANLZWriteError.readBack("cue comments didn't read back")
        }
        val newTags = split(result).tags
        if (newTags.map { it.name } != sp.tags.map { it.name }) throw ANLZWriteError.readBack("tag order changed")
        for ((x, y) in sp.tags.zip(newTags)) if (x.name != "PCOB" && x.name != "PCO2" && !x.bytes.contentEquals(y.bytes)) throw ANLZWriteError.readBack("${x.name} changed")
        return result
    }

    // ---- beat grid ----
    /** A constant-tempo grid: `firstBeat` (seconds) is a downbeat; beats run from the first one at or after 0 s
     *  to `duration`, numbered 1-4 within the bar, times rounded to the millisecond. */
    fun constantGrid(bpm: Double, firstBeat: Double, duration: Double): List<ANLZBeat> {
        if (!(bpm >= 20 && bpm <= 999 && bpm.isFinite())) throw ANLZWriteError.badGrid("BPM $bpm")
        if (!(duration > 0 && duration.isFinite() && firstBeat.isFinite() && firstBeat >= 0 && firstBeat < duration))
            throw ANLZWriteError.badGrid("first beat $firstBeat s in a $duration s track")
        val period = 60 / bpm
        val before = floor(firstBeat / period).toInt()          // whole beats before the downbeat
        val out = ArrayList<ANLZBeat>()
        var i = -before
        val tempo = min(65535.0, Math.round(bpm * 100).toDouble()).toInt()
        while (true) {
            val t = firstBeat + i * period
            if (t >= duration) break
            if (t >= 0) out.add(ANLZBeat(((i % 4) + 4) % 4 + 1, tempo / 100.0, Math.round(t * 1000)))
            i += 1
        }
        if (out.size < 2) throw ANLZWriteError.badGrid("fewer than two beats")
        return out
    }

    /** Replaces the beat grid (PQTZ) in an analysis file. A file without PQTZ (the .EXT usually) keeps its grid
     *  tags as they are, except PQT2, which is dropped (see ANLZWrite.swift). */
    fun writeGrid(file: ByteArray, beats: List<ANLZBeat>): ByteArray {
        if (beats.size < 2) throw ANLZWriteError.badGrid("fewer than two beats")
        for ((a, b) in beats.zipWithNext()) if (b.ms <= a.ms) throw ANLZWriteError.badGrid("beats out of order at ${b.ms} ms")
        for (b in beats) if (b.n < 1 || b.n > 4 || b.bpm <= 0 || b.bpm * 100 > 65535) throw ANLZWriteError.badGrid("beat at ${b.ms} ms")
        val sp = split(file)
        val out = ArrayList<ByteArray>()
        for (t in sp.tags) {
            when (t.name) {
                "PQTZ" -> {
                    var body = ByteArray(0)
                    for (b in beats) body += be16(b.n) + be16(Math.round(b.bpm * 100).toInt()) + be32(b.ms)
                    // the two header words rekordbox writes (0, 0x80000) are kept from the file
                    out.add(tag("PQTZ", t.bytes.copyOfRange(12, 20) + be32(beats.size.toLong()), body))
                }
                "PQT2" -> {}
                else -> out.add(t.bytes)
            }
        }
        val result = join(sp.header, out)
        if (sp.tags.any { it.name == "PQTZ" }) {
            val back = parse(result).beats
            if (back != beats.map { ANLZBeat(it.n, Math.round(it.bpm * 100).toInt() / 100.0, it.ms) }) throw ANLZWriteError.readBack("beat grid didn't read back")
        }
        val newTags = split(result).tags
        val kept = sp.tags.filter { it.name != "PQT2" }
        if (newTags.map { it.name } != kept.map { it.name }) throw ANLZWriteError.readBack("tag order changed")
        for ((x, y) in kept.zip(newTags)) if (x.name != "PQTZ" && !x.bytes.contentEquals(y.bytes)) throw ANLZWriteError.readBack("${x.name} changed")
        return result
    }
}
