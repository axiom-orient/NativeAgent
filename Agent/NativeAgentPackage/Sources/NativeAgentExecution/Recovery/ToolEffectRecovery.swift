import Foundation
import NativeAgentDomain

public enum ToolEffectRecoveryDisposition: String, Codable, Sendable, Equatable {
    /// No uncertain mutating receipt exists; normal runtime continuation can execute it.
    case executable
    /// A completed receipt exists and normal runtime continuation can replay it.
    case replayable
    /// The external effect outcome is uncertain and the host must explicitly resolve it.
    case reconciliationRequired = "reconciliation_required"
    /// The pending invocation cannot be matched to a registered tool definition.
    case invalid
}

public struct ToolEffectRecoveryItem: Codable, Sendable, Equatable {
    public let call: ToolCall
    public let definition: ToolDefinition?
    public let effectRecord: EffectRecord?
    public let disposition: ToolEffectRecoveryDisposition
    public let detail: String

    public init(
        call: ToolCall,
        definition: ToolDefinition?,
        effectRecord: EffectRecord?,
        disposition: ToolEffectRecoveryDisposition,
        detail: String
    ) {
        self.call = call
        self.definition = definition
        self.effectRecord = effectRecord
        self.disposition = disposition
        self.detail = detail
    }
}

public struct SessionRecoveryInspection: Codable, Sendable, Equatable {
    public let snapshot: SessionSnapshot
    public let pendingToolEffects: [ToolEffectRecoveryItem]

    public init(
        snapshot: SessionSnapshot,
        pendingToolEffects: [ToolEffectRecoveryItem]
    ) {
        self.snapshot = snapshot
        self.pendingToolEffects = pendingToolEffects
    }

    public var requiresHostReconciliation: Bool {
        pendingToolEffects.contains { $0.disposition == .reconciliationRequired }
    }
}

/// Host-supplied outcome for an external mutating effect whose process was
/// interrupted after the durable `started` receipt was written.
public enum ToolEffectRecoveryResolution: Sendable, Equatable {
    /// The host verified that the external effect completed and supplies its canonical result.
    case completed(ToolResult)
    /// The host verified that the effect did not complete, or elected to terminate it as failed.
    case failed(String)
}

struct ToolEffectRecoveryInspector: Sendable {
    let store: any SessionRuntimeStore
    let registry: ToolRegistry
    let resourceValidator: RuntimeResourceValidator
    let now: @Sendable () -> Date

    func inspect(
        snapshot: SessionSnapshot
    ) async throws -> SessionRecoveryInspection {
        try resourceValidator.validate(snapshot: snapshot)
        let ledger = ToolEffectLedger(
            store: store,
            now: now
        )

        var items: [ToolEffectRecoveryItem] = []
        for call in try PendingToolCallIndex.calls(in: snapshot) {
            guard let definition = registry.definition(named: call.name) else {
                items.append(
                    ToolEffectRecoveryItem(
                        call: call,
                        definition: nil,
                        effectRecord: nil,
                        disposition: .invalid,
                        detail: "No registered tool definition matches \(call.name)."
                    )
                )
                continue
            }

            try ToolCallValidator().validate(call: call, against: definition)
            let record = try await ledger.record(
                for: call,
                definition: definition,
                sessionID: snapshot.sessionID
            )
            let disposition: ToolEffectRecoveryDisposition
            let detail: String
            switch record?.status {
            case .completed:
                disposition = .replayable
                detail = "A completed receipt can be replayed without executing the tool."
            case .started:
                disposition = .reconciliationRequired
                detail = "The external effect may have occurred; automatic re-execution is blocked."
            case .failed:
                disposition = .reconciliationRequired
                detail = "The recorded failure can be confirmed or replaced by a host-verified completion."
            case .none:
                disposition = .executable
                detail = definition.isReadOnly
                    ? "The read-only call can be executed by normal continuation."
                    : "No effect receipt exists; normal continuation can execute the call."
            }
            items.append(
                ToolEffectRecoveryItem(
                    call: call,
                    definition: definition,
                    effectRecord: record,
                    disposition: disposition,
                    detail: detail
                )
            )
        }
        return SessionRecoveryInspection(
            snapshot: snapshot,
            pendingToolEffects: items
        )
    }
}

extension SessionCoordinator {
    func inspectRecovery(
        snapshot: SessionSnapshot
    ) async throws -> SessionRecoveryInspection {
        try await ToolEffectRecoveryInspector(
            store: store,
            registry: registry,
            resourceValidator: resourceValidator,
            now: now
        ).inspect(snapshot: snapshot)
    }

    /// Returns a stable inspection of unresolved tool calls and their durable
    /// effect receipts. The method never executes a tool.
    public func inspectRecovery(sessionID: String) async throws -> SessionRecoveryInspection {
        try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
            return try await inspectRecovery(snapshot: snapshot)
        }
    }

    /// Resolves one uncertain mutating effect without invoking its executor.
    /// The returned snapshot contains a durable tool result/error message; call
    /// `run(sessionID:)` afterwards to continue model execution.
    @discardableResult
    public func resolvePendingToolEffect(
        sessionID: String,
        callID: String,
        resolution: ToolEffectRecoveryResolution
    ) async throws -> SessionSnapshot {
        try await withSessionExecution(sessionID: sessionID) {
            let persistedSnapshot = try await loadExistingSnapshot(sessionID: sessionID)
            return try await ToolEffectRecoveryReconciler(
                store: store,
                registry: registry,
                resourceValidator: resourceValidator,
                configuration: configuration,
                now: now,
                idGenerator: idGenerator,
                snapshotWriter: snapshotWriter,
                toolErrorAppender: toolErrorAppender
            ).reconcile(
                persistedSnapshot: persistedSnapshot,
                sessionID: sessionID,
                callID: callID,
                resolution: resolution
            )
        }
    }

}


