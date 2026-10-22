// A USB stick through Android's Storage Access Framework (the iOS app's security-scoped folder URL): the user
// picks the stick's root once with ACTION_OPEN_DOCUMENT_TREE, the app keeps the permission, and every path below
// it is looked up by name through DocumentsContract. Paths are relative to the stick's root, as in core's StickFS.
//
// There's no atomic rename-over here: replace() deletes the old file and renames the staged one into its place.
// USBSafeWrite's journal covers the gap: recover() moves the staged file in if a write stopped between the two.
package com.zonahbear.cratebox.platform

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import com.zonahbear.cratebox.core.StickFS
import com.zonahbear.cratebox.core.readUpTo
import java.io.FileOutputStream
import java.io.IOException

class SafStickFS(context: Context, val tree: Uri) : StickFS {
    private val cr: ContentResolver = context.applicationContext.contentResolver
    private val rootId = DocumentsContract.getTreeDocumentId(tree)

    private class Entry(val id: String, val dir: Boolean, val size: Long)
    // path → document, filled as paths are looked up; cleared when names change
    private val cache = HashMap<String, Entry>()

    private fun uri(id: String) = DocumentsContract.buildDocumentUriUsingTree(tree, id)
    private fun parts(rel: String) = rel.split('/').filter { it.isNotEmpty() && it != "." }

    /** a directory's children by name (with their ids, kinds and sizes) */
    private fun children(dirId: String): Map<String, Entry> {
        val out = HashMap<String, Entry>()
        val q = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dirId)
        cr.query(q, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE), null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                out[name] = Entry(c.getString(0), c.getString(2) == Document.MIME_TYPE_DIR, if (c.isNull(3)) 0 else c.getLong(3))
            }
        }
        return out
    }

    /** the document at rel, or null; FAT is case-insensitive, so a name that differs only in case still matches */
    private fun find(rel: String, fresh: Boolean = false): Entry? {
        val ps = parts(rel)
        if (ps.isEmpty()) return Entry(rootId, true, 0)
        val key = ps.joinToString("/")
        if (!fresh) cache[key]?.let { return it }
        var cur = Entry(rootId, true, 0)
        var path = ""
        for ((i, p) in ps.withIndex()) {
            path = if (path.isEmpty()) p else "$path/$p"
            val last = i == ps.size - 1
            val hit = if (!last && !fresh) cache[path] else null
            cur = hit ?: run {
                val kids = children(cur.id)
                for ((n, e) in kids) cache[(if (i == 0) "" else path.substringBeforeLast('/') + "/") + n] = e
                kids[p] ?: kids.entries.firstOrNull { it.key.equals(p, ignoreCase = true) }?.value
            } ?: return null
            if (!last && !cur.dir) return null
        }
        return cur
    }

    private fun forget(rel: String) {
        val key = parts(rel).joinToString("/")
        cache.keys.removeAll { it == key || it.startsWith("$key/") }
    }

    override fun read(rel: String): ByteArray? = runCatching {
        val e = find(rel)?.takeIf { !it.dir } ?: return null
        cr.openInputStream(uri(e.id))?.use { it.readBytes() }
    }.getOrNull()

    override fun readHead(rel: String, max: Int): ByteArray? = runCatching {
        val e = find(rel)?.takeIf { !it.dir } ?: return null
        cr.openInputStream(uri(e.id))?.use { s -> s.readUpTo(max) }
    }.getOrNull()

    override fun size(rel: String): Long? = find(rel, fresh = true)?.takeIf { !it.dir }?.size

    override fun write(rel: String, bytes: ByteArray) {
        val ps = parts(rel)
        val name = ps.lastOrNull() ?: throw IOException("no file name")
        val parent = ps.dropLast(1).joinToString("/")
        val existing = find(rel, fresh = true)
        val id = if (existing != null) {
            if (existing.dir) throw IOException("$rel is a folder")
            existing.id
        } else {
            val dir = find(parent) ?: throw IOException("no folder $parent")
            val made = DocumentsContract.createDocument(cr, uri(dir.id), "application/octet-stream", name)
                ?: throw IOException("couldn't create $rel")
            val madeId = DocumentsContract.getDocumentId(made)
            // a provider that renamed it ("x (1)", an added extension) would leave the real path unwritten
            val got = children(dir.id).entries.firstOrNull { it.value.id == madeId }?.key
            if (got != null && got != name) {
                runCatching { DocumentsContract.deleteDocument(cr, made) }
                throw IOException("the stick named the new file $got instead of $name")
            }
            madeId
        }
        // "rwt": truncate, then sync to the device before returning, like FileStickFS
        cr.openFileDescriptor(uri(id), "rwt")?.use { pfd ->
            FileOutputStream(pfd.fileDescriptor).use { out -> out.write(bytes); out.flush(); out.fd.sync() }
        } ?: throw IOException("couldn't open $rel for writing")
        forget(rel)
    }

    override fun replace(from: String, to: String) {
        val fromParts = parts(from); val toParts = parts(to)
        if (fromParts.dropLast(1) != toParts.dropLast(1)) throw IOException("replace only works within one folder")
        val src = find(from, fresh = true) ?: throw IOException("no $from")
        find(to, fresh = true)?.let { old ->
            if (!DocumentsContract.deleteDocument(cr, uri(old.id))) throw IOException("couldn't remove the old $to")
        }
        forget(to)
        val renamed = DocumentsContract.renameDocument(cr, uri(src.id), toParts.last())
            ?: throw IOException("couldn't rename $from")
        forget(from)
        // check the name it actually got
        val parentId = find(toParts.dropLast(1).joinToString("/"))?.id ?: return
        val got = children(parentId).entries.firstOrNull { it.value.id == DocumentsContract.getDocumentId(renamed) }?.key
        if (got != null && got != toParts.last()) throw IOException("the stick named it $got instead of ${toParts.last()}")
    }

    override fun delete(rel: String) {
        val e = find(rel, fresh = true) ?: return
        DocumentsContract.deleteDocument(cr, uri(e.id))
        forget(rel)
    }

    override fun list(dir: String): List<String>? {
        val e = find(dir, fresh = true)?.takeIf { it.dir } ?: return null
        val kids = children(e.id)
        val base = parts(dir).joinToString("/")
        for ((n, k) in kids) cache[if (base.isEmpty()) n else "$base/$n"] = k
        return kids.keys.toList()
    }

    override fun mkdirs(dir: String) {
        var cur = Entry(rootId, true, 0)
        var path = ""
        for (p in parts(dir)) {
            path = if (path.isEmpty()) p else "$path/$p"
            val next = find(path, fresh = true)
            cur = if (next != null) {
                if (!next.dir) throw IOException("$path is a file")
                next
            } else {
                val made = DocumentsContract.createDocument(cr, uri(cur.id), Document.MIME_TYPE_DIR, p) ?: throw IOException("couldn't create $path")
                Entry(DocumentsContract.getDocumentId(made), true, 0).also { cache[path] = it }
            }
        }
    }

    /** the stick's name as the phone shows it */
    fun displayName(): String = runCatching {
        cr.query(uri(rootId), arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull() ?: "USB stick"
}
