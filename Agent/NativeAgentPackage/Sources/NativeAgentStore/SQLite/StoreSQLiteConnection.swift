import CSQLite
import Foundation
import NativeAgentDomain
#if canImport(Darwin)
import Darwin
#else
import CoreFoundation
import Glibc
#endif

enum StoreSQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null
}

struct StoreSQLRow {
    let values: [StoreSQLValue]

    func text(_ index: Int) throws -> String {
        guard values.indices.contains(index) else {
            throw AgentError.persistenceFailure("SQLite row is missing column \(index).")
        }
        switch values[index] {
        case .text(let value):
            return value
        default:
            throw AgentError.persistenceFailure("SQLite column \(index) is not text.")
        }
    }

    func optionalText(_ index: Int) throws -> String? {
        guard values.indices.contains(index) else {
            throw AgentError.persistenceFailure("SQLite row is missing column \(index).")
        }
        if case .null = values[index] {
            return nil
        }
        return try text(index)
    }

    func integer(_ index: Int) throws -> Int64 {
        guard values.indices.contains(index) else {
            throw AgentError.persistenceFailure("SQLite row is missing column \(index).")
        }
        switch values[index] {
        case .integer(let value):
            return value
        default:
            throw AgentError.persistenceFailure("SQLite column \(index) is not an integer.")
        }
    }

    func real(_ index: Int) throws -> Double {
        guard values.indices.contains(index) else {
            throw AgentError.persistenceFailure("SQLite row is missing column \(index).")
        }
        switch values[index] {
        case .real(let value):
            return value
        case .integer(let value):
            return Double(value)
        default:
            throw AgentError.persistenceFailure("SQLite column \(index) is not numeric.")
        }
    }

    func blob(_ index: Int) throws -> Data {
        guard values.indices.contains(index) else {
            throw AgentError.persistenceFailure("SQLite row is missing column \(index).")
        }
        switch values[index] {
        case .blob(let value):
            return value
        default:
            throw AgentError.persistenceFailure("SQLite column \(index) is not a blob.")
        }
    }

    func optionalBlob(_ index: Int) throws -> Data? {
        guard values.indices.contains(index) else {
            throw AgentError.persistenceFailure("SQLite row is missing column \(index).")
        }
        if case .null = values[index] {
            return nil
        }
        return try blob(index)
    }
}

final class StoreSQLiteConnection {
    private var handle: OpaquePointer?
    private var transactionActive = false
    private var preserveExistingWALOnClose = false
    private var checkpointWALOnClose = false

    private enum OpenMode {
        case regular(readOnly: Bool, create: Bool)
        case walSchemaAdmission
    }

    convenience init(url: URL, readOnly: Bool = false, create: Bool = true) throws {
        try self.init(path: url.path, mode: .regular(readOnly: readOnly, create: create))
    }

    static func schemaPreflightConnection(at url: URL) throws -> StoreSQLiteConnection {
        if try databaseHeaderUsesWAL(at: url) {
            let walPath = url.path + "-wal"
            let sharedMemoryPath = url.path + "-shm"
            if FileManager.default.fileExists(atPath: walPath),
               FileManager.default.fileExists(atPath: sharedMemoryPath) {
                // Reuse SQLite's existing WAL index when present so active readers
                // and writers keep the normal WAL concurrency contract.
                return try StoreSQLiteConnection(
                    path: url.path,
                    mode: .regular(readOnly: true, create: false)
                )
            }
            return try StoreSQLiteConnection(path: url.path, mode: .walSchemaAdmission)
        }
        return try StoreSQLiteConnection(
            path: url.path,
            mode: .regular(readOnly: true, create: false)
        )
    }

    static func currentSchemaReference() throws -> StoreSQLiteConnection {
        let reference = try StoreSQLiteConnection(
            path: ":memory:",
            mode: .regular(readOnly: false, create: true)
        )
        try reference.executeScript(sqliteSessionSchema)
        return reference
    }

