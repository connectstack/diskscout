import Foundation
import SQLite3

/// Minimal read helper over the SQLite C API (the databases inside iPhone backups).
final class SQLiteDB {
    enum Failure: LocalizedError {
        case open(String), query(String)
        var errorDescription: String? {
            switch self {
            case .open(let m): return "Couldn't open the database: \(m)"
            case .query(let m): return "Couldn't read the database: \(m)"
            }
        }
    }

    private let db: OpaquePointer

    /// Opens a private copy (read-write so SQLite can apply a write-ahead log), or read-only.
    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        // FULLMUTEX: one reader can be asked for two things at once (open a chat while exporting another).
        let flags = (readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        let target = readOnly ? "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1" : path
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw Failure.open(message)
        }
        db = handle
    }

    private init(handle: OpaquePointer) { db = handle }

    /// A database that exists only in memory and vanishes when released (the search index).
    static func inMemory() throws -> SQLiteDB {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Failure.open("in-memory database")
        }
        return SQLiteDB(handle: handle)
    }

    deinit { sqlite3_close(db) }

    /// Runs statements that return nothing (schema, transactions, deletes).
    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) }
        sqlite3_free(err)
        guard rc == SQLITE_OK else { throw Failure.query(message ?? "unknown error") }
    }

    func tables() -> Set<String> {
        var out = Set<String>()
        try? query("SELECT name FROM sqlite_master WHERE type = 'table'") { if let n = $0.string(0) { out.insert(n) } }
        return out
    }

    func columns(_ table: String) -> Set<String> {
        var out = Set<String>()
        try? query("PRAGMA table_info(\(table))") { if let n = $0.string(1) { out.insert(n) } }
        return out
    }

    /// Runs `sql`, calling `row` for each result. Bind values: String, Int, Int64, Double, Data or nil.
    func query(_ sql: String, _ bindings: [Any?] = [], row: (SQLiteRow) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, transient)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let b as Data: _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(b.count), transient) }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
            try row(SQLiteRow(stmt: stmt))
        }
    }

    /// First column of the first row as an integer.
    func scalar(_ sql: String, _ bindings: [Any?] = []) -> Int64? {
        var out: Int64?
        try? query(sql, bindings) { r in if out == nil { out = r.isNull(0) ? nil : r.int64(0) } }
        return out
    }
}

struct SQLiteRow {
    let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    func string(_ i: Int32) -> String? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return nil
        case SQLITE_BLOB:
            // Some iOS tables store text as blobs (call history addresses, for example).
            return data(i).flatMap { String(data: $0, encoding: .utf8) }
        default:
            return sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
    }

    func data(_ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }

    /// Seconds since 1 January 2001 (Core Data / Apple timestamps).
    func appleDate(_ i: Int32) -> Date? {
        guard !isNull(i) else { return nil }
        let v = double(i)
        guard v > 0 else { return nil }
        // Some tables store nanoseconds; scale those back to seconds.
        return Date(timeIntervalSinceReferenceDate: v > 1e12 ? v / 1e9 : v)
    }
}
