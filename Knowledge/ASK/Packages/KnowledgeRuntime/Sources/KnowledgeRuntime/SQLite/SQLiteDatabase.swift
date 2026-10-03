import Foundation
import KnowledgeCore
import ASKCSQLite

/// Signals that a database could not be opened because it is not there.
///
/// Callers previously inferred this by matching SQLite's English error text, which ties
/// behaviour to a message the library is free to reword.
package struct SQLiteDatabaseMissing: Error, Equatable {
    package let path: String
}

package final class SQLiteDatabase {
    package let path: URL
    private var handle: OpaquePointer?

    /// Waited on before reporting a locked database, so writer contention surfaces as a
    /// bounded delay instead of an immediate `SQLITE_BUSY`.
    private static let busyTimeoutMilliseconds: Int32 = 5_000

    package init(path: URL, readOnly: Bool = false) throws {
        self.path = path
        if readOnly {
            // A read must not bring the storage layout into existence.
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw SQLiteDatabaseMissing(path: path.path)
            }
        } else {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let flags: Int32 = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path.path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_close_v2(handle)
            handle = nil
            throw ASKError.database(message)
        }
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    }

    deinit {
        if let handle {
            // `sqlite3_close_v2` releases the handle once any surviving statement is
            // finalized; `sqlite3_close` would return SQLITE_BUSY and leak it.
            sqlite3_close_v2(handle)
        }
    }

    package func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorPointer)
            throw ASKError.database(message)
        }
    }

    package func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try exec("COMMIT;")
            return value
        } catch {
            let transactionError = error
            do {
                try exec("ROLLBACK;")
            } catch {
                throw ASKError.database(
                    "transaction failed: \(transactionError); rollback failed: \(error)"
                )
            }
            throw transactionError
        }
    }

    package func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw ASKError.database(lastErrorMessage())
        }
        return SQLiteStatement(database: self, handle: statement)
    }

    package func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        guard try statement.step() else {
            throw ASKError.database("sqlite query returned no rows")
        }
        return Int(statement.int(at: 0))
    }

    package func lastErrorMessage() -> String {
        handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
    }
}
