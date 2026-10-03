import Foundation
import NativeAgentDomain

extension SQLiteSessionStore {
    func createSessionTransaction(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) throws {
        let sessionID = try ValidatedSessionID(snapshot.sessionID)
        try snapshot.validateState()
        try validateArtifactPayloads(snapshot.artifacts)
        try validateOwnedRecords(
            events: events,
            effects: effects,
            sessionID: sessionID
        )

        try fileManager.createDirectory(
            at: layout.sessionRootURL(sessionID: sessionID.rawValue),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: layout.artifactsDirectoryURL(sessionID: sessionID.rawValue),
            withIntermediateDirectories: true
        )

        try requiredDatabase.inTransaction {
            try insertSessionHeader(snapshot)
            try insert(messages: snapshot.messages, sessionID: sessionID.rawValue, startingAt: 0)
            try insert(artifacts: snapshot.artifacts, sessionID: sessionID.rawValue, startingAt: 0)
            try insert(events: events)
            try insert(effects: effects)
        }
    }

    func commitTransaction(_ transaction: SessionPersistenceTransaction) throws {
        let sessionID = try validateCommitTransaction(transaction)
        try requiredDatabase.inTransaction {
            try applyCommitTransaction(transaction, sessionID: sessionID.rawValue)
        }
    }

    func commitForkTransaction(
        _ transaction: SessionForkPersistenceTransaction
    ) throws {
        let sourceSessionID = try validateCommitTransaction(transaction.source)
        let targetSessionID = try ValidatedSessionID(transaction.target.sessionID)
        guard sourceSessionID.rawValue != targetSessionID.rawValue else {
            throw AgentError.persistenceFailure(
                "A fork target must differ from its source session."
            )
        }
        try transaction.target.validateState()
        try validateArtifactPayloads(transaction.target.artifacts)
        try validateOwnedRecords(
            events: transaction.targetEvents,
            effects: transaction.targetEffects,
            sessionID: targetSessionID
        )

        try fileManager.createDirectory(
            at: layout.sessionRootURL(sessionID: targetSessionID.rawValue),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: layout.artifactsDirectoryURL(sessionID: targetSessionID.rawValue),
            withIntermediateDirectories: true
        )

        try requiredDatabase.inTransaction {
            guard try sessionRevision(sessionID: targetSessionID.rawValue) == nil else {
                throw AgentError.persistenceFailure(
                    "Session already exists: \(targetSessionID.rawValue)."
                )
            }
            try applyCommitTransaction(
                transaction.source,
                sessionID: sourceSessionID.rawValue
            )
            try insertSessionHeader(transaction.target)
            try insert(
                messages: transaction.target.messages,
                sessionID: targetSessionID.rawValue,
                startingAt: 0
            )
            try insert(
                artifacts: transaction.target.artifacts,
                sessionID: targetSessionID.rawValue,
                startingAt: 0
            )
            try insert(events: transaction.targetEvents)
            try insert(effects: transaction.targetEffects)
        }
    }

    private func validateCommitTransaction(
        _ transaction: SessionPersistenceTransaction
    ) throws -> ValidatedSessionID {
        let snapshot = transaction.snapshot
        let delta = transaction.delta
        let sessionID = try ValidatedSessionID(snapshot.sessionID)
        try snapshot.validateState()
        try validateOwnedRecords(
            events: transaction.events,
            effects: transaction.effects,
            sessionID: sessionID
        )
        guard delta.expectedRevision < Int64.max,
              snapshot.revision == delta.expectedRevision + 1 else {
            throw AgentError.persistenceFailure(
                "Session \(sessionID.rawValue) has an invalid revision transition " +
                "\(delta.expectedRevision)->\(snapshot.revision)."
            )
        }

        try validate(delta: delta, against: snapshot)
        switch delta.artifacts {
        case .unchanged:
            break
        case .append(_, let artifacts), .replace(let artifacts):
            try validateArtifactPayloads(artifacts)
        }
        return sessionID
    }

    private func validateOwnedRecords(
        events: [SessionEvent],
        effects: [EffectRecord],
        sessionID: ValidatedSessionID
    ) throws {
        for event in events {
            try event.validateState()
            let eventSessionID = try ValidatedSessionID(event.sessionID)
            guard eventSessionID.rawValue == sessionID.rawValue else {
                throw AgentError.persistenceFailure(
                    "Session event \(event.id) belongs to another session."
                )
            }
        }
        for effect in effects {
            let effectSessionID = try ValidatedSessionID(effect.sessionID)
            guard effectSessionID.rawValue == sessionID.rawValue else {
                throw AgentError.persistenceFailure(
                    "Effect receipt \(effect.scope.rawValue)/\(effect.key) " +
                    "belongs to another session."
                )
            }
        }
    }