    private init(path: String, mode: OpenMode) throws {
        if case .walSchemaAdmission = mode {
            preserveExistingWALOnClose = try Self.inspectWALSidecar(at: path + "-wal").exists
            checkpointWALOnClose = !preserveExistingWALOnClose
        }

        let readOnly: Bool
        let create: Bool
        switch mode {
        case .regular(let isReadOnly, let shouldCreate):
            readOnly = isReadOnly
            create = shouldCreate
        case .walSchemaAdmission:
            readOnly = false
            create = false
        }
        let access = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let flags = access | (create && !readOnly ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = errorMessage
            if let handle {
                sqlite3_close_v2(handle)
                self.handle = nil
            }
            throw AgentError.persistenceFailure(
                "Unable to open SQLite session store: \(message)"
            )
        }

        sqlite3_extended_result_codes(handle, 1)
        do {
            switch mode {
            case .regular:
                try executeScript(
                    """
                    PRAGMA foreign_keys = ON;
                    PRAGMA busy_timeout = 5000;
                    PRAGMA synchronous = FULL;
                    """
                )
            case .walSchemaAdmission:
                try execute("PRAGMA locking_mode = EXCLUSIVE")
                if !preserveExistingWALOnClose,
                   try Self.inspectWALSidecar(at: path + "-wal").mayContainFrames {
                    // A writer may have committed after the first sidecar check.
                    preserveExistingWALOnClose = true
                    checkpointWALOnClose = false
                }
                let configResult = nativeAgentSQLiteSetCheckpointOnClose(
                    handle,
                    preserveExistingWALOnClose ? 0 : 1
                )
                guard configResult == SQLITE_OK else {
                    throw failure("Unable to configure WAL close policy during store admission")
                }
                try executeScript(
                    """
                    PRAGMA query_only = ON;
                    PRAGMA foreign_keys = ON;
                    PRAGMA busy_timeout = 5000;
                    PRAGMA synchronous = FULL;
                    """
                )
            }
        } catch {
            let initializationError = error
            var closePreparationError: (any Error)?
            if checkpointWALOnClose {
                do { try prepareWALForSQLiteClose() }
                catch { closePreparationError = error }
            }
            let closeResult = sqlite3_close(handle)
            if closeResult == SQLITE_OK {
                self.handle = nil
            } else {
                let closeError = errorMessage
                _ = sqlite3_close_v2(handle)
                self.handle = nil
                throw AgentError.persistenceFailure(
                    "SQLite inspection initialization failed [\(initializationError.localizedDescription)] " +
                    "and close failed [\(closeError)]."
                )
            }
            if let closePreparationError {
                throw AgentError.persistenceFailure(
                    "SQLite inspection initialization failed [\(initializationError.localizedDescription)] " +
                    "and WAL close preparation failed [\(closePreparationError.localizedDescription)]."
                )
            }
            throw error
        }
    }

