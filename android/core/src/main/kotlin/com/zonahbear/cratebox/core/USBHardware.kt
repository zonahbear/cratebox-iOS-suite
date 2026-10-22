// What each player can read off a USB stick: which library (Device Library = export.pdb, OneLibrary =
// exportLibrary.db), which audio formats up to which sample rate / bit depth, which file systems, how many hot
// cues it shows. A port of USBHardware.swift (from AlphaTheta / Pioneer DJ manuals and support pages, as of
// October 2026). Where a detail wasn't confirmed it errs on the strict side (and `confirmed` is false).
// "Unknown player" is the strictest of all: what every listed player can read.
package com.zonahbear.cratebox.core

import kotlin.math.min
import kotlin.math.pow

enum class AudioCodec(val raw: String) { MP3("mp3"), AAC("aac"), WAV("wav"), AIFF("aiff"), FLAC("flac"), ALAC("alac"), OTHER("other") }

data class PlayerProfile(
    val id: String, val name: String, val family: String,
    val readsDeviceLibrary: Boolean, val readsOneLibrary: Boolean,
    val codecs: Set<AudioCodec>,
    val maxSampleRate: Int,                 // Hz, for uncompressed / lossless files
    val maxBitDepth: Int,
    val fileSystems: Set<String>,           // "FAT32", "exFAT", "HFS+", "FAT16"
    val hotCues: Int,                       // hot cues it shows (A, B, C… )
    val confirmed: Boolean,
)

object PlayerProfiles {
    private val all6 = setOf(AudioCodec.MP3, AudioCodec.AAC, AudioCodec.WAV, AudioCodec.AIFF, AudioCodec.FLAC, AudioCodec.ALAC)
    private val basic4 = setOf(AudioCodec.MP3, AudioCodec.AAC, AudioCodec.WAV, AudioCodec.AIFF)
    private val fat32hfs = setOf("FAT32", "HFS+"); private val allFs = setOf("FAT32", "exFAT", "HFS+"); private val fatEx = setOf("FAT32", "exFAT")
    val all: List<PlayerProfile> = listOf(
        PlayerProfile("cdj3000x", "CDJ-3000X", "CDJ", false, true, all6, 96000, 24, allFs, 8, true),
        PlayerProfile("cdj3000", "CDJ-3000", "CDJ", true, true, all6, 96000, 24, allFs, 8, true),
        PlayerProfile("cdj2000nxs2", "CDJ-2000NXS2", "CDJ", true, false, all6, 96000, 24, fat32hfs, 8, true),
        PlayerProfile("cdj2000nxs", "CDJ-2000NXS", "CDJ", true, false, basic4, 48000, 24, fat32hfs, 3, false),
        PlayerProfile("cdj900nxs", "CDJ-900NXS", "CDJ", true, false, basic4, 48000, 24, fat32hfs, 3, false),
        PlayerProfile("xdj1000mk2", "XDJ-1000MK2", "XDJ", true, false, all6, 96000, 24, fat32hfs, 8, false),
        PlayerProfile("xdj700", "XDJ-700", "XDJ", true, false, basic4, 48000, 24, fat32hfs, 4, false),
        PlayerProfile("xdjxz", "XDJ-XZ", "XDJ", true, false, all6, 96000, 24, allFs, 8, false),
        PlayerProfile("xdjrx3", "XDJ-RX3", "XDJ", true, false, all6, 96000, 24, allFs, 8, false),
        PlayerProfile("xdjrx2", "XDJ-RX2", "XDJ", true, false, all6, 48000, 24, fat32hfs, 8, false),
        PlayerProfile("xdjaz", "XDJ-AZ", "XDJ", false, true, all6, 96000, 24, fatEx, 8, true),
        PlayerProfile("opusquad", "OPUS-QUAD", "All-in-one", false, true, all6, 96000, 24, fatEx, 8, true),
        PlayerProfile("omnisduo", "OMNIS-DUO", "All-in-one", false, true, all6, 96000, 24, fatEx, 8, true),
    )
    /** a player we know nothing about: needs both libraries and what every player reads */
    val unknown = PlayerProfile("unknown", "Unknown player", "?", true, true, basic4, 48000, 16, setOf("FAT32"), 3, false)
    fun byId(id: String): PlayerProfile? = if (id == "unknown") unknown else all.firstOrNull { it.id == id }