struct ToolEffectRecoveryReconciler: Sendable {
    let store: any SessionRuntimeStore
    let registry: ToolRegistry
    let resourceValidator: RuntimeResourceValidator
    let configuration: RuntimeConfiguration
    let now: @Sendable () -> Date
    let idGenerator: @Sendable () -> String
    let snapshotWriter: RuntimeSnapshotWriter
    let toolErrorAppender: RuntimeToolErrorAppender

    func reconcile(
        persistedSnapshot: SessionSnapshot,
        sessionID: String,
        callID: String,
        resolution: ToolEffectRecoveryResolution
    ) async throws -> SessionSnapshot {
        try resourceValidator.validate(snapshot: persistedSnapshot)
        guard persistedSnapshot.status == .running || persistedSnapshot.status == .failed else {
            throw AgentError.invariantViolation(
                "Pending tool effects can only be reconciled in a running or failed session; " +
                "session \(sessionID) is \(persistedSnapshot.status.rawValue)."
            )
        }

        let call = try PendingToolCallIndex.call(id: callID, in: persistedSnapshot)
        guard let definition = registry.definition(named: call.name) else {
            throw AgentError.toolNotFound(call.name)
        }
        guard definition.isReadOnly == false else {
            throw AgentError.invariantViolation(
                "Read-only tool call \(call.id) has no uncertain mutation to reconcile."
            )
        }
        try ToolCallValidator().validate(call: call, against: definition)

        let ledger = ToolEffectLedger(
            store: store,
            now: now
        )
        guard let record = try await ledger.record(
            for: call,
            definition: definition,
            sessionID: persistedSnapshot.sessionID
        ) else {
            throw AgentError.notFound(
                "No effect receipt exists for pending tool call \(call.id)."
            )
        }
        guard record.status == .started || record.status == .failed else {
            throw AgentError.invariantViolation(
                "Tool effect \(call.id) is \(record.status.rawValue), not uncertain."
            )
        }

        // Validate the host-supplied outcome before changing a failed session
        // back to running. A rejected reconciliation attempt must leave the
        // durable failure state untouched.
        let validatedResolution: ToolEffectRecoveryResolution
        switch resolution {
        case .completed(let result):
            guard result.callID == call.id, result.toolName == call.name else {
                throw AgentError.invariantViolation(
                    "Reconciled tool result identity does not match invocation \(call.id)/\(call.name)."
                )
            }
            try resourceValidator.validate(result: result)
            validatedResolution = .completed(result)

        case .failed(let rawReason):
            let bounded = RuntimeSessionFailure.boundedMessage(
                rawReason,
                maximumUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
            ).message
            try resourceValidator.validateFailureReason(bounded)
            guard bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw AgentError.invariantViolation(
                    "Effect reconciliation failure reason must not be empty."
                )
            }
            validatedResolution = .failed(bounded)
        }

        let resumingFailedSession = persistedSnapshot.status == .failed

        let transitions = AgentLoopSnapshotTransitions(
            now: now,
            idGenerator: idGenerator,
            maximumFailureMessageUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
        )

        switch validatedResolution {
        case .completed(let result):
            var metadata = result.metadata
            metadata["effectReconciled"] = .bool(true)
            metadata["effectReconciliationOutcome"] = .string("completed")
            let reconciledResult = result.applying(.metadataChanged(metadata))
            let handler = AgentLoopToolResultHandler(
                store: store,
                transitions: transitions,
                resourceValidator: resourceValidator,
                now: now
            )
            let reduction = try await handler.applySuccessfulResult(
                reconciledResult,
                for: call,
                definition: definition,
                to: persistedSnapshot,
                resumingFailedSession: resumingFailedSession
            )
            let updated = reduction.snapshot
            guard let message = updated.messages.last,
                  message.role == .tool,
                  message.toolCallID == call.id else {
                throw AgentError.invariantViolation(
                    "Effect reconciliation did not produce the expected tool message for \(call.id)."
                )
            }
            let artifacts = Array(
                updated.artifacts.dropFirst(persistedSnapshot.artifacts.count)
            )
            let completedEffect = try await ledger.reconciledCompletedRecord(
                call: call,
                definition: definition,
                sessionID: sessionID,
                message: message,
                artifacts: artifacts,
                record: record
            )
            let entries = reduction.snapshot.messages.last.map {
                [SessionJournal.Entry.toolResult($0)]
            } ?? []
            return try await snapshotWriter.persist(
                reduction,
                effects: [completedEffect].compactMap { $0 },
                journalEntries: entries
            )

        case .failed(let bounded):
            let failedEffect = try await ledger.reconciledFailedRecord(
                call: call,
                definition: definition,
                sessionID: sessionID,
                error: bounded,
                record: record
            )
            return try await toolErrorAppender.append(
                callID: call.id,
                toolName: call.name,
                content: bounded,
                metadata: [
                    "effectReconciled": .bool(true),
                    "effectReconciliationOutcome": .string("failed")
                ],
                definition: definition,
                effects: [failedEffect].compactMap { $0 },
                resumingFailedSession: resumingFailedSession,
                to: persistedSnapshot
            )
        }
}
}
