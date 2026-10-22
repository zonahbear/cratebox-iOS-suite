// Every change Cratebox USB makes to a stick goes through here: staged, backed up, checked, and recoverable.
// A port of USBSafeWrite.swift, over StickFS (paths relative to the stick's root) so the same code runs on a
// plain directory (tests, OTG paths) and on Android's Storage Access Framework (the app's StickFS).
//
//  1. read the file as it is now, and refuse if it isn't the version the change was made against
//  2. back it up (on the stick, under PIONEER/rekordbox/.cratebox/backups, and a copy in the app) and read the
//     backup back
//  3. write a journal saying what's about to happen
//  4. write the new version next to it (…cratebox-stage), flush it to the stick, read it back
//  5. let the caller check the staged bytes (parse them like a player would)
//  6. swap it in (one rename where the platform has one), flush, read the result back
//  7. clear the journal
// If the app, the phone or the stick goes away in the middle, the journal is still there the next time the
// stick is opened, and `recover` puts the right version back. The journal is the same JSON the iOS app writes,
// so a stick cut off on one recovers on the other.
//
// Which writes are allowed at all is USBWriteGate's job (below): nothing that hasn't been proven on hardware.
package com.zonahbear.cratebox.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.temporal.ChronoUnit

/** a stick's files, by path relative to its root ("PIONEER/rekordbox/export.pdb") */
interface StickFS {
    /** the whole file, or null when it's missing or can't be read */
    fun read(rel: String): ByteArray?
    /** up to `max` bytes from the start */
    fun readHead(rel: String, max: Int): ByteArray? = read(rel)?.let { if (it.size > max) it.copyOf(max) else it }
    /** the file's size, or null when there's no such file */
    fun size(rel: String): Long?
    fun exists(rel: String): Boolean = size(rel) != null
    /** create or replace, and flush it to the device before returning */
    fun write(rel: String, bytes: ByteArray)
    /** move `from` over `to` (replacing it), as close to one step as the platform allows */
    fun replace(from: String, to: String)
    fun delete(rel: String)
    /** the names in a directory, or null when there's no such directory */
    fun list(dir: String): List<String>?
    fun mkdirs(dir: String)
}

/** up to `max` bytes from a stream (InputStream.readNBytes is Android 13+) */
fun java.io.InputStream.readUpTo(max: Int): ByteArray {
    val b = ByteArray(max); var n = 0
    while (n < max) { val k = read(b, n, max - n); if (k < 0) break; n += k }
    return if (n == max) b else b.copyOf(n)
}