    /** what a mix of players needs, all at once */
    data class Requirement(
        var deviceLibrary: Boolean = false, var oneLibrary: Boolean = false,
        var codecs: Set<AudioCodec> = AudioCodec.entries.toSet(),
        var maxSampleRate: Int = Int.MAX_VALUE, var maxBitDepth: Int = Int.MAX_VALUE,
        var fileSystems: Set<String>? = null,
        var hotCues: Int = 8,
        var players: List<PlayerProfile> = emptyList(),
    ) {
        val unknownIncluded get() = players.any { it.id == "unknown" }
    }

    fun requirement(ids: List<String>): Requirement {
        val r = Requirement()
        val ps = ids.mapNotNull { byId(it) }
        r.players = ps.ifEmpty { listOf(unknown) }
        for (p in r.players) {
            // "unknown" covers both libraries: with an unknown player, either may be the one it reads
            if (p.readsDeviceLibrary && !p.readsOneLibrary || p.id == "unknown") r.deviceLibrary = true
            if (p.readsOneLibrary && !p.readsDeviceLibrary || p.id == "unknown") r.oneLibrary = true
            r.codecs = r.codecs intersect p.codecs
            r.maxSampleRate = min(r.maxSampleRate, p.maxSampleRate); r.maxBitDepth = min(r.maxBitDepth, p.maxBitDepth)
            r.fileSystems = r.fileSystems?.let { it intersect p.fileSystems } ?: p.fileSystems
            r.hotCues = min(r.hotCues, p.hotCues)
        }
        // a player that reads both (CDJ-3000) is happy with either; it adds no library need of its own unless
        // it's the only kind present
        if (!r.deviceLibrary && !r.oneLibrary) r.deviceLibrary = true
        return r
    }

    fun codec(ext: String): AudioCodec = when (ext.lowercase()) {
        "mp3" -> AudioCodec.MP3
        "m4a", "aac", "mp4" -> AudioCodec.AAC              // could be ALAC inside; the header check tells
        "wav", "wave" -> AudioCodec.WAV
        "aif", "aiff" -> AudioCodec.AIFF
        "flac" -> AudioCodec.FLAC
        "alac" -> AudioCodec.ALAC
        else -> AudioCodec.OTHER
    }
}

/** What a file's own header says (read from its first bytes, without decoding) */
data class AudioFacts(val codec: AudioCodec, val sampleRate: Int = 0, val bitDepth: Int = 0, val channels: Int = 0, val floatingPoint: Boolean = false)

