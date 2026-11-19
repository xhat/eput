import Foundation
import SQLite3

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

struct SQLRow {
    fileprivate let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}

/// 系统自带 libsqlite3 的一层薄封装，所有访问都串行在一个队列上。
final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "database", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaXiangShuo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("data.sqlite").path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            Log.app.error("打开数据库失败：\(path, privacy: .public)")
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA cache_size=-256")
        execute("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created REAL NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                raw TEXT NOT NULL,
                text TEXT NOT NULL,
                app TEXT NOT NULL DEFAULT ''
            )
            """)
        execute("CREATE INDEX IF NOT EXISTS history_created ON history(created)")
        execute("CREATE TABLE IF NOT EXISTS usage (day TEXT PRIMARY KEY, seconds REAL NOT NULL DEFAULT 0)")
        execute("""
            CREATE TABLE IF NOT EXISTS phrases (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                term TEXT NOT NULL,
                value TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL
            )
            """)
    }

    @discardableResult
    func execute(_ sql: String, _ args: [SQLValue] = []) -> Int64 {
        queue.sync {
            guard let stmt = prepare(sql, args) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE, rc != SQLITE_ROW {
                Log.app.error("SQL 执行失败：\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func query<T>(_ sql: String, _ args: [SQLValue] = [], map: (SQLRow) -> T) -> [T] {
        queue.sync {
            guard let stmt = prepare(sql, args) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(map(SQLRow(stmt: stmt)))
            }
            return out
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Log.app.error("SQL 编译失败：\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