/** StickFS on a directory (the tests; a stick the platform mounts as a path) */
class FileStickFS(val root: File) : StickFS {
    private fun f(rel: String) = File(root, rel)
    override fun read(rel: String): ByteArray? = runCatching { f(rel).takeIf { it.isFile }?.readBytes() }.getOrNull()
    override fun readHead(rel: String, max: Int): ByteArray? = runCatching {
        f(rel).takeIf { it.isFile }?.inputStream()?.use { s -> s.readUpTo(max) }
    }.getOrNull()
    override fun size(rel: String): Long? = f(rel).takeIf { it.isFile }?.length()
    override fun write(rel: String, bytes: ByteArray) {
        FileOutputStream(f(rel)).use { it.write(bytes); it.flush(); it.fd.sync() }
    }
    override fun replace(from: String, to: String) {
        java.nio.file.Files.move(f(from).toPath(), f(to).toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
    }
    override fun delete(rel: String) { f(rel).delete() }
    override fun list(dir: String): List<String>? = f(dir).takeIf { it.isDirectory }?.list()?.toList()
    override fun mkdirs(dir: String) { f(dir).mkdirs() }
}

class USBWriteError(val kind: Kind, val detail: String) : Exception(text(kind, detail)) {
    enum class Kind { CHANGED_SINCE_READ, BACKUP_FAILED, STAGE_FAILED, VERIFY_FAILED, SWAP_FAILED, LOCKED }
    override fun equals(other: Any?) = other is USBWriteError && other.kind == kind && other.detail == detail
    override fun hashCode() = kind.hashCode() * 31 + detail.hashCode()
    companion object {
        fun text(k: Kind, s: String) = when (k) {
            Kind.CHANGED_SINCE_READ -> "$s changed on the stick since Cratebox read it (rekordbox exported to it?). Nothing was written. Open the stick again."
            Kind.BACKUP_FAILED -> "Couldn't back up first, so nothing was written: $s"
            Kind.STAGE_FAILED -> "Couldn't stage the new version, nothing was changed: $s"
            Kind.VERIFY_FAILED -> "The new version didn't pass its checks, nothing was changed: $s"
            Kind.SWAP_FAILED -> "Swapping the new version in failed: $s. The backup is on the stick."
            Kind.LOCKED -> s
        }
        fun changedSinceRead(s: String) = USBWriteError(Kind.CHANGED_SINCE_READ, s)
        fun backupFailed(s: String) = USBWriteError(Kind.BACKUP_FAILED, s)
        fun stageFailed(s: String) = USBWriteError(Kind.STAGE_FAILED, s)
        fun verifyFailed(s: String) = USBWriteError(Kind.VERIFY_FAILED, s)
        fun swapFailed(s: String) = USBWriteError(Kind.SWAP_FAILED, s)
        fun locked(s: String) = USBWriteError(Kind.LOCKED, s)
    }
}

/** what's about to happen to one file; `when` in seconds since 2001-01-01, as Swift's JSONEncoder writes a Date */
data class USBJournal(
    val target: String,         // path relative to the stick's root
    val backup: String,         // relative to the stick's root
    val oldHash: String, val newHash: String,
    val oldSize: Int, val newSize: Int,
    val state: String,          // "staged" → "swapped"
    val `when`: Double,
) {
    fun json(): String = buildJsonObject {
        put("target", JsonPrimitive(target)); put("backup", JsonPrimitive(backup))
        put("oldHash", JsonPrimitive(oldHash)); put("newHash", JsonPrimitive(newHash))
        put("oldSize", JsonPrimitive(oldSize)); put("newSize", JsonPrimitive(newSize))
        put("state", JsonPrimitive(state)); put("when", JsonPrimitive(`when`))
    }.toString()

    companion object {
        const val REFERENCE_EPOCH = 978307200.0                  // 2001-01-01T00:00:00Z in Unix seconds
        fun now() = System.currentTimeMillis() / 1000.0 - REFERENCE_EPOCH
        fun parse(s: String): USBJournal? = runCatching {
            val o = Json.parseToJsonElement(s).jsonObject
            fun str(k: String) = o[k]!!.jsonPrimitive.content
            USBJournal(str("target"), str("backup"), str("oldHash"), str("newHash"), o["oldSize"]!!.jsonPrimitive.int,
                o["newSize"]!!.jsonPrimitive.int, str("state"), o["when"]!!.jsonPrimitive.double)
        }.getOrNull()
    }
}

object USBSafeWrite {
    const val DIR_NAME = "PIONEER/rekordbox/.cratebox"

    /** FNV-1a 64 + size: enough to tell versions of one file apart (not a security hash); same text as iOS */
    fun hash(b: ByteArray): String {
        var h = -0x340d631b7bdddcdbL                            // 0xcbf29ce484222325
        for (x in b) { h = h xor (x.toLong() and 0xff); h *= 0x100000001b3L }
        return String.format(java.util.Locale.US, "%016x-%d", h, b.size)
    }
    fun journalRel(rel: String) = "$DIR_NAME/journal-" + rel.replace("/", "_") + ".json"
    private fun lastComponent(rel: String) = rel.substringAfterLast('/')
    private fun parentOf(rel: String) = if (rel.contains('/')) rel.substringBeforeLast('/') + "/" else ""

