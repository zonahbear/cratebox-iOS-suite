// Cratebox USB's preflight scan: will this stick play on the players at the gig? A port of USBPreflight.swift.
//
//  Emergency  seconds: only the set you're about to play (or every track, if none is picked): files there,
//             formats the players read, analysis present, the libraries the players need. No decoding.
//  Standard   the whole stick, the set first: also each file's own header (codec, sample rate, bit depth),
//             export.pdb's structure, OneLibrary's quick check, the two libraries against each other, file
//             names a FAT32 stick can't hold.
//  Deep       everything: decodes each file, parses each analysis file, SQLite's full integrity check, hot cues
//             the older players can't show.
//
// Issues come with one-tap fixes where there is one. Fixes that would write to the stick say which write
// (USBWriteKind) so the app can keep them locked until that write is proven.
package com.zonahbear.cratebox.core

import kotlin.math.max

enum class ScanMode(val raw: String, val title: String, val blurb: String) {
    EMERGENCY("emergency", "Emergency", "Seconds. The set only: files, formats, libraries."),
    STANDARD("standard", "Standard", "The whole stick, set first: headers, databases, sync."),
    DEEP("deep", "Deep Scan", "Everything, decoding every file. Takes a while."),
}
enum class IssueSeverity(val raw: Int) { INFO(0), WARNING(1), CRITICAL(2) }
enum class IssueCategory(val label: String) {
    RECOVERY("Recovery"), LIBRARY("Library"), SYNC("Sync"), HARDWARE("Players"), MISSING_FILE("Missing files"),
    AUDIO("Audio"), ANALYSIS("Analysis"), FILE_SYSTEM("File system"),
}
enum class QuickFix(val title: String) {
    RECOVER_WRITE("Recover"),                   // finish / undo a cut-off save (journal)
    RESTORE_BACKUP("Restore backup"),           // put Cratebox's last backup of a database back
    REMOVE_FROM_PLAYLISTS("Remove from playlists"), // take missing / unplayable tracks out of the playlists (writes playlists)
    SYNC_PLAYLISTS("Sync playlists"),           // make both libraries' playlists the same (writes playlists)
    SKIP("Skip"),                               // leave it out of this check
    EXPORT_FIX_LIST("Add to fix list"),         // a list of tracks to fix in rekordbox, saved to a file
    REEXPORT("Re-export in rekordbox"),         // needs rekordbox: only it can do this
}

data class ScanIssue(
    val id: String,
    val severity: IssueSeverity,
    val category: IssueCategory,
    val title: String,
    val detail: String,
    val trackKey: String? = null,
    val playlistId: String? = null,
    val inSet: Boolean = false,             // touches the set picked for the gig
    val conflict: Boolean = false,          // a decision: Fix, Review or Skip
    val fix: QuickFix? = null,
    val fixWrites: USBWriteKind? = null,
)

sealed class Readiness {
    object Unknown : Readiness()
    object Ready : Readiness()
    data class Warnings(val n: Int) : Readiness()
    data class NotReady(val n: Int) : Readiness()
    val label: String get() = when (this) {
        Unknown -> "Not checked"
        Ready -> "Ready"
        is Warnings -> "Ready · $n warning${if (n == 1) "" else "s"}"
        is NotReady -> "Not ready · $n problem${if (n == 1) "" else "s"}"
    }
}

data class ScanOptions(
    val mode: ScanMode,
    val players: List<String>,
    val setPlaylist: String? = null,        // USBPlaylist.id of the set
    val fileSystem: String? = null,         // "FAT32", "exFAT", "HFS+", … as the app found it
)

class ScanReport(val options: ScanOptions, val requirement: PlayerProfiles.Requirement) {
    var issues: List<ScanIssue> = emptyList()
    var tracksChecked = 0; var setTracks = 0
    var started = System.currentTimeMillis(); var finished = System.currentTimeMillis()
    var cancelled = false
    /** what the stick's databases were when scanned (a rescan is due when they change) */
    var pdbHash: String? = null; var olHash: String? = null

