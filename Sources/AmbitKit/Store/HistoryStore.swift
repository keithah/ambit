import Foundation
import SQLite3

/// A stretch of history summed up: how the probes in it went.
public struct HistoryBucket: Sendable, Equatable {
    public var start: Date
    /// Mean latency of the probes that were answered; nil when none was.
    public var averageMs: Double?
    public var failures: Int
    public var count: Int

    public init(start: Date, averageMs: Double?, failures: Int, count: Int) {
        self.start = start
        self.averageMs = averageMs
        self.failures = failures
        self.count = count
    }
}

extension HistoryBucket {
    /// The stretch as one point on a graph: its mean latency, or a failure when at least half
    /// of its probes got no reply.
    public var sample: ProbeSample {
        if let averageMs, failures * 2 < count { return ProbeSample(date: start, latencyMs: averageMs) }
        return ProbeSample(date: start, failure: .unknown)
    }
}

extension Array where Element == ProbeSample {
    /// A number for each sample that goes up after every pause longer than `gap`, so a graph can
    /// leave the pause empty instead of drawing a line across it. Samples are oldest first.
    public func runs(brokenBy gap: TimeInterval) -> [Int] {
        var run = 0
        return indices.map { index in
            if index > 0, self[index].date.timeIntervalSince(self[index - 1].date) > gap { run += 1 }
            return run
        }
    }
}

public struct HistoryError: Error, Equatable {
    public var message: String
}

/// Latency samples in one SQLite file, kept for a day. A sample without a value is a probe that
/// got no reply. History is a convenience: losing the file loses a graph, nothing else.
public actor HistoryStore {
    /// The history of the connection itself, as opposed to one device's.
    public static let connection = "connection"
    public static let keep: TimeInterval = 25 * 3600
    private static let insertsBetweenPrunes = 500

    private let connection: Connection
    private var insertsSincePrune = 0

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try Connection(path: url.path)
        try connection.run("PRAGMA journal_mode = WAL")
        try connection.run("PRAGMA synchronous = NORMAL")
        try connection.run("""
            CREATE TABLE IF NOT EXISTS sample(
                device TEXT NOT NULL, series TEXT NOT NULL, ts REAL NOT NULL, value REAL)
            """)
        try connection.run("CREATE INDEX IF NOT EXISTS sample_key ON sample(device, series, ts)")
        try connection.run("CREATE INDEX IF NOT EXISTS sample_ts ON sample(ts)")
        try connection.run("DELETE FROM sample WHERE ts < ?", [.number(Date().timeIntervalSince1970 - Self.keep)])
    }

    /// `~/Library/Application Support/Ambit/samples.sqlite`. A file that cannot be used is
    /// replaced by an empty one.
    public static func standard() throws -> HistoryStore {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try open(replacingIfUnusable: folder.appendingPathComponent("Ambit", isDirectory: true).appendingPathComponent("samples.sqlite"))
    }

    static func open(replacingIfUnusable url: URL) throws -> HistoryStore {
        do {
            return try HistoryStore(url: url)
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            return try HistoryStore(url: url)
        }
    }

    public func record(device: String, series: String, sample: ProbeSample) throws {
        // A latency that is not a number is stored as no reply.
        let value: Value = sample.latencyMs.flatMap { $0.isFinite ? .number($0) : nil } ?? .null
        try connection.run(
            "INSERT INTO sample(device, series, ts, value) VALUES (?, ?, ?, ?)",
            [.text(device), .text(series), .number(sample.date.timeIntervalSince1970), value]
        )
        insertsSincePrune += 1
        if insertsSincePrune >= Self.insertsBetweenPrunes {
            insertsSincePrune = 0
            try prune(before: Date().addingTimeInterval(-Self.keep))
        }
    }

    /// Samples at or after `since`, oldest first.
    public func samples(device: String, series: String, since: Date) throws -> [ProbeSample] {
        try connection.rows(
            "SELECT ts, value FROM sample WHERE device = ? AND series = ? AND ts >= ? ORDER BY ts",
            [.text(device), .text(series), .number(since.timeIntervalSince1970)]
        ) { row in
            let date = Date(timeIntervalSince1970: row.double(0))
            return row.optionalDouble(1).map { ProbeSample(date: date, latencyMs: $0) }
                ?? ProbeSample(date: date, failure: .unknown)
        }
    }

    /// Samples at or after `since` grouped into stretches of `seconds`, oldest first. Stretches
    /// with no samples are left out.
    public func buckets(device: String, series: String, since: Date, seconds: Int) throws -> [HistoryBucket] {
        let width = Double(max(1, seconds))
        return try connection.rows(
            """
            SELECT CAST(ts / ? AS INTEGER) AS bucket, AVG(value), COUNT(*) - COUNT(value), COUNT(*)
            FROM sample WHERE device = ? AND series = ? AND ts >= ? GROUP BY bucket ORDER BY bucket
            """,
            [.number(width), .text(device), .text(series), .number(since.timeIntervalSince1970)]
        ) { row in
            HistoryBucket(
                start: Date(timeIntervalSince1970: row.double(0) * width),
                averageMs: row.optionalDouble(1),
                failures: Int(row.double(2)),
                count: Int(row.double(3))
            )
        }
    }

    public func remove(device: String) throws {
        try connection.run("DELETE FROM sample WHERE device = ?", [.text(device)])
    }

    public func prune(before: Date) throws {
        try connection.run("DELETE FROM sample WHERE ts < ?", [.number(before.timeIntervalSince1970)])
    }
}

private enum Value {
    case text(String), number(Double), null
}

private struct Row {
    let statement: OpaquePointer

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func optionalDouble(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }
}

/// One open database. Only the owning actor uses it, so calls never overlap.
private final class Connection: @unchecked Sendable {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(handle)
            throw HistoryError(message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        sqlite3_close(db)
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        _ = try rows(sql, values) { _ in () }
    }

    func rows<T>(_ sql: String, _ values: [Value], _ read: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status = switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .number(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(read(Row(statement: statement)))
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }

    private func failure() -> HistoryError {
        HistoryError(message: String(cString: sqlite3_errmsg(db)))
    }
}
