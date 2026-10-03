import Foundation
import KnowledgeCore
import ASKCSQLite

package final class SQLiteStatement {
    private unowned let database: SQLiteDatabase
    private var handle: OpaquePointer?

    package init(database: SQLiteDatabase, handle: OpaquePointer?) {
        self.database = database
        self.handle = handle
    }

    deinit {
        finalize()
    }

    package func finalize() {
        if let handle {
            sqlite3_finalize(handle)
            self.handle = nil
        }
    }

    package func reset() throws {
        guard sqlite3_reset(handle) == SQLITE_OK else {
            throw ASKError.database(database.lastErrorMessage())
        }
        guard sqlite3_clear_bindings(handle) == SQLITE_OK else {
            throw ASKError.database(database.lastErrorMessage())
        }
    }

    package func bind(_ value: String?, at index: Int32) throws {
        if let value {
            guard sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                throw ASKError.database(database.lastErrorMessage())
            }
        } else {
            guard sqlite3_bind_null(handle, index) == SQLITE_OK else {
                throw ASKError.database(database.lastErrorMessage())
            }
        }
    }

    package func bind(_ value: Int, at index: Int32) throws {
        guard sqlite3_bind_int64(handle, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw ASKError.database(database.lastErrorMessage())
        }
    }

    package func bind(_ value: Double, at index: Int32) throws {
        guard sqlite3_bind_double(handle, index, value) == SQLITE_OK else {
            throw ASKError.database(database.lastErrorMessage())
        }
    }

    package func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ASKError.database(database.lastErrorMessage())
        }
    }

    package func string(at column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    package func int(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    package func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
