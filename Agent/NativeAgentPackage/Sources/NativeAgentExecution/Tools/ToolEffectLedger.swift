import Foundation
import NativeAgentDomain

/// Async effect shell around the pure `ToolEffectLedgerPolicy`.
struct ToolEffectLedger: Sendable {
    enum Decision: Sendable {
        case execute
        case replay(message: AgentMessage, artifacts: [ArtifactRecord])
        case block(code: ToolFailureCode, message: String)
    }

    let store: (any EffectLedgerStore)?
    let now: @Sendable () -> Date

    func decision(
        for call: ToolCall,
        definition: ToolDefinition,
        sessionID: String
    ) async throws -> Decision {
        guard ToolEffectLedgerPolicy.shouldTrack(definition), let store else {
            return .execute
        }
        let record = try await loadEffect(
            from: store,
            sessionID: sessionID,
            key: call.id
        )
        return try ToolEffectLedgerPolicy.decision(
            record: record,
            call: call,
            definition: definition,
            sessionID: sessionID
        )
    }

    func record(
        for call: ToolCall,
        definition: ToolDefinition,
        sessionID: String
    ) async throws -> EffectRecord? {
        guard ToolEffectLedgerPolicy.shouldTrack(definition), let store else { return nil }
        guard let record = try await loadEffect(
            from: store,
            sessionID: sessionID,
            key: call.id
        ) else {
            return nil
        }
        try ToolEffectLedgerPolicy.validate(
            record: record,
            call: call,
            definition: definition,
            sessionID: sessionID
        )
        return record
    }

    func reconciledCompletedRecord(
        call: ToolCall,
        definition: ToolDefinition,
        sessionID: String,
        message: AgentMessage,
        artifacts: [ArtifactRecord],
        record: EffectRecord
    ) async throws -> EffectRecord? {
        try await makeTerminalRecord(
            call: call,
            definition: definition,
            sessionID: sessionID,
            existingRecord: record,
            outcome: .completed(
                message: message,
                artifacts: artifacts,
                additionalMetadata: [
                    "reconciled": .bool(true),
                    "reconciliationOutcome": .string("completed")
                ]
            )
        )
    }

    func reconciledFailedRecord(
        call: ToolCall,
        definition: ToolDefinition,
        sessionID: String,
        error: String,
        record: EffectRecord
    ) async throws -> EffectRecord? {
        try await makeTerminalRecord(
            call: call,
            definition: definition,
            sessionID: sessionID,
            existingRecord: record,
            outcome: .failed(
                error: error,
                additionalMetadata: [
                    "reconciled": .bool(true),
                    "reconciliationOutcome": .string("failed")
                ]
            )
        )
    }

    @discardableResult
    func markStarted(
        call: ToolCall,
        definition: ToolDefinition,
        sessionID: String
    ) async throws -> EffectRecord? {
        guard ToolEffectLedgerPolicy.shouldTrack(definition), let store else {
            return nil
        }
        let record = try ToolEffectLedgerPolicy.makeStartedRecord(
            call: call,
            definition: definition,
            sessionID: sessionID,
            timestamp: now()
        )
        try await store.saveEffect(record)
        return record
    }

    func completedRecord(
        call: ToolCall,
        definition: ToolDefinition,
        sessionID: String,
        message: AgentMessage,
        artifacts: [ArtifactRecord],
        startedRecord: EffectRecord? = nil
    ) async throws -> EffectRecord? {
        try await makeTerminalRecord(
            call: call,
            definition: definition,
            sessionID: sessionID,
            existingRecord: startedRecord,
            outcome: .completed(message: message, artifacts: artifacts)
        )
    }

    func failedRecord(
        call: ToolCall,
        definition: ToolDefinition,
        sessionID: String,
        error: String,
        startedRecord: EffectRecord? = nil
    ) async throws -> EffectRecord? {
        try await makeTerminalRecord(
            call: call,
            definition: definition,
            sessionID: sessionID,
            existingRecord: startedRecord,
            outcome: .failed(error: error)
        )
    }

    private func makeTerminalRecord(
        call: ToolCall,
        definition: ToolDefinition,
        sessionID: String,
        existingRecord: EffectRecord?,
        outcome: ToolEffectLedgerPolicy.TerminalOutcome
    ) async throws -> EffectRecord? {
        guard ToolEffectLedgerPolicy.shouldTrack(definition), let store else {
            return nil
        }
        let timestamp = now()
        let record: EffectRecord
        if let existingRecord {
            record = existingRecord
        } else if let loaded = try await loadEffect(
            from: store,
            sessionID: sessionID,
            key: call.id
        ) {
            record = loaded
        } else {
            record = try ToolEffectLedgerPolicy.makeStartedRecord(
                call: call,
                definition: definition,
                sessionID: sessionID,
                timestamp: timestamp
            )
        }

        return try ToolEffectLedgerPolicy.makeTerminalRecord(
            from: record,
            call: call,
            definition: definition,
            sessionID: sessionID,
            outcome: outcome,
            timestamp: timestamp
        )
    }
    private func loadEffect(
        from store: any EffectLedgerStore,
        sessionID: String,
        key: String
    ) async throws -> EffectRecord? {
        do {
            return try await store.loadEffect(
                sessionID: sessionID,
                scope: .toolCall,
                key: key
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentError.effectLedgerFailure(
                "Effect ledger read failed for session \(sessionID), tool call \(key): " +
                error.localizedDescription
            )
        }
    }

}
