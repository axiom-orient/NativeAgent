import Foundation
import NativeAgentDomain
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

actor SQLiteSessionStore:
    SessionRuntimeStore,
    RuntimeAtomicSessionForkStore,
    SessionRuntimeAdmissionStore,
    SessionEventStore,
    EffectLedgerStore,
    SessionSummaryStore,
    SessionSummaryLookupStore,
    SessionStateViewStore,
    SessionMessagePageStore,
    SessionQueryStore
{
    let layout: StoreLayout
    let fileManager: FileManager
    let dataPolicy: StoreDataPolicy
    let artifactIDGenerator: @Sendable () -> String
    let sandboxGuard: StoreSandboxGuard

    var database: StoreSQLiteConnection?
    var issuedArtifactIDsBySession: [String: Set<String>] = [:]

    init(
        rootURL: URL,
        dataPolicy: StoreDataPolicy,
        artifactIDGenerator: @escaping @Sendable () -> String
    ) {
        let fileManager = FileManager()
        self.layout = StoreLayout(rootURL: rootURL)
        self.fileManager = fileManager
        self.dataPolicy = dataPolicy
        self.artifactIDGenerator = artifactIDGenerator
        self.sandboxGuard = StoreSandboxGuard(rootURL: rootURL, fileManager: fileManager)
    }

    func prepare() throws {
        guard database == nil else { return }

        try fileManager.createDirectory(at: layout.rootURL, withIntermediateDirectories: true)
        // Serialize bootstrap and preflight without creating a lock file in a
        // store that may need to be rejected unchanged. Kernel custody ends on exit.
        let descriptor = open(layout.rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AgentError.persistenceFailure("Unable to open the session-store preparation lock.")
        }
        defer { _ = close(descriptor) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EAGAIN), ContinuousClock.now < deadline else {
                throw AgentError.persistenceFailure("Unable to acquire the session-store preparation lock.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let manifestIO = StoreManifestIO(layout: layout, fileManager: fileManager)
        let manifest = try manifestIO.loadExistingManifest()
        let existingDatabase = fileManager.fileExists(atPath: layout.databaseURL.path)
        guard existingDatabase == (manifest != nil) else {
            throw AgentError.persistenceFailure("Incomplete session store: database and manifest must both exist.")
        }
        if let manifest {
            guard manifest.schemaVersion == StoreManifest.currentSchemaVersion else {
                throw AgentError.persistenceFailure("Unsupported store manifest schema version \(manifest.schemaVersion).")
            }
            let preflight = try StoreSQLiteConnection.schemaPreflightConnection(at: layout.databaseURL)
            do {
                try validateCurrentSchema(preflight)
            } catch {
                let validationError = error
                do {
                    try preflight.finishSchemaPreflight()
                } catch {
                    throw AgentError.persistenceFailure(
                        "Session-store validation failed [\(validationError.localizedDescription)] " +
                        "and inspection cleanup failed [\(error.localizedDescription)]."
                    )
                }
                throw validationError
            }
            try preflight.finishSchemaPreflight()
        } else if fileManager.fileExists(atPath: layout.sessionsRootURL.path),
                  try fileManager.contentsOfDirectory(atPath: layout.sessionsRootURL.path).isEmpty == false {
            throw AgentError.persistenceFailure("Unversioned session data cannot initialize a new session store.")
        }

        try fileManager.createDirectory(at: layout.configDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.sessionsRootURL, withIntermediateDirectories: true)
        try dataPolicy.apply(to: layout.rootURL, fileManager: fileManager)
        try dataPolicy.apply(to: layout.configDirectoryURL, fileManager: fileManager)
        try dataPolicy.apply(to: layout.sessionsRootURL, fileManager: fileManager)
        let opened = try StoreSQLiteConnection(url: layout.databaseURL, create: !existingDatabase)
        do {
            if existingDatabase {
                try validateCurrentSchema(opened)
            } else {
                try opened.inTransaction {
                    try opened.executeScript(sqliteSessionSchema)
                    try opened.execute("INSERT INTO store_metadata(key, value) VALUES('schema_version', '1')")
                }
                try manifestIO.writeManifest(StoreManifest())
            }
            try opened.executeScript("PRAGMA journal_mode = WAL;")
            try dataPolicy.apply(to: layout.databaseURL, fileManager: fileManager)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: layout.databaseURL.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try dataPolicy.apply(to: sidecar, fileManager: fileManager)
                }
            }
            database = opened
            // Missing DB references do not prove orphan custody: another store
            // may have staged these bytes and still be committing their record.
        } catch {
            database = nil
            throw error
        }
    }

    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) throws {
        try ensurePrepared()
        try createSessionTransaction(snapshot, events: events, effects: effects)
    }

    func loadSnapshot(sessionID: String) throws -> SessionSnapshot? {
        try ensurePrepared()
        return try loadSessionSnapshot(sessionID: sessionID)
    }

    func loadSessionRuntimeAdmission(
        sessionID: String
    ) throws -> SessionRuntimeAdmission? {
        try ensurePrepared()
        let validated = try ValidatedSessionID(sessionID)
        let rows = try requiredDatabase.query(
            """
            SELECT
                s.schema_version,
                s.revision,
                s.message_count,
                LENGTH(s.metadata)
                + COALESCE(LENGTH(s.context_checkpoint), 0)
                + COALESCE(LENGTH(s.wait_state), 0)
                + COALESCE(LENGTH(s.failure), 0)
                + COALESCE(LENGTH(s.last_signal), 0)
                + COALESCE((
                    SELECT SUM(LENGTH(m.payload))
                    FROM session_messages m
                    WHERE m.session_id = s.session_id
                ), 0)
                + COALESCE((
                    SELECT SUM(LENGTH(a.payload))
                    FROM session_artifacts a
                    WHERE a.session_id = s.session_id
                ), 0),
                s.artifact_count
            FROM sessions s
            WHERE s.session_id = ?
            """,
            parameters: [.text(validated.rawValue)]
        )
        guard let row = rows.first else { return nil }
        return SessionRuntimeAdmission(
            schemaVersion: try row.text(0),
            revision: try row.integer(1),
            messageCount: try integerCount(row.integer(2), field: "message"),
            hydrationPayloadBytes: try integerCount(
                row.integer(3),
                field: "session hydration payload byte"
            ),
            artifactCount: try integerCount(row.integer(4), field: "artifact")
        )
    }

    func commit(_ transaction: SessionPersistenceTransaction) throws {
        try ensurePrepared()
        try commitTransaction(transaction)
    }

    func commitFork(_ transaction: SessionForkPersistenceTransaction) throws {
        try ensurePrepared()
        try commitForkTransaction(transaction)
    }

    func loadEvents(sessionID: String) throws -> [SessionEvent] {
        try ensurePrepared()
        let validated = try ValidatedSessionID(sessionID)
        let rows = try requiredDatabase.query(
            """
            SELECT payload
            FROM session_events
            WHERE session_id = ?
            ORDER BY sequence ASC
            """,
            parameters: [.text(validated.rawValue)]
        )
        return try rows.map { row in
            let event = try StoreCodecs.decode(SessionEvent.self, from: row.blob(0))
            try event.validateState()
            guard event.sessionID == validated.rawValue else {
                throw AgentError.persistenceFailure(
                    "SQLite session event does not match its owning session."
                )
            }
            return event
        }
    }

    func saveEffect(_ effect: EffectRecord) throws {
        try ensurePrepared()
        try requiredDatabase.inTransaction {
            try insert(effects: [effect])
        }
    }

    func loadEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) throws -> EffectRecord? {
        try ensurePrepared()
        let validatedSessionID = try ValidatedSessionID(sessionID)
        let validatedScope = try ValidatedEffectScope(scope.rawValue)
        let validatedKey = try ValidatedEffectKey(key)
        let rows = try requiredDatabase.query(
            """
            SELECT payload
            FROM session_effects
            WHERE session_id = ? AND scope = ? AND effect_key = ?
            """,
            parameters: [
                .text(validatedSessionID.rawValue),
                .text(validatedScope.rawValue),
                .text(validatedKey.rawValue),
            ]
        )
        guard let row = rows.first else { return nil }
        let record = try StoreCodecs.decode(EffectRecord.self, from: row.blob(0))
        guard record.sessionID == validatedSessionID.rawValue,
              record.scope.rawValue == validatedScope.rawValue,
              record.key == validatedKey.rawValue else {
            throw AgentError.persistenceFailure(
                "SQLite effect record does not match its primary key."
            )
        }
        try record.validateState()
        return record
    }

    var requiredDatabase: StoreSQLiteConnection {
        get throws {
            guard let database else {
                throw AgentError.persistenceFailure(
                    "SQLite session store has not been prepared."
                )
            }
            return database
        }
    }

    func ensurePrepared() throws {
        if database == nil {
            try prepare()
        }
    }

    private func validateCurrentSchema(_ connection: StoreSQLiteConnection) throws {
        let objects = try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'")
        let tables = Set(try objects.map { try $0.text(0) })
        let required: Set<String> = ["store_metadata", "sessions", "session_messages", "session_artifacts", "session_events", "session_effects"]
        guard tables.subtracting(["sqlite_sequence"]) == required else {
            throw AgentError.persistenceFailure("Unsupported or incomplete SQLite session-store schema.")
        }
        let rows = try connection.query("SELECT value FROM store_metadata WHERE key = 'schema_version'")
        guard rows.count == 1, try rows[0].text(0) == "1" else {
            throw AgentError.persistenceFailure("Unsupported SQLite session-store schema version.")
        }
        // SQLite's stored DDL from the current writer is the single schema contract.
        // PRAGMA column/key metadata alone loses AUTOINCREMENT and PRIMARY KEY DESC.
        // Compare required objects before any mutation of the persisted database.
        let reference = try StoreSQLiteConnection.currentSchemaReference()
        let expectedObjects = try reference.query(
            "SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'"
        )
        for expected in expectedObjects {
            let type = try expected.text(0)
            let name = try expected.text(1)
            let actual = try connection.query(
                "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?",
                parameters: [.text(type), .text(name)]
            )
            guard actual.count == 1, try actual[0].text(0) == expected.text(2) else {
                throw AgentError.persistenceFailure("Incompatible session-store schema object: \(name).")
            }
        }
    }

}