    /** Writes `new` over rel. `expectedHash`: the version the change was based on (from `hash`), or null to skip
     *  that check. `appBackupDir`: where the app keeps its own copy of the backup. `verify` gets the staged bytes
     *  as read back from the stick and throws if they're wrong. Returns the backup's path on the stick. */
    fun write(new: ByteArray, fs: StickFS, rel: String, expectedHash: String?, appBackupDir: File?, keepBackups: Int = 5,
              verify: (ByteArray) -> Unit): String {
        // 1
        val cur = fs.read(rel) ?: throw USBWriteError.changedSinceRead("$rel (can't be read)")
        val oldHash = hash(cur)
        if (expectedHash != null && expectedHash != oldHash) throw USBWriteError.changedSinceRead(lastComponent(rel))
        // 2
        val backups = "$DIR_NAME/backups"
        val stamp = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString().replace(":", "-")
        val base = lastComponent(rel)
        val backupRel = "$backups/$base.$stamp.bak"
        try {
            fs.mkdirs(backups)
            fs.write(backupRel, cur)
            if (!(fs.read(backupRel)?.contentEquals(cur) ?: false)) throw USBWriteError.backupFailed("the backup didn't read back")
            if (appBackupDir != null) {
                appBackupDir.mkdirs()
                File(appBackupDir, "$base.$stamp.bak").writeBytes(cur)
            }
            // keep the newest few
            val mine = fs.list(backups)?.filter { it.startsWith("$base.") && it.endsWith(".bak") }?.sorted() ?: emptyList()
            for (old in mine.dropLast(keepBackups)) runCatching { fs.delete("$backups/$old") }
        } catch (e: USBWriteError) { throw e } catch (e: Exception) { throw USBWriteError.backupFailed(e.message ?: e.toString()) }
        // 3
        var j = USBJournal(rel, backupRel, oldHash, hash(new), cur.size, new.size, "staged", USBJournal.now())
        val ju = journalRel(rel)
        try { fs.write(ju, j.json().toByteArray()) } catch (e: Exception) { throw USBWriteError.stageFailed("journal: ${e.message}") }
        // 4
        val stage = parentOf(rel) + base + ".cratebox-stage"
        try {
            fs.write(stage, new)
            val back = fs.read(stage)
            if (back == null || !back.contentEquals(new)) throw USBWriteError.stageFailed("the staged file didn't read back")
            // 5
            try { verify(back) } catch (e: Exception) { throw USBWriteError.verifyFailed(e.message ?: e.toString()) }
        } catch (e: Exception) {
            runCatching { fs.delete(stage) }; runCatching { fs.delete(ju) }
            if (e is USBWriteError) throw e
            throw USBWriteError.stageFailed(e.message ?: e.toString())
        }
        // 6: move it over the old file
        try { fs.replace(stage, rel) } catch (e: Exception) {
            runCatching { fs.delete(stage) }; runCatching { fs.delete(ju) }
            throw USBWriteError.swapFailed(e.message ?: e.toString())
        }
        val final = fs.read(rel)
        if (final == null || !final.contentEquals(new)) {
            // put the old one back from the backup
            runCatching { fs.write(rel, cur) }
            runCatching { fs.delete(ju) }
            throw USBWriteError.swapFailed("the file on the stick isn't what was written; the old version was put back")
        }
        j = j.copy(state = "swapped")
        runCatching { fs.write(ju, j.json().toByteArray()) }
        // 7
        runCatching { fs.delete(ju) }
        return backupRel
    }

    sealed class Recovery {
        object Nothing : Recovery()
        data class CleanedUp(val what: String) : Recovery()
        data class Restored(val what: String) : Recovery()
        data class NeedsAttention(val what: String) : Recovery()
    }

    /** After a write that didn't finish (the journal is still there): keep whichever complete version is on the
     *  stick, or put the backup back if the file is neither. */
    fun recover(fs: StickFS): List<Recovery> {
        val names = fs.list(DIR_NAME) ?: return emptyList()
        val out = ArrayList<Recovery>()
        for (n in names.sorted()) {
            if (!(n.startsWith("journal-") && n.endsWith(".json"))) continue
            val ju = "$DIR_NAME/$n"
            val j = fs.read(ju)?.let { USBJournal.parse(String(it, Charsets.UTF_8)) }
            if (j == null) { out.add(Recovery.NeedsAttention("unreadable journal $n")); continue }
            val stage = parentOf(j.target) + lastComponent(j.target) + ".cratebox-stage"
            val cur = fs.read(j.target)?.let(::hash)
            val b = fs.read(j.backup)
            val staged = if (cur == null) fs.read(stage)?.let(::hash) else null
            if (cur == null && staged == j.newHash) {
                // a platform without an atomic rename-over (Android's document provider: delete, then rename)
                // stopped between the two steps: the complete new version is the staged file
                try {
                    fs.replace(stage, j.target)
                    runCatching { fs.delete(ju) }
                    out.add(Recovery.CleanedUp("${j.target}: the change had been saved completely"))
                } catch (e: Exception) { out.add(Recovery.NeedsAttention("${j.target}: the new version is staged but couldn't be moved into place (${e.message})")) }
            } else if (cur == j.oldHash || cur == j.newHash) {
                runCatching { fs.delete(stage) }; runCatching { fs.delete(ju) }
                out.add(Recovery.CleanedUp(if (cur == j.newHash) "${j.target}: the change had been saved completely" else "${j.target}: the change hadn't been saved; the stick is as it was"))
            } else if (b != null && hash(b) == j.oldHash) {
                try {
                    fs.write(j.target, b)
                    runCatching { fs.delete(stage) }; runCatching { fs.delete(ju) }
                    out.add(Recovery.Restored("${j.target}: a save was cut off part way; the version from before it was put back"))
                } catch (e: Exception) { out.add(Recovery.NeedsAttention("${j.target}: couldn't restore the backup (${e.message})")) }
            } else {
                out.add(Recovery.NeedsAttention("${j.target}: a save was cut off and its backup is missing or damaged"))
            }
        }
        return out
    }