    fun readiness(skipped: Set<String>): Readiness {
        val open = issues.filter { !skipped.contains(it.id) && (options.mode != ScanMode.EMERGENCY || it.inSet || it.trackKey == null) }
        val crit = open.count { it.severity == IssueSeverity.CRITICAL }; val warn = open.count { it.severity == IssueSeverity.WARNING }
        if (cancelled) return Readiness.Unknown
        return if (crit > 0) Readiness.NotReady(crit) else if (warn > 0) Readiness.Warnings(warn) else Readiness.Ready
    }
}

object Preflight {
    private fun rel(path: String) = path.dropWhile { it == '/' }

    /** decode: (path on the stick) → null if it decodes fine, else why not (Deep only; the app does it with MediaCodec) */
    fun run(lib: USBLibrary, fs: StickFS, options: ScanOptions, pdbBytes: ByteArray?, olBytes: ByteArray?,
            progress: (Double, String) -> Unit = { _, _ -> }, cancelled: () -> Boolean = { false },
            decode: ((String) -> String?)? = null): ScanReport {
        val req = PlayerProfiles.requirement(options.players)
        val r = ScanReport(options, req)
        r.pdbHash = pdbBytes?.let(USBSafeWrite::hash); r.olHash = olBytes?.let(USBSafeWrite::hash)
        val out = ArrayList<ScanIssue>()
        val names = req.players.joinToString(", ") { it.name }
        val olRel = "PIONEER/rekordbox/exportLibrary.db"; val pdbRel = "PIONEER/rekordbox/export.pdb"

        // ---- interrupted saves first: nothing else is trustworthy until they're dealt with ----
        if (fs.list(USBSafeWrite.DIR_NAME)?.any { it.startsWith("journal-") } == true) {
            out.add(ScanIssue("recovery|journal", IssueSeverity.CRITICAL, IssueCategory.RECOVERY, "A save to this stick was cut off",
                "Cratebox was writing to the stick when it was unplugged or the app stopped. Recover puts back whichever complete version is there.",
                conflict = false, fix = QuickFix.RECOVER_WRITE))
        }

        // ---- the libraries the players need ----
        if (!lib.hasDeviceLibrary && !lib.hasOneLibrary && lib.oneError == null) {
            out.add(ScanIssue("lib|none", IssueSeverity.CRITICAL, IssueCategory.LIBRARY, "No rekordbox library on this stick",
                "There's no PIONEER/rekordbox/export.pdb or exportLibrary.db. Export to it from rekordbox.", fix = QuickFix.REEXPORT))
        }
        if (req.deviceLibrary && !lib.hasDeviceLibrary) {
            val who = req.players.filter { it.readsDeviceLibrary && !it.readsOneLibrary || it.id == "unknown" }.joinToString(", ") { it.name }
            out.add(ScanIssue("lib|need-dl", IssueSeverity.CRITICAL, IssueCategory.HARDWARE, "No Device Library for $who",
                "These players read export.pdb, and this stick only has OneLibrary. They'll show the files in folder view, without playlists, grids or cues. In rekordbox, export the Device Library too.", fix = QuickFix.REEXPORT))
        }
        if (req.oneLibrary && !lib.hasOneLibrary) {
            val who = req.players.filter { it.readsOneLibrary && !it.readsDeviceLibrary || it.id == "unknown" }.joinToString(", ") { it.name }
            out.add(ScanIssue("lib|need-ol", IssueSeverity.CRITICAL, IssueCategory.HARDWARE, "No OneLibrary for $who",
                "These players read OneLibrary, and this stick only has the Device Library. In rekordbox 7.2.13 or later: right-click OneLibrary on the device → Convert from Device Library, then export again.", fix = QuickFix.REEXPORT))
        }
        lib.oneError?.let { e ->
            out.add(ScanIssue("lib|ol-unreadable", if (req.oneLibrary) IssueSeverity.CRITICAL else IssueSeverity.WARNING, IssueCategory.LIBRARY, "OneLibrary can't be read",
                e, fix = if (USBSafeWrite.latestBackup(fs, olRel) != null) QuickFix.RESTORE_BACKUP else QuickFix.REEXPORT))
        }
        if (options.mode != ScanMode.EMERGENCY && pdbBytes != null) {
            for ((i, p) in PDB.problems(pdbBytes).take(6).withIndex()) {
                out.add(ScanIssue("lib|pdb|$i", IssueSeverity.CRITICAL, IssueCategory.LIBRARY, "export.pdb is damaged", p,
                    fix = if (USBSafeWrite.latestBackup(fs, pdbRel) != null) QuickFix.RESTORE_BACKUP else QuickFix.REEXPORT))
            }
        }
        lib.one?.let { one ->
            if (one.integrity.isNotEmpty() && one.integrity != listOf("ok"))
                out.add(ScanIssue("lib|ol-integrity", IssueSeverity.CRITICAL, IssueCategory.LIBRARY, "OneLibrary failed SQLite's integrity check",
                    one.integrity.take(3).joinToString("; "), fix = if (USBSafeWrite.latestBackup(fs, olRel) != null) QuickFix.RESTORE_BACKUP else QuickFix.REEXPORT))
        }
        // ---- file system ----
        val fsName = options.fileSystem
        if (!fsName.isNullOrEmpty()) {
            val ok = req.fileSystems?.let { allowed -> allowed.any { fsName.uppercase().contains(it.uppercase()) || (it == "FAT32" && fsName.uppercase().contains("MSDOS")) } } ?: true
            if (!ok) {
                out.add(ScanIssue("fs|$fsName", IssueSeverity.CRITICAL, IssueCategory.FILE_SYSTEM, "$fsName isn't readable by every player",
                    "$names need ${req.fileSystems?.sorted()?.joinToString(" or ") ?: "FAT32"}. FAT32 (MBR) works everywhere.", fix = null))
            }
        }

        // ---- the set, and which tracks to look at ----
        val setKeys = options.setPlaylist?.let { lib.trackKeys(it) } ?: emptyList()
        val setSet = setKeys.toSet()
        r.setTracks = setKeys.size
        val inAnyPlaylist = lib.playlists.filter { !it.folder }.flatMap { it.tracks }.toSet()
        var order = setKeys
        if (options.mode == ScanMode.EMERGENCY) {
            if (order.isEmpty()) order = lib.tracks.map { it.key }
        } else {
            order = order + lib.tracks.map { it.key }.filter { !setSet.contains(it) }
        }

        // ---- sync between the two libraries ----
        if (options.mode != ScanMode.EMERGENCY && lib.hasDeviceLibrary && lib.hasOneLibrary) {
            val both = req.deviceLibrary && req.oneLibrary
            for (d in lib.differences) {
                val playlist = d.kind.isPlaylist
                val inSet = if (playlist) d.subject == options.setPlaylist else setSet.contains(d.subject)
                out.add(ScanIssue("sync|" + d.id, if (both || inSet) IssueSeverity.CRITICAL else IssueSeverity.WARNING, IssueCategory.SYNC,
                    if (playlist) "Playlists differ between the libraries" else if (d.kind == USBSyncDifference.Kind.METADATA_DIFFERS) "Track info differs between the libraries" else "Track in only one library",
                    d.detail + (if (playlist) "" else " (${lib.track(d.subject)?.fileName ?: d.subject})"),
                    trackKey = if (playlist) null else d.subject, playlistId = if (playlist) d.subject else null, inSet = inSet, conflict = true,
                    fix = if (playlist) QuickFix.SYNC_PLAYLISTS else QuickFix.REEXPORT, fixWrites = if (playlist) USBWriteKind.ONE_LIBRARY_PLAYLISTS else null))
            }
        }

        // ---- every track in scope ----
        val seenCase = HashMap<String, String>()
        val total = max(1, order.size)
        for ((i, key) in order.withIndex()) {
            if (cancelled()) { r.cancelled = true; break }
            val t = lib.track(key) ?: continue
            if (i % 8 == 0) progress(i.toDouble() / total, t.fileName)
            r.tracksChecked += 1
            val inSet = setSet.contains(key)
            val played = inSet || inAnyPlaylist.contains(key)
            val sev = if (inSet || (options.mode == ScanMode.EMERGENCY && setSet.isEmpty())) IssueSeverity.CRITICAL else if (played) IssueSeverity.WARNING else IssueSeverity.INFO
            fun add(code: String, s: IssueSeverity, c: IssueCategory, title: String, detail: String, fix: QuickFix? = null, writes: USBWriteKind? = null) {
                out.add(ScanIssue("track|$code|$key", s, c, title, detail, trackKey = key, inSet = inSet, fix = fix, fixWrites = writes))
            }
            val file = rel(t.path)
            val size = fs.size(file)
            if (size == null) {
                add("missing", sev, IssueCategory.MISSING_FILE, "Missing: ${t.title}", "${t.path} isn't on the stick. Players show it but can't load it.",
                    fix = if (played) QuickFix.REMOVE_FROM_PLAYLISTS else QuickFix.SKIP, writes = if (played) USBWriteKind.DEVICE_LIBRARY_PLAYLISTS else null)
                continue
            }
            if (size == 0L) { add("empty", sev, IssueCategory.MISSING_FILE, "Empty file: ${t.title}", "${t.path} is 0 bytes.", fix = QuickFix.REEXPORT); continue }
            if (t.fileSize > 0 && size != t.fileSize) {
                add("size", IssueSeverity.WARNING, IssueCategory.AUDIO, "Changed since export: ${t.title}", "The file is $size bytes, the library says ${t.fileSize}. Cues and the grid may be off; re-export it from rekordbox.", fix = QuickFix.EXPORT_FIX_LIST)
            }
            // format: the extension (all modes), the header (standard, deep)
            var codec = PlayerProfiles.codec(t.ext); var rate = t.sampleRate; var depth = t.bitDepth; var isFloat = false
            if (options.mode != ScanMode.EMERGENCY) {
                val head = fs.readHead(file, 256 * 1024)
                if (head != null) {
                    val f = AudioSniffer.sniff(head)
                    if (f != null) {
                        if (f.codec != codec && !(codec == AudioCodec.AAC && f.codec == AudioCodec.ALAC)) {
                            add("ext", IssueSeverity.WARNING, IssueCategory.AUDIO, "Wrong file extension: ${t.fileName}", "It's really ${f.codec.raw.uppercase()}. Some players go by the extension.", fix = QuickFix.EXPORT_FIX_LIST)
                        }
                        codec = f.codec
                        if (f.sampleRate > 0) rate = f.sampleRate
                        if (f.bitDepth > 0 && f.codec != AudioCodec.MP3 && f.codec != AudioCodec.AAC) depth = f.bitDepth
                        isFloat = f.floatingPoint
                    } else {
                        add("header", sev, IssueCategory.AUDIO, "Unrecognised audio: ${t.fileName}", "The file's start doesn't look like any format the players read.", fix = QuickFix.EXPORT_FIX_LIST)
                    }
                }
            }
            if (!req.codecs.contains(codec)) {
                add("codec", sev, IssueCategory.HARDWARE, "${codec.raw.uppercase()} won't play on $names: ${t.title}",
                    "Convert it (${if (req.codecs.contains(AudioCodec.AIFF)) "AIFF or WAV for lossless" else "MP3"} ), then re-export.", fix = QuickFix.EXPORT_FIX_LIST)
            } else if (isFloat) {
                add("float", sev, IssueCategory.HARDWARE, "32-bit float audio: ${t.title}", "Players read integer PCM only. Convert to 24-bit.", fix = QuickFix.EXPORT_FIX_LIST)
            } else if (rate > req.maxSampleRate) {
                add("rate", sev, IssueCategory.HARDWARE, "${rate / 1000} kHz is too high for $names: ${t.title}", "They read up to ${req.maxSampleRate / 1000} kHz.", fix = QuickFix.EXPORT_FIX_LIST)
            } else if (codec in listOf(AudioCodec.WAV, AudioCodec.AIFF, AudioCodec.FLAC, AudioCodec.ALAC) && depth > req.maxBitDepth) {
                add("depth", sev, IssueCategory.HARDWARE, "$depth-bit is too deep for $names: ${t.title}", "They read up to ${req.maxBitDepth}-bit.", fix = QuickFix.EXPORT_FIX_LIST)
            }
            // analysis
            if (t.anlzPath.isEmpty()) {
                add("anlz-none", if (played) IssueSeverity.WARNING else IssueSeverity.INFO, IssueCategory.ANALYSIS, "Not analysed: ${t.title}", "No beat grid, waveform or cues on the players. Analyse it in rekordbox and export again.", fix = QuickFix.EXPORT_FIX_LIST)
            } else {
                val dat = rel(t.anlzPath)
                if (!fs.exists(dat)) {
                    add("anlz-missing", if (played) IssueSeverity.WARNING else IssueSeverity.INFO, IssueCategory.ANALYSIS, "Analysis file missing: ${t.title}", "${t.anlzPath} isn't on the stick: no grid or waveform on the players.", fix = QuickFix.EXPORT_FIX_LIST)
                } else if (options.mode == ScanMode.DEEP) {
                    val a = RekordboxANLZ.parse(fs.read(dat) ?: ByteArray(0))
                    if (a.beats.isEmpty()) add("anlz-grid", IssueSeverity.WARNING, IssueCategory.ANALYSIS, "No beat grid: ${t.title}", "Its analysis file has no beats: SYNC and quantize won't work.", fix = QuickFix.EXPORT_FIX_LIST)
                    val extRel = (if (dat.substringAfterLast('/').contains('.')) dat.substringBeforeLast('.') else dat) + ".EXT"
                    val ext = RekordboxANLZ.parse(fs.read(extRel) ?: ByteArray(0))
                    val hot = ext.hot.ifEmpty { a.hot }.filter { it.hot > req.hotCues }
                    if (hot.isNotEmpty()) {
                        add("hot", IssueSeverity.INFO, IssueCategory.HARDWARE, "Hot cues past ${(64 + req.hotCues).toChar()} on ${t.title}", "$names show ${req.hotCues} hot cues; ${hot.size} won't be there.")
                    }
                }
            }
            // FAT32: names that differ only in case, characters it can't hold, very long paths
            val lower = t.path.lowercase()
            val other = seenCase[lower]
            if (other != null && other != t.path) {
                add("case", IssueSeverity.WARNING, IssueCategory.FILE_SYSTEM, "Two files differ only in capitals", "$other and ${t.path}: FAT32 treats them as one file.", fix = QuickFix.EXPORT_FIX_LIST)
            } else seenCase[lower] = t.path
            if (options.mode != ScanMode.EMERGENCY) {
                if (t.path.any { it in "?*:\"<>|\\" }) {
                    add("chars", IssueSeverity.WARNING, IssueCategory.FILE_SYSTEM, "Unusual characters in ${t.fileName}", "Some players and FAT32 can't handle ? * : \" < > | \\ in names.", fix = QuickFix.EXPORT_FIX_LIST)
                }
                if (t.path.toByteArray(Charsets.UTF_8).size > 255) add("long", IssueSeverity.WARNING, IssueCategory.FILE_SYSTEM, "Very long path: ${t.fileName}", "Over 255 bytes; older players may not open it.", fix = QuickFix.EXPORT_FIX_LIST)
            }
            if (options.mode == ScanMode.DEEP && decode != null) {
                decode(file)?.let { add("decode", sev, IssueCategory.AUDIO, "Doesn't decode: ${t.title}", it, fix = QuickFix.EXPORT_FIX_LIST) }
            }
        }
        progress(1.0, "")
        // worst first, the set before the rest
        r.issues = out.sortedWith(compareByDescending<ScanIssue> { it.severity.raw }.thenByDescending { if (it.inSet) 1 else 0 })
        r.finished = System.currentTimeMillis()
        return r
    }
}