    private func applyCommitTransaction(
        _ transaction: SessionPersistenceTransaction,
        sessionID: String
    ) throws {
        let snapshot = transaction.snapshot
        let delta = transaction.delta
        guard let current = try sessionCountsAndRevision(sessionID: sessionID) else {
            throw AgentError.sessionNotFound(sessionID)
        }
        guard current.revision == delta.expectedRevision else {
            throw AgentError.persistenceFailure(
                "Stale session revision for \(sessionID): " +
                "expected \(delta.expectedRevision), found \(current.revision)."
            )
        }
        try validateResultCounts(
            delta: delta,
            snapshot: snapshot,
            persistedMessageCount: current.messageCount,
            persistedArtifactCount: current.artifactCount
        )

        try apply(
            delta.messages,
            sessionID: sessionID,
            persistedCount: current.messageCount
        )
        try apply(
            delta.artifacts,
            sessionID: sessionID,
            persistedCount: current.artifactCount
        )
        try updateSessionHeader(snapshot, expectedRevision: delta.expectedRevision)
        try insert(events: transaction.events)
        try insert(effects: transaction.effects)
    }

    func loadSessionSnapshot(sessionID: String) throws -> SessionSnapshot? {
        let validated = try ValidatedSessionID(sessionID)
        let rows = try requiredDatabase.query(
            """
            SELECT
                revision,
                schema_version,
                title,
                status,
                created_at,
                updated_at,
                provider_id,
                model_id,
                metadata,
                context_checkpoint,
                wait_state,
                failure,
                last_signal,
                message_count,
                artifact_count
            FROM sessions
            WHERE session_id = ?
            """,
            parameters: [.text(validated.rawValue)]
        )
        guard let row = rows.first else { return nil }

        let schemaVersion = try row.text(1)
        guard schemaVersion == SessionSnapshot.currentSchemaVersion else {
            throw AgentError.persistenceFailure(
                "Unsupported durable session schema version: \(schemaVersion)."
            )
        }

        let messageRows = try requiredDatabase.query(
            """
            SELECT payload
            FROM session_messages
            WHERE session_id = ?
            ORDER BY ordinal ASC
            """,
            parameters: [.text(validated.rawValue)]
        )
        let artifactRows = try requiredDatabase.query(
            """
            SELECT payload
            FROM session_artifacts
            WHERE session_id = ?
            ORDER BY ordinal ASC
            """,
            parameters: [.text(validated.rawValue)]
        )

        let expectedMessageCount = try integerCount(row.integer(13), field: "message")
        let expectedArtifactCount = try integerCount(row.integer(14), field: "artifact")
        guard messageRows.count == expectedMessageCount,
              artifactRows.count == expectedArtifactCount else {
            throw AgentError.persistenceFailure(
                "Session \(validated.rawValue) row counts do not match durable records."
            )
        }

        let statusRaw = try row.text(3)
        guard let status = SessionStatus(rawValue: statusRaw) else {
            throw AgentError.persistenceFailure(
                "Session \(validated.rawValue) has unknown status \(statusRaw)."
            )
        }

        let metadata = try StoreCodecs.decode(
            [String: JSONValue].self,
            from: row.blob(8)
        )
        let waitState: SessionWaitState? = try decodeOptional(
            SessionWaitState.self,
            data: row.optionalBlob(10)
        )
        let failure: SessionFailure? = try decodeOptional(
            SessionFailure.self,
            data: row.optionalBlob(11)
        )
        let lastSignal: SessionSignal? = try decodeOptional(
            SessionSignal.self,
            data: row.optionalBlob(12)
        )
        let contextCheckpoint: SessionContextCheckpoint? = try decodeOptional(
            SessionContextCheckpoint.self,
            data: row.optionalBlob(9)
        )

        let snapshot = SessionSnapshot(
            schemaVersion: schemaVersion,
            revision: try row.integer(0),
            sessionID: validated.rawValue,
            title: try row.optionalText(2),
            status: status,
            createdAt: Date(timeIntervalSince1970: try row.real(4)),
            updatedAt: Date(timeIntervalSince1970: try row.real(5)),
            messages: try messageRows.map {
                try StoreCodecs.decode(AgentMessage.self, from: $0.blob(0))
            },
            artifacts: try artifactRows.map {
                try StoreCodecs.decode(ArtifactRecord.self, from: $0.blob(0))
            },
            providerID: try row.optionalText(6),
            modelID: try row.optionalText(7),
            metadata: metadata,
            contextCheckpoint: contextCheckpoint,
            waitState: waitState,
            failure: failure,
            lastSignal: lastSignal
        )
        try snapshot.validateState()
        return snapshot
    }

