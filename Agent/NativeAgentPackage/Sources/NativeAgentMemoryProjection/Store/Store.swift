import CSQLite
import Foundation

final class Store {
    let db: any Database
    let workspaceID: String
    let capabilitySnapshot: AgentMemoryCapabilities
    private var transactionState = StoreTransactionState.idle

    convenience init(path: String) throws {
        try self.init(database: DB(path))
    }

    init(database: any Database) throws {
        db = database
        workspaceID = try Self.prepareSchema(on: database)
        capabilitySnapshot = try Self.verifySQLiteCapabilities(on: database)

        // External-content FTS tables can be restored independently of their
        // triggers. Rebuilding at open keeps the derived projection searchable.
        try db.exec("INSERT INTO memory_record_fts(memory_record_fts) VALUES('rebuild')")
        try db.exec("INSERT INTO memory_event_fts(memory_event_fts) VALUES('rebuild')")
    }

    func close() throws { try db.close() }
    static let currentSchemaVersion = MemorySchemaVersion.current

    /// Only validated storage can select a preparation effect.
    private enum SchemaState {
        case empty
        case current(workspaceID: String)
    }

    private static func prepareSchema(on db: any Database) throws -> String {
        try validateBeforeJournalChange(on: db)
        try enableWAL(on: db)
        try db.exec("BEGIN IMMEDIATE")
        do {
            // Re-read under the write lock; never act on the preflight snapshot.
            let workspaceID: String
            switch try schemaState(on: db) {
            case .empty:
                try db.execScript(schemaSQL)
                workspaceID = "workspace_" + UUID().uuidString.lowercased()
                try db.exec(
                    "INSERT INTO memory_schema(workspace_id,schema_version,created_at_ms) VALUES(?,?,?)",
                    [.text(workspaceID), .int(currentSchemaVersion), .int(nowMS())]
                )
            case .current(let identity):
                workspaceID = identity
            }
            try db.exec("COMMIT")
            return workspaceID
        } catch let primary {
            do {
                try db.exec("ROLLBACK")
            } catch let rollback {
                throw AppError.storage(
                    "workspace_identity_rollback_failed",
                    "workspace identity preparation failed and rollback also failed",
                    StoreTransactionRollbackFailure(
                        primary: StoreTransactionFailure(stage: "workspace_identity", error: primary),
                        rollback: StoreTransactionFailure(stage: "rollback", error: rollback)
                    )
                )
            }
            throw primary
        }
    }

    /// Validate one read snapshot before changing the persistent journal mode.
    private static func validateBeforeJournalChange(on db: any Database) throws {
        try db.exec("BEGIN")
        do {
            _ = try schemaState(on: db)
            try db.exec("COMMIT")
        } catch let primary {
            do {
                try db.exec("ROLLBACK")
            } catch let rollback {
                throw AppError.storage(
                    "schema_validation_rollback_failed", "schema validation rollback failed",
                    StoreTransactionRollbackFailure(
                        primary: StoreTransactionFailure(stage: "schema_validation", error: primary),
                        rollback: StoreTransactionFailure(stage: "rollback", error: rollback)
                    )
                )
            }
            throw primary
        }
    }

