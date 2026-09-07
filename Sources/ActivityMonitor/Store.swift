import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One observed (app, title, url) key within one 5-minute bucket.
struct TallyRow {
    var bucketStart: Int
    var bundleID: String
    var appName: String
    var title: String
    var url: String
    var seconds: Int
    var switches: Int
}

enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    var description: String {
        switch self {
        case .open(let m): return "could not open database: \(m)"
        case .sql(let m): return "sql error: \(m)"
        }
    }
}

/// Append-only tally of raw observations. Titles are stored exactly as the
/// Accessibility API reported them; all cleanup and grouping happens in Rules
/// at read time, so re-editing a rule retroactively reshapes every past day.
final class Store {
    /// Storage granularity. Read-time rollups are integer multiples of this.
    static let bucketSeconds = 300

    private var db: OpaquePointer?
    private var upsertStmt: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK, db != nil else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS bucket_tally (
              bucket_start INTEGER NOT NULL,
              bundle_id    TEXT    NOT NULL,
              app_name     TEXT    NOT NULL,
              title        TEXT    NOT NULL,
              url          TEXT    NOT NULL DEFAULT '',
              seconds      INTEGER NOT NULL DEFAULT 0,
              switches     INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (bucket_start, bundle_id, title, url)
            ) WITHOUT ROWID;
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_bucket ON bucket_tally(bucket_start);")

        let sql = """
            INSERT INTO bucket_tally
              (bucket_start, bundle_id, app_name, title, url, seconds, switches)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_start, bundle_id, title, url) DO UPDATE SET
              seconds  = seconds  + excluded.seconds,
              switches = switches + excluded.switches,
              app_name = excluded.app_name;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &upsertStmt, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit {
        sqlite3_finalize(upsertStmt)
        sqlite3_close(db)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }

    /// Adds `seconds` to one key. Called once per poll; the upsert makes this
    /// idempotent-safe against crashes, since there is no open segment to flush.
    func add(bucketStart: Int, bundleID: String, appName: String, title: String,
             url: String, seconds: Int, switches: Int) {
        guard let stmt = upsertStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(bucketStart))
        sqlite3_bind_text(stmt, 2, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, appName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(seconds))
        sqlite3_bind_int64(stmt, 7, Int64(switches))
        if sqlite3_step(stmt) != SQLITE_DONE {
            FileHandle.standardError.write(Data("tally write failed: \(String(cString: sqlite3_errmsg(db)))\n".utf8))
        }
    }

    func rows(from: Int, to: Int) -> [TallyRow] {
        let sql = """
            SELECT bucket_start, bundle_id, app_name, title, url, seconds, switches
            FROM bucket_tally WHERE bucket_start >= ? AND bucket_start < ?
            ORDER BY bucket_start;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(from))
        sqlite3_bind_int64(stmt, 2, Int64(to))

        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }

        var out: [TallyRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TallyRow(
                bucketStart: Int(sqlite3_column_int64(stmt, 0)),
                bundleID: text(1), appName: text(2), title: text(3), url: text(4),
                seconds: Int(sqlite3_column_int64(stmt, 5)),
                switches: Int(sqlite3_column_int64(stmt, 6))
            ))
        }
        return out
    }

    /// Days that have any data, newest first, as epoch-second local midnights.
    func daysWithData() -> [Int] {
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT bucket_start FROM bucket_tally ORDER BY bucket_start DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var seen = Set<Int>()
        var out: [Int] = []
        let cal = Calendar.current
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Int(sqlite3_column_int64(stmt, 0))
            let midnight = Int(cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts))).timeIntervalSince1970)
            if seen.insert(midnight).inserted { out.append(midnight) }
        }
        return out
    }
}
