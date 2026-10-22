// core's SQLite seam on android.database.sqlite (the tests use sqlite-jdbc). OneLibrary decrypts exportLibrary.db
// into a plain copy in the app's cache and opens that, so this only ever sees ordinary SQLite files.
package com.zonahbear.cratebox.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import com.zonahbear.cratebox.core.SQLValue
import com.zonahbear.cratebox.core.SQLite
import com.zonahbear.cratebox.core.SQLiteDB
import com.zonahbear.cratebox.core.SQLiteError

class AndroidSQLite private constructor(override val path: String, private var db: SQLiteDatabase?) : SQLiteDB {
    companion object {
        /** call once at startup */
        fun install() {
            SQLite.opener = { path, readOnly ->
                val flags = if (readOnly) SQLiteDatabase.OPEN_READONLY else SQLiteDatabase.OPEN_READWRITE
                val d = try { SQLiteDatabase.openDatabase(path, null, flags or SQLiteDatabase.NO_LOCALIZED_COLLATORS) }
                        catch (e: SQLiteException) { throw SQLiteError.open(e.message ?: "can't open") }
                AndroidSQLite(path, d)
            }
        }
    }

    private fun conn() = db ?: throw SQLiteError.open("closed")

    private fun bindArgs(args: List<SQLValue>): Array<Any?> = Array(args.size) { i ->
        when (val a = args[i]) {
            SQLValue.Null -> null
            is SQLValue.I -> a.v
            is SQLValue.R -> a.v
            is SQLValue.T -> a.v
            is SQLValue.B -> a.v
        }
    }

    override fun query(sql: String, args: List<SQLValue>): List<Map<String, SQLValue>> {
        // rawQuery binds only strings, so typed values go through a compiled statement's binders
        val c: Cursor = try {
            conn().rawQueryWithFactory({ _, driver, table, q ->
                for ((i, a) in args.withIndex()) when (a) {
                    SQLValue.Null -> q.bindNull(i + 1)
                    is SQLValue.I -> q.bindLong(i + 1, a.v)
                    is SQLValue.R -> q.bindDouble(i + 1, a.v)
                    is SQLValue.T -> q.bindString(i + 1, a.v)
                    is SQLValue.B -> q.bindBlob(i + 1, a.v)
                }
                android.database.sqlite.SQLiteCursor(driver, table, q)
            }, sql, null, "")
        } catch (e: SQLiteException) { throw SQLiteError.prepare(sql, e.message ?: "") }
        return try {
            c.use {
                val names = it.columnNames
                val rows = ArrayList<Map<String, SQLValue>>()
                while (it.moveToNext()) {
                    val row = LinkedHashMap<String, SQLValue>()
                    for (k in names.indices) row[names[k]] = when (it.getType(k)) {
                        Cursor.FIELD_TYPE_NULL -> SQLValue.Null
                        Cursor.FIELD_TYPE_INTEGER -> SQLValue.I(it.getLong(k))
                        Cursor.FIELD_TYPE_FLOAT -> SQLValue.R(it.getDouble(k))
                        Cursor.FIELD_TYPE_BLOB -> SQLValue.B(it.getBlob(k))
                        else -> SQLValue.T(it.getString(k))
                    }
                    rows.add(row)
                }
                rows
            }
        } catch (e: SQLiteException) { throw SQLiteError.step(sql, e.message ?: "") }
    }

    override fun run(sql: String, args: List<SQLValue>) {
        try {
            val s = sql.trimStart().uppercase()
            // PRAGMAs and other statements that return rows go through a query (execSQL refuses them)
            if (s.startsWith("PRAGMA") || s.startsWith("SELECT")) { query(sql, args); return }
            if (args.isEmpty()) conn().execSQL(sql) else conn().execSQL(sql, bindArgs(args))
        } catch (e: SQLiteException) { throw SQLiteError.step(sql, e.message ?: "") }
    }

    /** Android's own transaction API: execSQL("BEGIN") is refused on some versions */
    override fun transaction(body: () -> Unit) {
        val d = conn()
        d.beginTransaction()
        try { body(); d.setTransactionSuccessful() } finally { d.endTransaction() }
    }

    override fun close() { db?.close(); db = null }
}