    /// The single interpretation of persisted schema and identity, with no writes.
    private static func schemaState(on db: any Database) throws -> SchemaState {
        let objects = try db.query("SELECT name,type FROM sqlite_master WHERE type IN ('table','view')")
        let names = try objects.map { try $0.text(0) }
        let tables = try objects.filter { try $0.text(1) == "table" }.map { try $0.text(0) }
        let versionRows = try db.query("PRAGMA user_version")
        guard versionRows.count == 1 else {
            throw AppError.storage("unsupported_schema_version", "memory schema version is unavailable")
        }
        let version = try versionRows[0].int(0)
        guard tables.contains("memory_schema") else {
            guard names.allSatisfy({ $0.hasPrefix("sqlite_") }) else {
                throw AppError.storage("unsupported_schema", "memory database contains foreign objects")
            }
            guard version == 0 else {
                throw AppError.storage("unsupported_schema_version", "empty memory database has a nonzero version")
            }
            return .empty
        }
        guard version == currentSchemaVersion else {
            throw AppError.storage("unsupported_schema_version", "the memory database uses an unsupported schema version")
        }
        guard memoryRequiredTables.allSatisfy(tables.contains) else {
            throw AppError.storage("incomplete_schema", "memory schema is missing required tables")
        }
        let identities = try db.query("SELECT workspace_id,schema_version FROM memory_schema")
        guard identities.count <= 1 else {
            throw AppError.storage("ambiguous_workspace_identity", "memory_schema contains more than one workspace identity")
        }
        guard let identity = identities.first else {
            throw AppError.storage("invalid_workspace_identity", "existing memory database has no workspace identity")
        }
        let workspaceID = try identity.text(0)
        guard !workspaceID.isEmpty else {
            throw AppError.storage("invalid_workspace_identity", "memory workspace identity is empty")
        }
        guard try identity.int(1) == version else {
            throw AppError.storage("unsupported_schema_version", "memory identity and schema versions disagree")
        }
        return .current(workspaceID: workspaceID)
    }

    /// Only SQLITE_BUSY retries this idempotent operation. Each attempt retains
    /// the connection busy timeout; the retry window is not an operation deadline.
    private static func enableWAL(on db: any Database) throws {
        let deadline = ContinuousClock.now.advanced(by: MemorySQLitePolicy.walRetryWindow)
        while true {
            do {
                let rows = try db.query("PRAGMA journal_mode=WAL")
                guard rows.count == 1, try rows[0].text(0) == "wal" else {
                    throw AppError.storage("unsupported_journal_mode", "memory storage requires WAL journal mode")
                }
                return
            } catch let error as AppError {
                guard error.context["sqliteCode"] == String(SQLITE_BUSY), ContinuousClock.now < deadline else {
                    throw error
                }
                Thread.sleep(forTimeInterval: MemorySQLitePolicy.walRetryDelaySeconds)
            }
        }
    }

    private static func verifySQLiteCapabilities(on db: any Database) throws -> AgentMemoryCapabilities {
        guard let versionRow = try db.query("SELECT sqlite_version()").first,
              !(try versionRow.text(0)).isEmpty else {
            throw AppError.storage("unsupported_sqlite_capability", "SQLite version is unavailable")
        }
        let foreignKeys = try db.query("PRAGMA foreign_keys").first.map { try $0.int(0) == 1 } ?? false
        guard foreignKeys else {
            throw AppError.storage("foreign_keys_disabled", "SQLite foreign keys are required")
        }

        try verifyTemporaryProbe(
            on: db,
            createSQL: "CREATE TABLE temp.__native_agent_strict_probe(x TEXT) STRICT",
            dropSQL: "DROP TABLE temp.__native_agent_strict_probe",
            capability: "SQLite STRICT tables"
        )
        try verifyTemporaryProbe(
            on: db,
            createSQL: "CREATE VIRTUAL TABLE temp.__native_agent_fts_probe USING fts5(x)",
            dropSQL: "DROP TABLE temp.__native_agent_fts_probe",
            capability: "SQLite FTS5"
        )
        return AgentMemoryCapabilities(
            sqliteVersion: try versionRow.text(0),
            foreignKeys: true,
            strictTables: true,
            fts5: true
        )
    }

    private static func verifyTemporaryProbe(
        on db: any Database,
        createSQL: String,
        dropSQL: String,
        capability: String
    ) throws {
        do {
            try db.exec(createSQL)
        } catch {
            throw AppError.storage(
                "unsupported_sqlite_capability",
                "\(capability) is required",
                error
            )
        }
        do {
            try db.exec(dropSQL)
        } catch {
            throw AppError.storage(
                "sqlite_probe_cleanup_failed",
                "could not remove the temporary \(capability) probe",
                error
            )
        }
    }

