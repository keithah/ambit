import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Owns the sqlite handle and closes it when deallocated (keeps the non-Sendable pointer off
/// the actor's deinit). Access is serialized by the owning actor.
private final class SQLiteConnection: @unchecked Sendable {
    let db: OpaquePointer?

    init(url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { db = nil; return }
        db = handle
        Self.exec(handle, "PRAGMA journal_mode=WAL;")
        Self.exec(handle, "PRAGMA synchronous=NORMAL;")
        Self.exec(handle, """
        CREATE TABLE IF NOT EXISTS history_samples(
            entity_id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            value REAL,
            ok INTEGER NOT NULL,
            metadata TEXT
        );
        """)
        Self.exec(handle, "CREATE INDEX IF NOT EXISTS history_entity_time ON history_samples(entity_id, timestamp);")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    static func exec(_ db: OpaquePointer?, _ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

/// SQLite-backed history store (WAL, synchronous=NORMAL, (entity_id, timestamp) index),
/// modeled on the oracle's proven schema. Generic: keyed by EntityID, with rich per-
/// integration detail riding in the `metadata` column.
public actor SQLiteHistoryStore: HistoryStore {
    private let connection: SQLiteConnection
    private var db: OpaquePointer? { connection.db }

    public init(url: URL) {
        connection = SQLiteConnection(url: url)
    }

    public static func defaultURL(appName: String = "Ambit") throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    public func append(_ sample: Sample, for id: EntityID) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO history_samples(entity_id, timestamp, value, ok, metadata) VALUES(?,?,?,?,?);", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(stmt, 2, sample.timestamp.timeIntervalSince1970)
        if let value = sample.value { sqlite3_bind_double(stmt, 3, value) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int(stmt, 4, sample.ok ? 1 : 0)
        if let metadata = sample.metadata { sqlite3_bind_text(stmt, 5, metadata, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_step(stmt)
    }

    public func samples(_ id: EntityID, since: Date, limit: Int) -> [Sample] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        // Most-recent `limit` within range, returned ascending.
        guard sqlite3_prepare_v2(db, "SELECT timestamp, value, ok, metadata FROM history_samples WHERE entity_id=? AND timestamp>=? ORDER BY timestamp DESC LIMIT ?;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(clamping: limit))
        var result: [Sample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let value: Double? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
            let ok = sqlite3_column_int(stmt, 2) != 0
            let metadata: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            result.append(Sample(timestamp: timestamp, value: value, ok: ok, metadata: metadata))
        }
        return result.reversed()
    }

    public func prune(olderThan cutoff: Date) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM history_samples WHERE timestamp < ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        sqlite3_step(stmt)
    }
}
