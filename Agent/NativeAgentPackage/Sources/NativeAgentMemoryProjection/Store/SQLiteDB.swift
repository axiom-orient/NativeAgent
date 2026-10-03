import CSQLite
import Foundation

/// Fixed storage policy, not a user setting or per-session state.
enum MemorySQLitePolicy {
    static let busyTimeoutMilliseconds: Int32 = 5_000
    static let walRetryWindow: Duration = .seconds(5)
    static let walRetryDelaySeconds: TimeInterval = 0.01
}

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}
struct SQLRow {
    let v: [SQLValue]
    func text(_ i: Int) throws -> String {
        guard v.indices.contains(i) else {
            throw corruptColumn(i, expected: "text", actual: "missing")
        }
        switch v[i] {
        case .text(let s): return s
        case .int: throw corruptColumn(i, expected: "text", actual: "integer")
        case .double: throw corruptColumn(i, expected: "text", actual: "real")
        case .null: throw corruptColumn(i, expected: "text", actual: "null")
        }
    }
    func int(_ i: Int) throws -> Int64 {
        guard v.indices.contains(i) else {
            throw corruptColumn(i, expected: "integer", actual: "missing")
        }
        guard case .int(let value) = v[i] else {
            throw corruptColumn(i, expected: "integer", actual: typeName(v[i]))
        }
        return value
    }
    func dbl(_ i: Int) throws -> Double {
        guard v.indices.contains(i) else {
            throw corruptColumn(i, expected: "real", actual: "missing")
        }
        switch v[i] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .text: throw corruptColumn(i, expected: "real", actual: "text")
        case .null: throw corruptColumn(i, expected: "real", actual: "null")
        }
    }
    func optInt(_ i: Int) throws -> Int64? {
        guard v.indices.contains(i) else {
            throw corruptColumn(i, expected: "integer or null", actual: "missing")
        }
        if case .null = v[i] { return nil }
        return try int(i)
    }

    func optText(_ i: Int) throws -> String? {
        guard v.indices.contains(i) else {
            throw corruptColumn(i, expected: "text or null", actual: "missing")
        }
        if case .null = v[i] { return nil }
        return try text(i)
    }

    private func typeName(_ value: SQLValue) -> String {
        switch value {
        case .text: "text"
        case .int: "integer"
        case .double: "real"
        case .null: "null"
        }
    }

    private func corruptColumn(_ index: Int, expected: String, actual: String) -> AppError {
        AppError.storage(
            "corrupt_column",
            "stored SQLite column \(index) expected \(expected), found \(actual)"
        )
    }
}
final class DB: Database {
    var p: OpaquePointer?
    init(_ path: String) throws {
        if sqlite3_open_v2(
            path, &p, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            != SQLITE_OK
        {
            let m = p != nil ? String(cString: sqlite3_errmsg(p)) : "unknown"
            throw AppError.storage(
                "sqlite_open_failed", "could not open SQLite database", NSError(domain: m, code: 0))
        }
        try execScript("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=\(MemorySQLitePolicy.busyTimeoutMilliseconds);")
    }
    deinit {
        // Normal owners call the throwing close() path. close_v2 is the only
        // non-throwing safety net available during deinitialization.
        if let handle = p {
            _ = sqlite3_close_v2(handle)
            p = nil
        }
    }
    func close() throws {
        if let x = p {
            if sqlite3_close(x) != SQLITE_OK {
                throw AppError.storage("sqlite_close_failed", "could not close SQLite database")
            }
            p = nil
        }
    }
    func err(_ c: String, _ m: String) -> AppError {
        AppError(
            .storage, c, m,
            NSError(domain: p != nil ? String(cString: sqlite3_errmsg(p)) : "unknown", code: 0),
            context: ["sqliteCode": String(sqlite3_errcode(p))])
    }
    func execScript(_ sql: String) throws {
        var e: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(p, sql, nil, nil, &e) != SQLITE_OK {
            let m: String
            if let e {
                m = String(cString: e)
                sqlite3_free(e)
            } else {
                m = "sqlite"
            }
            throw AppError.storage(
                "sqlite_exec_failed", "could not execute SQLite script", NSError(domain: m, code: 0))
        }
    }
    func prep(_ sql: String) throws -> OpaquePointer? {
        var s: OpaquePointer?
        if sqlite3_prepare_v2(p, sql, -1, &s, nil) != SQLITE_OK {
            throw err("sqlite_prepare_failed", "could not prepare SQLite statement")
        }
        return s
    }
    func bind(_ s: OpaquePointer?, _ params: [SQLValue]) throws {
        for (idx, val) in params.enumerated() {
            let i = Int32(idx + 1)
            let rc: Int32
            switch val {
            case .text(let t):
                rc = t.withCString {
                    sqlite3_bind_text(s, i, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let n): rc = sqlite3_bind_int64(s, i, n)
            case .double(let d): rc = sqlite3_bind_double(s, i, d)
            case .null: rc = sqlite3_bind_null(s, i)
            }
            if rc != SQLITE_OK { throw err("sqlite_bind_failed", "could not bind SQLite parameter") }
        }
    }
    func exec(_ sql: String, _ params: [SQLValue] = []) throws {
        let s = try prep(sql)
        defer { sqlite3_finalize(s) }
        try bind(s, params)
        let rc = sqlite3_step(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw err("sqlite_exec_failed", "could not execute SQLite statement")
        }
    }
    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        let s = try prep(sql)
        defer { sqlite3_finalize(s) }
        try bind(s, params)
        var out: [SQLRow] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                var vals: [SQLValue] = []
                for i in 0..<sqlite3_column_count(s) {
                    switch sqlite3_column_type(s, i) {
                    case SQLITE_INTEGER: vals.append(.int(sqlite3_column_int64(s, i)))
                    case SQLITE_FLOAT: vals.append(.double(sqlite3_column_double(s, i)))
                    case SQLITE_TEXT:
                        guard let text = sqlite3_column_text(s, i) else {
                            throw AppError.storage(
                                "corrupt_column",
                                "SQLite reported text for column \(i) without text bytes"
                            )
                        }
                        vals.append(.text(String(cString: text)))
                    case SQLITE_NULL: vals.append(.null)
                    default:
                        throw AppError.storage(
                            "unsupported_column_type",
                            "SQLite returned an unsupported type for column \(i)"
                        )
                    }
                }
                out.append(SQLRow(v: vals))
            } else if rc == SQLITE_DONE {
                return out
            } else {
                throw err("sqlite_query_failed", "could not query SQLite statement")
            }
        }
    }
    func changes() -> Int { Int(sqlite3_changes(p)) }
}