    func inTx(_ f: () throws -> Void) throws {
        switch transactionState {
        case .idle:
            try runRootTransaction(f)
        case .active(let depth):
            try runNestedTransaction(depth: depth, f)
        case .rollbackRequired(let failure):
            throw AppError.storage(
                "transaction_rollback_required",
                "the current transaction already requires rollback",
                failure
            )
        case .poisoned(let failure):
            throw AppError.storage(
                "transaction_poisoned",
                "the database connection cannot start another transaction after rollback failure",
                failure
            )
        }
    }

    private func runRootTransaction(_ body: () throws -> Void) throws {
        try db.exec("BEGIN IMMEDIATE")
        transactionState = .active(depth: 1)

        let bodyError: (any Error)?
        do {
            try body()
            bodyError = nil
        } catch {
            bodyError = error
        }

        switch transactionState {
        case .active(depth: 1):
            if let bodyError {
                try rollbackAndThrow(primary: bodyError, stage: "body")
            } else {
                try commitRootTransaction()
            }

        case .rollbackRequired(let failure):
            let primary = bodyError ?? AppError.storage(
                "transaction_rollback_required",
                "a nested transaction failed even though its error was handled by the caller",
                failure
            )
            try rollbackAndThrow(primary: primary, stage: failure.stage)

        case .poisoned(let failure):
            throw AppError.storage(
                "transaction_poisoned",
                "the database connection became unusable while the transaction was active",
                failure
            )

        case .idle, .active:
            let failure = StoreTransactionFailure(
                stage: "state",
                detail: "invalid transaction state after root body: \(transactionState)"
            )
            transactionState = .poisoned(failure)
            throw AppError.storage(
                "transaction_state_invalid",
                "the transaction state machine reached an invalid root state",
                failure
            )
        }
    }

    private func runNestedTransaction(depth: Int, _ body: () throws -> Void) throws {
        transactionState = .active(depth: depth + 1)
        do {
            try body()
        } catch {
            let failure = StoreTransactionFailure(stage: "nested_body", error: error)
            transactionState = .rollbackRequired(failure)
            throw error
        }

        switch transactionState {
        case .active(let currentDepth) where currentDepth == depth + 1:
            transactionState = .active(depth: depth)
        case .rollbackRequired(let failure):
            throw AppError.storage(
                "transaction_rollback_required",
                "a nested transaction failed and the root transaction must roll back",
                failure
            )
        case .poisoned(let failure):
            throw AppError.storage(
                "transaction_poisoned",
                "the database connection became unusable inside a nested transaction",
                failure
            )
        case .idle, .active:
            let failure = StoreTransactionFailure(
                stage: "state",
                detail: "invalid transaction state after nested body: \(transactionState)"
            )
            transactionState = .poisoned(failure)
            throw AppError.storage(
                "transaction_state_invalid",
                "the transaction state machine reached an invalid nested state",
                failure
            )
        }
    }

    private func commitRootTransaction() throws {
        do {
            try db.exec("COMMIT")
            transactionState = .idle
        } catch {
            try rollbackAndThrow(primary: error, stage: "commit")
        }
    }

    private func rollbackAndThrow(primary: any Error, stage: String) throws -> Never {
        let primaryFailure = StoreTransactionFailure(stage: stage, error: primary)
        do {
            try db.exec("ROLLBACK")
        } catch {
            let rollbackFailure = StoreTransactionFailure(stage: "rollback", error: error)
            transactionState = .poisoned(rollbackFailure)
            throw AppError.storage(
                "transaction_and_rollback_failed",
                "the transaction failed and its rollback also failed",
                StoreTransactionRollbackFailure(primary: primaryFailure, rollback: rollbackFailure)
            )
        }

        transactionState = .idle
        throw primary
    }
}
func openStore(path: String) throws -> Store {
    try Store(path: path)
}