    /** the newest backup of a file on the stick, if any (its path on the stick) */
    fun latestBackup(fs: StickFS, rel: String): String? {
        val backups = "$DIR_NAME/backups"
        val base = lastComponent(rel)
        val mine = fs.list(backups)?.filter { it.startsWith("$base.") && it.endsWith(".bak") }?.sorted() ?: emptyList()
        return mine.lastOrNull()?.let { "$backups/$it" }
    }
}

/** What Cratebox USB is allowed to write to a stick. A write is "proven" when it's been checked against a real
 *  player: on by default only then. Until then it stays locked; the Proving Ground in Cratebox USB lets you test
 *  one on a spare stick and mark it proven yourself. */
enum class USBWriteKind(val raw: String) {
    DEVICE_LIBRARY_PLAYLISTS("deviceLibraryPlaylists"), ONE_LIBRARY_PLAYLISTS("oneLibraryPlaylists"), CUES("cues"), BEATGRID("beatgrid"), METADATA("metadata");

    val title: String get() = when (this) {
        DEVICE_LIBRARY_PLAYLISTS -> "Playlists → Device Library (export.pdb)"
        ONE_LIBRARY_PLAYLISTS -> "Playlists → OneLibrary (exportLibrary.db)"
        CUES -> "Hot cues, memory cues and loops → analysis files"
        BEATGRID -> "Beat grid → analysis files"
        METADATA -> "Track info (title, artist…) → both libraries"
    }
    enum class Status { UNPROVEN, UNSUPPORTED }
    /** where each write stands in this build: writers exist and check themselves by reading back, but haven't
     *  been confirmed on a player */
    val status: Status get() = Status.UNPROVEN
    val note: String get() = when (this) {
        DEVICE_LIBRARY_PLAYLISTS -> "Byte-for-byte the same as the web app's writer, read back after every save. Not yet confirmed on a CDJ/XDJ."
        ONE_LIBRARY_PLAYLISTS -> "Edits a decrypted copy in one transaction, checks it with SQLite and reads it back, then re-encrypts. Not yet confirmed on a OneLibrary player."
        CUES -> "Rewrites the cue lists in the track's analysis files (.DAT and .EXT) and OneLibrary's cue table, read back after every save. Not yet confirmed on a CDJ/XDJ: check hot cues A-H, memory cues, loops and their comments on each player."
        BEATGRID -> "Writes a constant-tempo grid to the analysis files and the BPM to both libraries. rekordbox's second grid (PQT2) can't be rebuilt, so it's removed. Not yet confirmed on a CDJ/XDJ: check the grid, beat sync and quantise."
        METADATA -> "Writes title, artist, album, genre, comment and rating to the Device Library and OneLibrary, read back after every save. Not yet confirmed on a CDJ/XDJ: check the track lists and browsing by artist, album and genre."
    }
    companion object { fun of(raw: String) = entries.firstOrNull { it.raw == raw } }
}

data class USBWriteGate(val proven: Set<USBWriteKind>) {
    fun allowed(k: USBWriteKind) = k.status != USBWriteKind.Status.UNSUPPORTED && proven.contains(k)
    /** Playlist changes reach the stick only when every library on it can take them (a change in one library but
     *  not the other is a sync conflict waiting to happen). null = allowed; otherwise why not. */
    fun playlistWriteBlocker(deviceLibrary: Boolean, oneLibrary: Boolean): String? {
        val missing = ArrayList<String>()
        if (deviceLibrary && !allowed(USBWriteKind.DEVICE_LIBRARY_PLAYLISTS)) missing.add("Device Library")
        if (oneLibrary && !allowed(USBWriteKind.ONE_LIBRARY_PLAYLISTS)) missing.add("OneLibrary")
        if (!deviceLibrary && !oneLibrary) return "No rekordbox library on this stick"
        if (missing.isEmpty()) return null
        return "Playlist writing to ${missing.joinToString(" and ")} isn't proven on hardware yet, so it's locked. Your changes are kept as staged changes."
    }
}
