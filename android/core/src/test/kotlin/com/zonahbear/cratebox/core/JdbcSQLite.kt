package com.zonahbear.cratebox.core

import java.sql.Connection
import java.sql.DriverManager

/** SQLiteDB on sqlite-jdbc, for the JVM tests (the app plugs in android.database.sqlite instead) */
class JdbcSQLite(override val path: String, readOnly: Boolean) : SQLiteDB {
    private var c: Connection? = try {
        val props = java.util.Properties()
        if (readOnly) props.setProperty("open_mode", "1")
        DriverManager.getConnection("jdbc:sqlite:$path", props)
    } catch (e: Exception) { throw SQLiteError.open(e.message ?: "can't open") }

    private fun conn() = c ?: throw SQLiteError.open("closed")

    private fun prepare(sql: String, args: List<SQLValue>) = try {
        conn().prepareStatement(sql).also { st ->
            for ((i, a) in args.withIndex()) when (a) {
                SQLValue.Null -> st.setNull(i + 1, java.sql.Types.NULL)
                is SQLValue.I -> st.setLong(i + 1, a.v)
                is SQLValue.R -> st.setDouble(i + 1, a.v)
                is SQLValue.T -> st.setString(i + 1, a.v)
                is SQLValue.B -> st.setBytes(i + 1, a.v)
            }
        }
    } catch (e: java.sql.SQLException) { throw SQLiteError.prepare(sql, e.message ?: "") }

    override fun query(sql: String, args: List<SQLValue>): List<Map<String, SQLValue>> {
        prepare(sql, args).use { st ->
            try {
                val rs = st.executeQuery()
                val md = rs.metaData
                val rows = ArrayList<Map<String, SQLValue>>()
                while (rs.next()) {
                    val row = LinkedHashMap<String, SQLValue>()
                    for (k in 1..md.columnCount) {
                        row[md.getColumnLabel(k)] = when (val v = rs.getObject(k)) {
                            null -> SQLValue.Null
                            is Int -> SQLValue.I(v.toLong())
                            is Long -> SQLValue.I(v)
                            is Double -> SQLValue.R(v)
                            is Float -> SQLValue.R(v.toDouble())
                            is String -> SQLValue.T(v)
                            is ByteArray -> SQLValue.B(v)
                            else -> SQLValue.T(v.toString())
                        }
                    }
                    rows.add(row)
                }
                return rows
            } catch (e: java.sql.SQLException) { throw SQLiteError.step(sql, e.message ?: "") }
        }
    }

    override fun run(sql: String, args: List<SQLValue>) {
        prepare(sql, args).use { st -> try { st.execute() } catch (e: java.sql.SQLException) { throw SQLiteError.step(sql, e.message ?: "") } }
    }

    override fun close() { c?.close(); c = null }

    companion object {
        fun install() { SQLite.opener = { p, ro -> JdbcSQLite(p, ro) } }
    }
}