    func sessionRevision(sessionID: String) throws -> Int64? {
        let rows = try requiredDatabase.query(
            "SELECT revision FROM sessions WHERE session_id = ?",
            parameters: [.text(sessionID)]
        )
        return try rows.first?.integer(0)
    }

    private func sessionCountsAndRevision(
        sessionID: String
    ) throws -> (revision: Int64, messageCount: Int, artifactCount: Int)? {
        let rows = try requiredDatabase.query(
            """
            SELECT revision, message_count, artifact_count
            FROM sessions
            WHERE session_id = ?
            """,
            parameters: [.text(sessionID)]
        )
        guard let row = rows.first else { return nil }
        return (
            try row.integer(0),
            try integerCount(row.integer(1), field: "message"),
            try integerCount(row.integer(2), field: "artifact")
        )
    }

    private func insertSessionHeader(_ snapshot: SessionSnapshot) throws {
        do {
            try requiredDatabase.execute(
                """
                INSERT INTO sessions(
                    session_id,
                    revision,
                    schema_version,
                    title,
                    status,
                    created_at,
                    updated_at,
                    provider_id,
                    model_id,
                    metadata,
                    context_checkpoint,
                    wait_state,
                    failure,
                    last_signal,
                    message_count,
                    artifact_count
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: try headerParameters(snapshot)
            )
        } catch {
            if try sessionRevision(sessionID: snapshot.sessionID) != nil {
                throw AgentError.persistenceFailure(
                    "Session already exists: \(snapshot.sessionID)."
                )
            }
            throw error
        }
    }

    private func updateSessionHeader(
        _ snapshot: SessionSnapshot,
        expectedRevision: Int64
    ) throws {
        var parameters = Array(try headerParameters(snapshot).dropFirst())
        parameters.append(.text(snapshot.sessionID))
        parameters.append(.integer(expectedRevision))

        try requiredDatabase.execute(
            """
            UPDATE sessions
            SET
                revision = ?,
                schema_version = ?,
                title = ?,
                status = ?,
                created_at = ?,
                updated_at = ?,
                provider_id = ?,
                model_id = ?,
                metadata = ?,
                context_checkpoint = ?,
                wait_state = ?,
                failure = ?,
                last_signal = ?,
                message_count = ?,
                artifact_count = ?
            WHERE session_id = ? AND revision = ?
            """,
            parameters: parameters
        )
        guard try requiredDatabase.changes() == 1 else {
            throw AgentError.persistenceFailure(
                "Session \(snapshot.sessionID) changed during commit."
            )
        }
    }

    private func headerParameters(
        _ snapshot: SessionSnapshot
    ) throws -> [StoreSQLValue] {
        [
            .text(snapshot.sessionID),
            .integer(snapshot.revision),
            .text(snapshot.schemaVersion),
            snapshot.title.map(StoreSQLValue.text) ?? .null,
            .text(snapshot.status.rawValue),
            .real(snapshot.createdAt.timeIntervalSince1970),
            .real(snapshot.updatedAt.timeIntervalSince1970),
            snapshot.providerID.map(StoreSQLValue.text) ?? .null,
            snapshot.modelID.map(StoreSQLValue.text) ?? .null,
            .blob(try StoreCodecs.encode(snapshot.metadata)),
            try snapshot.contextCheckpoint.map {
                .blob(try StoreCodecs.encode($0))
            } ?? .null,
            try snapshot.waitState.map { .blob(try StoreCodecs.encode($0)) } ?? .null,
            try snapshot.failure.map { .blob(try StoreCodecs.encode($0)) } ?? .null,
            try snapshot.lastSignal.map { .blob(try StoreCodecs.encode($0)) } ?? .null,
            .integer(Int64(snapshot.messages.count)),
            .integer(Int64(snapshot.artifacts.count)),
        ]
    }

    private func validate(
        delta: SessionPersistenceDelta,
        against snapshot: SessionSnapshot
    ) throws {
        switch delta.messages {
        case .unchanged:
            break
        case .append(let startingAt, let messages):
            guard startingAt >= 0,
                  startingAt <= snapshot.messages.count,
                  snapshot.messages[startingAt...].elementsEqual(messages) else {
                throw AgentError.persistenceFailure(
                    "Session message append delta does not match the snapshot."
                )
            }
        case .replace(let messages):
            guard messages == snapshot.messages else {
                throw AgentError.persistenceFailure(
                    "Session message replacement does not match the snapshot."
                )
            }
        }

        switch delta.artifacts {
        case .unchanged:
            break
        case .append(let startingAt, let artifacts):
            guard startingAt >= 0,
                  startingAt <= snapshot.artifacts.count,
                  snapshot.artifacts[startingAt...].elementsEqual(artifacts) else {
                throw AgentError.persistenceFailure(
                    "Session artifact append delta does not match the snapshot."
                )
            }
        case .replace(let artifacts):
            guard artifacts == snapshot.artifacts else {
                throw AgentError.persistenceFailure(
                    "Session artifact replacement does not match the snapshot."
                )
            }
        }
    }

    private func validateArtifactPayloads(
        _ artifacts: [ArtifactRecord]
    ) throws {
        for artifact in artifacts {
            let url = try validateArtifactURL(for: artifact)
            try StoreArtifactIntegrity.validatePayload(at: url, record: artifact)
            try dataPolicy.apply(to: url, fileManager: fileManager)
        }
    }

    private func validateResultCounts(
        delta: SessionPersistenceDelta,
        snapshot: SessionSnapshot,
        persistedMessageCount: Int,
        persistedArtifactCount: Int
    ) throws {
        let expectedMessageCount: Int
        switch delta.messages {
        case .unchanged:
            expectedMessageCount = persistedMessageCount
        case .append(let startingAt, let messages):
            guard startingAt == persistedMessageCount,
                  messages.count <= Int.max - persistedMessageCount else {
                throw AgentError.persistenceFailure(
                    "Session message append count is invalid."
                )
            }
            expectedMessageCount = persistedMessageCount + messages.count
        case .replace(let messages):
            expectedMessageCount = messages.count
        }

        let expectedArtifactCount: Int
        switch delta.artifacts {
        case .unchanged:
            expectedArtifactCount = persistedArtifactCount
        case .append(let startingAt, let artifacts):
            guard startingAt == persistedArtifactCount,
                  artifacts.count <= Int.max - persistedArtifactCount else {
                throw AgentError.persistenceFailure(
                    "Session artifact append count is invalid."
                )
            }
            expectedArtifactCount = persistedArtifactCount + artifacts.count
        case .replace(let artifacts):
            expectedArtifactCount = artifacts.count
        }

        guard snapshot.messages.count == expectedMessageCount,
              snapshot.artifacts.count == expectedArtifactCount else {
            throw AgentError.persistenceFailure(
                "Session delta result counts do not match the durable rows."
            )
        }
    }

    private func apply(
        _ change: SessionMessagePersistence,
        sessionID: String,
        persistedCount: Int
    ) throws {
        switch change {
        case .unchanged:
            return
        case .append(let startingAt, let messages):
            guard startingAt == persistedCount else {
                throw AgentError.persistenceFailure(
                    "Message append expected index \(startingAt), found \(persistedCount)."
                )
            }
            try insert(messages: messages, sessionID: sessionID, startingAt: startingAt)
        case .replace(let messages):
            try requiredDatabase.execute(
                "DELETE FROM session_messages WHERE session_id = ?",
                parameters: [.text(sessionID)]
            )
            try insert(messages: messages, sessionID: sessionID, startingAt: 0)
        }
    }

    private func apply(
        _ change: SessionArtifactPersistence,
        sessionID: String,
        persistedCount: Int
    ) throws {
        switch change {
        case .unchanged:
            return
        case .append(let startingAt, let artifacts):
            guard startingAt == persistedCount else {
                throw AgentError.persistenceFailure(
                    "Artifact append expected index \(startingAt), found \(persistedCount)."
                )
            }
            try insert(artifacts: artifacts, sessionID: sessionID, startingAt: startingAt)
        case .replace(let artifacts):
            try requiredDatabase.execute(
                "DELETE FROM session_artifacts WHERE session_id = ?",
                parameters: [.text(sessionID)]
            )
            try insert(artifacts: artifacts, sessionID: sessionID, startingAt: 0)
        }
    }

    private func insert(
        messages: [AgentMessage],
        sessionID: String,
        startingAt: Int
    ) throws {
        for (offset, message) in messages.enumerated() {
            try requiredDatabase.execute(
                """
                INSERT INTO session_messages(session_id, ordinal, message_id, payload)
                VALUES(?, ?, ?, ?)
                """,
                parameters: [
                    .text(sessionID),
                    .integer(Int64(startingAt + offset)),
                    .text(message.id),
                    .blob(try StoreCodecs.encode(message)),
                ]
            )
        }
    }

    private func insert(
        artifacts: [ArtifactRecord],
        sessionID: String,
        startingAt: Int
    ) throws {
        for (offset, artifact) in artifacts.enumerated() {
            guard artifact.sessionID == sessionID else {
                throw AgentError.persistenceFailure(
                    "Artifact \(artifact.id) belongs to another session."
                )
            }
            try requiredDatabase.execute(
                """
                INSERT INTO session_artifacts(
                    session_id, ordinal, artifact_id, filename, payload
                ) VALUES(?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(sessionID),
                    .integer(Int64(startingAt + offset)),
                    .text(artifact.id),
                    .text(artifact.filename),
                    .blob(try StoreCodecs.encode(artifact)),
                ]
            )
        }
    }

