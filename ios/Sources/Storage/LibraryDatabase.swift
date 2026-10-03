import Foundation
import SQLite3

/// Atomic durable metadata, independent from original publication storage.
final class LibraryDatabase {
    private var database: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw BookError.message("The library database could not be opened.") }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
        try execute("PRAGMA user_version=1")
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> BookError { .message("Library storage: \(String(cString: sqlite3_errmsg(database)))") }
    /// Publish related records together. A thrown write or failed commit restores
    /// the previous database state; callers restore their in-memory snapshot.
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    func read<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM records WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        if data == Data("null".utf8) { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    func write<T: Encodable>(_ key: String, value: T) throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO records(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
}