object AudioSniffer {
    fun sniff(b: ByteArray): AudioFacts? {
        fun u(o: Int) = b[o].toInt() and 0xff
        fun be32(o: Int) = if (o + 4 <= b.size) (u(o) shl 24) or (u(o + 1) shl 16) or (u(o + 2) shl 8) or u(o + 3) else 0
        fun le32(o: Int) = if (o + 4 <= b.size) u(o) or (u(o + 1) shl 8) or (u(o + 2) shl 16) or (u(o + 3) shl 24) else 0
        fun le16(o: Int) = if (o + 2 <= b.size) u(o) or (u(o + 1) shl 8) else 0
        fun be16(o: Int) = if (o + 2 <= b.size) (u(o) shl 8) or u(o + 1) else 0
        fun tag(o: Int) = if (o + 4 <= b.size) String(b, o, 4, Charsets.ISO_8859_1) else ""
        if (b.size < 12) return null
        // WAV: RIFF ... WAVE, chunks until "fmt "
        if ((tag(0) == "RIFF" || tag(0) == "RF64") && tag(8) == "WAVE") {
            var o = 12
            while (o + 8 <= b.size) {
                val id = tag(o); val len = le32(o + 4)
                if (id == "fmt ") {
                    var fmt = le16(o + 8)
                    if (fmt == 0xFFFE && len >= 40) fmt = le16(o + 8 + 24)          // extensible: the sub-format GUID's first two bytes
                    return AudioFacts(AudioCodec.WAV, le32(o + 12), le16(o + 22), le16(o + 10), fmt == 3)
                }
                if (len < 0) break
                o += 8 + len + (len and 1)
            }
            return AudioFacts(AudioCodec.WAV)
        }
        // AIFF / AIFC: FORM ... AIFF, COMM chunk (sample rate as an 80-bit float)
        if (tag(0) == "FORM" && (tag(8) == "AIFF" || tag(8) == "AIFC")) {
            var o = 12
            while (o + 8 <= b.size) {
                val id = tag(o); val len = be32(o + 4)
                if (id == "COMM" && o + 26 <= b.size) {
                    val exp = be16(o + 16) and 0x7fff
                    val mant = (be32(o + 18).toLong() and 0xffffffffL shl 32) or (be32(o + 22).toLong() and 0xffffffffL)
                    val mantD = (mant ushr 1).toDouble() * 2 + (mant and 1)          // as unsigned
                    val rate = if (exp == 0) 0 else (mantD * 2.0.pow(exp - 16383 - 63)).toInt()
                    val comp = if (tag(8) == "AIFC" && o + 30 <= b.size) tag(o + 26) else "NONE"
                    return AudioFacts(AudioCodec.AIFF, rate, be16(o + 14), be16(o + 8), comp == "fl32" || comp == "fl64")
                }
                if (len < 0) break
                o += 8 + len + (len and 1)
            }
            return AudioFacts(AudioCodec.AIFF)
        }
        // FLAC: "fLaC", then STREAMINFO
        if (tag(0) == "fLaC" && b.size >= 8 + 18) {
            val s = 8 + 10
            val rate = (u(s) shl 12) or (u(s + 1) shl 4) or (u(s + 2) shr 4)
            val ch = (u(s + 2) shr 1 and 0x7) + 1
            val bps = (((u(s + 2) and 1) shl 4) or (u(s + 3) shr 4)) + 1
            return AudioFacts(AudioCodec.FLAC, rate, bps, ch)
        }
        // MP4 / M4A: an ALAC or AAC sample entry somewhere in the first bytes (moov first in most files)
        if (tag(4) == "ftyp") {
            fun find(t: String): Int? {
                val n = t.toByteArray(Charsets.ISO_8859_1)
                if (b.size < n.size) return null
                for (i in 0..(b.size - n.size)) if (b[i] == n[0] && b[i + 1] == n[1] && b[i + 2] == n[2] && b[i + 3] == n[3]) return i
                return null
            }
            // sample entry: size(4) 'alac'/'mp4a'(4) reserved(6) dataRef(2) version(2) rev(2) vendor(4) channels(2) bits(2) comp(2) packet(2) rate(4, 16.16)
            val i = find("alac") ?: find("mp4a")
            if (i != null) {
                val isAlac = tag(i) == "alac"
                val e = i + 4
                return AudioFacts(if (isAlac) AudioCodec.ALAC else AudioCodec.AAC, be32(e + 24) ushr 16, if (isAlac) be16(e + 18) else 0, be16(e + 16))
            }
            return AudioFacts(AudioCodec.AAC)
        }
        // MP3: skip an ID3v2 tag, then a frame header
        var o = 0
        if (tag(0).startsWith("ID3") && b.size >= 10)
            o = 10 + ((u(6) and 0x7f) shl 21 or ((u(7) and 0x7f) shl 14) or ((u(8) and 0x7f) shl 7) or (u(9) and 0x7f))
        while (o + 4 <= b.size) {
            if (u(o) == 0xff && u(o + 1) and 0xe0 == 0xe0) {
                val ver = u(o + 1) shr 3 and 3; val layer = u(o + 1) shr 1 and 3; val ri = u(o + 2) shr 2 and 3
                if (layer == 1 && ri != 3 && ver != 1) {                 // layer III
                    val base = intArrayOf(44100, 48000, 32000)[ri]
                    val rate = if (ver == 3) base else if (ver == 2) base / 2 else base / 4
                    return AudioFacts(AudioCodec.MP3, rate, 16, if (u(o + 3) shr 6 == 3) 1 else 2)
                }
            }
            o += 1
            if (o > 65536) break
        }
        return null
    }
}