    private static func databaseHeaderUsesWAL(at url: URL) throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AgentError.persistenceFailure(
                "Unable to read the SQLite session-store header: \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: 20) ?? Data()
        } catch {
            throw AgentError.persistenceFailure(
                "Unable to read the SQLite session-store header: \(error.localizedDescription)"
            )
        }
        guard header.count == 20,
              header.prefix(16).elementsEqual(Data("SQLite format 3\0".utf8))
        else {
            return false
        }
        // The header records rollback-journal mode as 1 and WAL mode as 2. Treat
        // either version byte set to 2 as WAL so malformed headers take the safer path.
        return header[18] == 2 || header[19] == 2
    }

    private struct WALSidecarState {
        let exists: Bool
        let mayContainFrames: Bool
    }

    private static func inspectWALSidecar(at path: String) throws -> WALSidecarState {
        #if canImport(Darwin)
        var info = Darwin.stat()
        let status = path.withCString { Darwin.lstat($0, &info) }
        let notFound = Darwin.ENOENT
        let typeMask = Darwin.S_IFMT
        let regularFile = Darwin.S_IFREG
        #else
        var info = Glibc.stat()
        let status = path.withCString { Glibc.lstat($0, &info) }
        let notFound = Glibc.ENOENT
        let typeMask = Glibc.S_IFMT
        let regularFile = Glibc.S_IFREG
        #endif
        guard status == 0 else {
            guard errno == notFound else {
                throw AgentError.persistenceFailure("Unable to inspect the SQLite WAL sidecar.")
            }
            return WALSidecarState(exists: false, mayContainFrames: false)
        }
        let isRegular = (info.st_mode & mode_t(typeMask)) == mode_t(regularFile)
        // A WAL header is 32 bytes. Any other nonempty size, or a non-regular
        // sidecar, is treated as existing state whose contents must be preserved.
        return WALSidecarState(
            exists: true,
            mayContainFrames: !isRegular || (info.st_size != 0 && info.st_size != 32)
        )
    }

    private func prepareWALForSQLiteClose() throws {
        try execute("PRAGMA query_only = OFF")
        _ = try query("SELECT 1 FROM sqlite_master LIMIT 1")
        let result = nativeAgentSQLiteSetPersistentWAL(handle, 0)
        guard result == SQLITE_OK else {
            throw failure("Unable to disable persistent WAL before SQLite inspection close")
        }
    }

    func finishSchemaPreflight() throws {
        guard let handle else {
            return
        }
        var closePreparationError: (any Error)?
        if checkpointWALOnClose {
            do { try prepareWALForSQLiteClose() }
            catch { closePreparationError = error }
        }
        let result = sqlite3_close(handle)
        if result == SQLITE_OK {
            self.handle = nil
        }
        guard result == SQLITE_OK else {
            if let closePreparationError {
                throw AgentError.persistenceFailure(
                    "WAL close preparation failed [\(closePreparationError.localizedDescription)] " +
                    "and SQLite close failed [\(errorMessage)]."
                )
            }
            throw failure("Unable to close SQLite session-store inspection connection")
        }
        if let closePreparationError {
            throw AgentError.persistenceFailure(
                "Unable to prepare SQLite WAL cleanup before inspection close: " +
                closePreparationError.localizedDescription
            )
        }
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func executeScript(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let detail: String
            if let errorPointer {
                detail = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else {
                detail = errorMessage
            }
            throw AgentError.persistenceFailure(
                "Unable to execute SQLite schema operation: \(detail)"
            )
        }
    }

    func execute(
        _ sql: String,
        parameters: [StoreSQLValue] = []
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw failure("Unable to execute SQLite statement")
        }
    }

    func query(
        _ sql: String,
        parameters: [StoreSQLValue] = []
    ) throws -> [StoreSQLRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        var rows: [StoreSQLRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(StoreSQLRow(values: readColumns(from: statement)))
            case SQLITE_DONE:
                return rows
            default:
                throw failure("Unable to query SQLite session store")
            }
        }
    }

    func changes() -> Int {
        Int(sqlite3_changes(handle))
    }

    func inTransaction<T>(_ operation: () throws -> T) throws -> T {
        guard transactionActive == false else {
            throw AgentError.persistenceFailure(
                "Nested SQLite session-store transactions are not supported."
            )
        }

        try execute("BEGIN IMMEDIATE")
        transactionActive = true

        do {
            let result = try operation()
            try execute("COMMIT")
            transactionActive = false
            return result
        } catch {
            let primaryError = error
            do {
                try execute("ROLLBACK")
                transactionActive = false
            } catch {
                transactionActive = false
                throw AgentError.persistenceFailure(
                    "SQLite transaction failed [\(primaryError.localizedDescription)] " +
                    "and rollback also failed [\(error.localizedDescription)]."
                )
            }
            throw primaryError
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw failure("Unable to prepare SQLite statement")
        }
        return statement
    }

    private func bind(
        _ parameters: [StoreSQLValue],
        to statement: OpaquePointer?
    ) throws {
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32

            switch parameter {
            case .text(let value):
                result = value.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }

            guard result == SQLITE_OK else {
                throw failure("Unable to bind SQLite parameter \(index)")
            }
        }
    }

    private func readColumns(from statement: OpaquePointer?) -> [StoreSQLValue] {
        let count = sqlite3_column_count(statement)
        var values: [StoreSQLValue] = []
        values.reserveCapacity(Int(count))

        for index in 0..<count {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(statement, index)))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(statement, index)))
            case SQLITE_TEXT:
                let value = sqlite3_column_text(statement, index)
                    .map { String(cString: $0) } ?? ""
                values.append(.text(value))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                if count == 0 {
                    values.append(.blob(Data()))
                } else if let bytes = sqlite3_column_blob(statement, index) {
                    values.append(.blob(Data(bytes: bytes, count: count)))
                } else {
                    values.append(.blob(Data()))
                }
            default:
                values.append(.null)
            }
        }
        return values
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    }

    private func failure(_ context: String) -> AgentError {
        AgentError.persistenceFailure("\(context): \(errorMessage)")
    }
}
