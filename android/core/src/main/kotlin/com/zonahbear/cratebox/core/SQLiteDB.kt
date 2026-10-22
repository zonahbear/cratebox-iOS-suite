// A small SQLite seam (SQLiteDB.swift wraps the system SQLite): open, query rows as maps, run statements with
// bound values, transactions. Enough for OneLibrary. :core has no SQLite of its own: the Android app plugs in
// android.database.sqlite through SQLite.opener, the tests plug in sqlite-jdbc.
package com.zonahbear.cratebox.core

class SQLiteError(message: String) : Exception(message) {
    companion object {
        fun open(m: String) = SQLiteError("SQLite open: $m")
        fun prepare(s: String, m: String) = SQLiteError("SQLite: $m in ${s.take(80)}")
        fun step(s: String, m: String) = SQLiteError("SQLite: $m running ${s.take(80)}")
    }
}

sealed class SQLValue {
    object Null : SQLValue() { override fun toString() = "NULL" }
    data class I(val v: Long) : SQLValue()
    data class R(val v: Double) : SQLValue()
    data class T(val v: String) : SQLValue()
    class B(val v: ByteArray) : SQLValue() {
        override fun equals(other: Any?) = other is B && v.contentEquals(other.v)
        override fun hashCode() = v.contentHashCode()
    }

    val int: Long? get() = when (this) { is I -> v; is R -> v.toLong(); is T -> v.toLongOrNull(); else -> null }
    val double: Double? get() = when (this) { is R -> v; is I -> v.toDouble(); is T -> v.toDoubleOrNull(); else -> null }
    val string: String? get() = when (this) { is T -> v; is I -> v.toString(); is R -> v.toString(); else -> null }
}

interface SQLiteDB {
    val path: String
    /** every row as column name → value */
    fun query(sql: String, args: List<SQLValue> = emptyList()): List<Map<String, SQLValue>>
    fun run(sql: String, args: List<SQLValue> = emptyList())
    fun close()

    /** statements in one transaction: all or nothing */
    fun transaction(body: () -> Unit) {
        run("BEGIN IMMEDIATE")
        try { body(); run("COMMIT") } catch (e: Throwable) { runCatching { run("ROLLBACK") }; throw e }
    }
    fun tables(): Set<String> = query("SELECT name FROM sqlite_master WHERE type='table'").mapNotNull { it["name"]?.string }.toSet()
    fun columns(table: String): Set<String> = query("PRAGMA table_info(\"${table.replace("\"", "")}\")").mapNotNull { it["name"]?.string }.toSet()
    /** SQLite's own consistency check: "ok", or the first problems it found */
    fun integrityCheck(quick: Boolean = false): List<String> =
        query(if (quick) "PRAGMA quick_check" else "PRAGMA integrity_check").mapNotNull { it.values.firstOrNull()?.string }
}

object SQLite {
    /** set by the platform: Android's SQLiteDatabase in the app, sqlite-jdbc in the tests */
    @Volatile var opener: ((path: String, readOnly: Boolean) -> SQLiteDB)? = null
    fun open(path: String, readOnly: Boolean = false): SQLiteDB =
        (opener ?: throw SQLiteError.open("no SQLite on this platform")).invoke(path, readOnly)
}