    func insert(events: [SessionEvent]) throws {
        for event in events {
            try event.validateState()
            _ = try ValidatedSessionID(event.sessionID)
            try ensureSessionExists(event.sessionID)
            try requiredDatabase.execute(
                """
                INSERT INTO session_events(
                    session_id, event_id, kind, created_at, payload
                ) VALUES(?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(event.sessionID),
                    .text(event.id),
                    .text(event.kind.rawValue),
                    .real(event.createdAt.timeIntervalSince1970),
                    .blob(try StoreCodecs.encode(event)),
                ]
            )
        }
    }

    func insert(effects: [EffectRecord]) throws {
        for effect in effects {
            _ = try ValidatedSessionID(effect.sessionID)
            _ = try ValidatedEffectScope(effect.scope.rawValue)
            _ = try ValidatedEffectKey(effect.key)
            try effect.validateState()
            try ensureSessionExists(effect.sessionID)
            if let existing = try persistedEffect(
                sessionID: effect.sessionID,
                scope: effect.scope,
                key: effect.key
            ) {
                try effect.validateReplacement(of: existing)
            }
            try requiredDatabase.execute(
                """
                INSERT INTO session_effects(
                    session_id, scope, effect_key, status, payload
                ) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(session_id, scope, effect_key)
                DO UPDATE SET status = excluded.status, payload = excluded.payload
                """,
                parameters: [
                    .text(effect.sessionID),
                    .text(effect.scope.rawValue),
                    .text(effect.key),
                    .text(effect.status.rawValue),
                    .blob(try StoreCodecs.encode(effect)),
                ]
            )
        }
    }

    private func persistedEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) throws -> EffectRecord? {
        let rows = try requiredDatabase.query(
            """
            SELECT payload
            FROM session_effects
            WHERE session_id = ? AND scope = ? AND effect_key = ?
            """,
            parameters: [
                .text(sessionID),
                .text(scope.rawValue),
                .text(key),
            ]
        )
        guard let row = rows.first else { return nil }
        let record = try StoreCodecs.decode(EffectRecord.self, from: row.blob(0))
        guard record.sessionID == sessionID,
              record.scope == scope,
              record.key == key else {
            throw AgentError.persistenceFailure(
                "SQLite effect record does not match its primary key."
            )
        }
        return record
    }

    private func ensureSessionExists(_ sessionID: String) throws {
        let rows = try requiredDatabase.query(
            "SELECT 1 FROM sessions WHERE session_id = ? LIMIT 1",
            parameters: [.text(sessionID)]
        )
        guard rows.isEmpty == false else {
            throw AgentError.sessionNotFound(sessionID)
        }
    }

    private func decodeOptional<T: Decodable>(
        _ type: T.Type,
        data: Data?
    ) throws -> T? {
        guard let data else { return nil }
        return try StoreCodecs.decode(type, from: data)
    }

    func integerCount(_ value: Int64, field: String) throws -> Int {
        guard value >= 0, value <= Int64(Int.max) else {
            throw AgentError.persistenceFailure(
                "SQLite \(field) count is outside the supported range."
            )
        }
        return Int(value)
    }
}
