// A small wrapper over the system SQLite (iOS and macOS ship it): open, query rows as dictionaries, run
// statements with bound values, transactions. Enough for OneLibrary.
import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String), prepare(String, String), step(String, String)
    public var description: String {
        switch self {
        case .open(let m): return "SQLite open: \(m)"
        case .prepare(let s, let m): return "SQLite: \(m) in \(s.prefix(80))"
        case .step(let s, let m): return "SQLite: \(m) running \(s.prefix(80))"
        }
    }
}

public enum SQLValue: Equatable {
    case null, int(Int64), real(Double), text(String), blob([UInt8])
    public var int: Int64? { if case .int(let v) = self { return v }; if case .real(let d) = self { return Int64(d) }; if case .text(let s) = self { return Int64(s) }; return nil }
    public var double: Double? { if case .real(let d) = self { return d }; if case .int(let v) = self { return Double(v) }; if case .text(let s) = self { return Double(s) }; return nil }
    public var string: String? { if case .text(let s) = self { return s }; if case .int(let v) = self { return String(v) }; if case .real(let d) = self { return String(d) }; return nil }
}

private let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDB {
    private var db: OpaquePointer?
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db); db = nil
            throw SQLiteError.open(m)
        }
    }
    deinit { close() }
    public func close() { if db != nil { sqlite3_close(db); db = nil } }

    private func message() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { throw SQLiteError.prepare(sql, message()) }
        for (i, a) in args.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(s, k)
            case .int(let v): sqlite3_bind_int64(s, k, v)
            case .real(let d): sqlite3_bind_double(s, k, d)
            case .text(let t): sqlite3_bind_text(s, k, t, -1, SQLITE_TRANSIENT_)
            case .blob(let b): _ = b.withUnsafeBytes { sqlite3_bind_blob(s, k, $0.baseAddress, Int32(b.count), SQLITE_TRANSIENT_) }
            }
        }
        return s
    }

    /// every row as column name → value
    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var rows = [[String: SQLValue]]()
        while true {
            let r = sqlite3_step(s)
            if r == SQLITE_DONE { break }
            guard r == SQLITE_ROW else { throw SQLiteError.step(sql, message()) }
            var row = [String: SQLValue]()
            for c in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, c))
                switch sqlite3_column_type(s, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(s, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(s, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(s, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(s, c))
                    if let p = sqlite3_column_blob(s, c), n > 0 { row[name] = .blob(Array(UnsafeRawBufferPointer(start: p, count: n))) } else { row[name] = .blob([]) }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        let r = sqlite3_step(s)
        guard r == SQLITE_DONE || r == SQLITE_ROW else { throw SQLiteError.step(sql, message()) }
    }

    /// statements in one transaction: all or nothing
    public func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do { try body(); try run("COMMIT") } catch { try? run("ROLLBACK"); throw error }
    }

    public func tables() throws -> Set<String> {
        Set(try query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.string })
    }
    public func columns(_ table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: ""))\")").compactMap { $0["name"]?.string })
    }
    /// SQLite's own consistency check: "ok", or the first problems it found
    public func integrityCheck(quick: Bool = false) throws -> [String] {
        try query(quick ? "PRAGMA quick_check" : "PRAGMA integrity_check").compactMap { $0.values.first?.string }
    }
}
