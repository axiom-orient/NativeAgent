import Foundation
import NativeAgentDomain

struct AgentLoopSnapshotTransitions {
    let now: @Sendable () -> Date
    let idGenerator: @Sendable () -> String
    let maximumFailureMessageUTF8Bytes: Int

    init(
        now: @escaping @Sendable () -> Date,
        idGenerator: @escaping @Sendable () -> String,
        maximumFailureMessageUTF8Bytes: Int = 64 * 1_024
    ) {
        self.now = now
        self.idGenerator = idGenerator
        self.maximumFailureMessageUTF8Bytes = maximumFailureMessageUTF8Bytes
    }

    private func mergedArtifacts(
        existing: [ArtifactRecord],
        incoming: [ArtifactRecord]
    ) -> [ArtifactRecord] {
        guard incoming.isEmpty == false else {
            return existing
        }

        var merged = existing
        merged.reserveCapacity(existing.count + incoming.count)

        var knownIDs = Set(existing.map(\.id))
        for artifact in incoming where knownIDs.insert(artifact.id).inserted {
            merged.append(artifact)
        }

        return merged
    }

    func applyingCompaction(
        _ compaction: CompactionResult,
        to snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        guard let checkpoint = compaction.checkpoint else {
            throw AgentError.invariantViolation(
                "Runtime compaction requires a durable context checkpoint."
            )
        }
        return try SessionReducer.reduce(
            .updateContextCheckpoint(checkpoint, updatedAt: now()),
            state: snapshot
        )
    }

    func appendingAssistantTurn(
        _ turn: ModelTurn,
        containsSensitiveToolCall: Bool = false,
        to snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        try SessionReducer.reduce(
            .append(
                messages: [assistantMessage(for: turn, containsSensitiveToolCall: containsSensitiveToolCall)],
                artifacts: snapshot.artifacts,
                updatedAt: now(),
                reason: .assistantTurnAppended
            ),
            state: snapshot
        )
    }

    /// Persist a model outcome and its next durable lifecycle in one revision.
    /// A continuation prompt is committed with the truncated response so recovery
    /// cannot lose its budget accounting or invoke again without that prompt.
    func recordingAssistantTurn(
        _ turn: ModelTurn,
        containsSensitiveToolCall: Bool,
        continuation: ResponseContinuationController,
        in snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        let message = assistantMessage(for: turn, containsSensitiveToolCall: containsSensitiveToolCall)
        let shouldContinue = turn.toolCalls.isEmpty
            && continuation.shouldContinue(after: turn, snapshot: snapshot)
        let continuationPrompt = shouldContinue ? AgentMessage(
            id: idGenerator(),
            role: .user,
            content: ResponseContinuationMetadata.syntheticPrompt,
            createdAt: now(),
            metadata: ResponseContinuationMetadata.syntheticRequestMetadata
        ) : nil
        return try SessionReducer.reduce(
            .recordAssistantTurn(
                message: message,
                continuationPrompt: continuationPrompt,
                completesSession: turn.toolCalls.isEmpty && !shouldContinue,
                updatedAt: now()
            ),
            state: snapshot
        )
    }

    private func assistantMessage(
        for turn: ModelTurn,
        containsSensitiveToolCall: Bool
    ) -> AgentMessage {
        var metadata = turn.metadata
        if containsSensitiveToolCall {
            metadata["sensitiveData"] = .bool(true)
        }
        return AgentMessage(
            id: idGenerator(),
            role: .assistant,
            contentParts: turn.contentParts,
            createdAt: now(),
            toolCalls: turn.toolCalls,
            metadata: metadata,
            usage: turn.usage,
            responseID: turn.responseID,
            reasoningSummary: turn.reasoningSummary,
            stopReason: turn.stopReason
        )
    }

    func appendingToolError(
        callID: String,
        toolName: String,
        content: String,
        metadata additionalMetadata: [String: JSONValue] = [:],
        definition: ToolDefinition? = nil,
        resumingFailedSession: Bool = false,
        to snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        let bounded = RuntimeSessionFailure.boundedMessage(
            content,
            maximumUTF8Bytes: maximumFailureMessageUTF8Bytes
        )
        var metadata: [String: JSONValue] = ["isError": .bool(true)]
        for (key, value) in additionalMetadata {
            metadata[key] = value
        }
        if bounded.wasTruncated {
            metadata["messageTruncated"] = .bool(true)
            metadata["originalMessageUTF8Bytes"] = .integer(Int64(bounded.originalUTF8Bytes))
        }
        return try appendingToolMessage(
            content: bounded.message,
            callID: callID,
            toolName: toolName,
            metadata: metadata,
            definition: definition,
            resumingFailedSession: resumingFailedSession,
            reason: .toolErrorAppended,
            to: snapshot
        )
    }

    func appendingToolResult(
        _ result: ToolResult,
        definition: ToolDefinition,
        persistedArtifacts: [ArtifactRecord],
        resumingFailedSession: Bool = false,
        to snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        var metadata = result.metadata
        let artifactReferences: [JSONValue] = persistedArtifacts.map { artifact in
            .object([
                "id": .string(artifact.id),
                "filename": .string(artifact.filename),
                "relativePath": .string(artifact.relativePath),
                "mimeType": .string(artifact.mimeType),
                "metadata": .object(artifact.metadata)
            ])
        }
        metadata["isError"] = .bool(result.isError)
        metadata["output"] = result.output
        metadata["artifacts"] = .array(artifactReferences)
        return try appendingToolMessage(
            content: result.renderedContent,
            callID: result.callID,
            toolName: result.toolName,
            metadata: metadata,
            definition: definition,
            artifacts: persistedArtifacts,
            resumingFailedSession: resumingFailedSession,
            reason: .toolResultAppended,
            to: snapshot
        )
    }

    func appendingReplayedToolResult(
        message: AgentMessage,
        definition: ToolDefinition,
        artifacts: [ArtifactRecord],
        to snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        var metadata = message.metadata
        metadata["effectReplayed"] = .bool(true)
        return try appendingToolMessage(
            content: message.content,
            callID: message.toolCallID,
            toolName: message.toolName,
            metadata: metadata,
            definition: definition,
            artifacts: artifacts,
            reason: .toolResultAppended,
            to: snapshot
        )
    }

    private func appendingToolMessage(
        content: String,
        callID: String?,
        toolName: String?,
        metadata: [String: JSONValue],
        definition: ToolDefinition? = nil,
        artifacts: [ArtifactRecord] = [],
        resumingFailedSession: Bool = false,
        reason: SessionMutationReason,
        to snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        let timestamp = now()
        let merged = mergedArtifacts(existing: snapshot.artifacts, incoming: artifacts)
        let message = durableToolMessage(
            content: content,
            callID: callID,
            toolName: toolName,
            metadata: metadata,
            definition: definition,
            createdAt: timestamp
        )
        if resumingFailedSession {
            return try SessionReducer.reduce(
                .resumeAndAppend(
                    messages: [message],
                    artifacts: merged,
                    updatedAt: timestamp,
                    reason: reason
                ),
                state: snapshot
            )
        }
        return try SessionReducer.reduce(
            .append(
                messages: [message],
                artifacts: merged,
                updatedAt: timestamp,
                reason: reason
            ),
            state: snapshot
        )
    }

    private func durableToolMessage(
        content: String,
        callID: String?,
        toolName: String?,
        metadata: [String: JSONValue],
        definition: ToolDefinition?,
        createdAt: Date
    ) -> AgentMessage {
        var durableMetadata = metadata
        if definition?.containsSensitiveData == true {
            durableMetadata["sensitiveData"] = .bool(true)
        }
        return AgentMessage(
            id: idGenerator(),
            role: .tool,
            content: content,
            createdAt: createdAt,
            toolCallID: callID,
            toolName: toolName,
            metadata: durableMetadata
        )
    }

    func markingWaiting(
        _ waitState: SessionWaitState,
        in snapshot: SessionSnapshot
    ) throws -> SessionReduction {
        try SessionReducer.reduce(
            .enterWait(waitState, updatedAt: now()),
            state: snapshot
        )
    }

    func clearingWait(in snapshot: SessionSnapshot) throws -> SessionReduction {
        try SessionReducer.reduce(
            .clearWait(updatedAt: now()),
            state: snapshot
        )
    }

    func markingCompleted(_ snapshot: SessionSnapshot) throws -> SessionReduction {
        try SessionReducer.reduce(
            .complete(updatedAt: now()),
            state: snapshot
        )
    }

    func markingFailed(
        _ snapshot: SessionSnapshot,
        error: any Error,
        interruptedToolCalls: [(id: String, name: String, definition: ToolDefinition?)] = []
    ) throws -> SessionReduction {
        let timestamp = now()
        let failure = RuntimeSessionFailure.make(
            error: error,
            at: timestamp,
            maximumMessageUTF8Bytes: maximumFailureMessageUTF8Bytes
        )
        if interruptedToolCalls.isEmpty == false {
            let messages = interruptedToolCalls.map { call in
                durableToolMessage(
                    content: TranscriptRepair.interruptedToolMessage,
                    callID: call.id,
                    toolName: call.name,
                    metadata: ["isError": .bool(true)],
                    definition: call.definition,
                    createdAt: timestamp
                )
            }
            return try SessionReducer.reduce(
                .appendAndFail(
                    messages: messages,
                    failure: failure,
                    updatedAt: timestamp,
                    reason: .sessionFailed
                ),
                state: snapshot
            )
        }
        return try SessionReducer.reduce(
            .fail(
                failure,
                updatedAt: timestamp,
                reason: .sessionFailed
            ),
            state: snapshot
        )
    }
}

enum RuntimeSessionFailure {
    static func make(
        error: any Error,
        at timestamp: Date,
        maximumMessageUTF8Bytes: Int
    ) -> SessionFailure {
        let failureCode: String
        let rawMessage: String
        var details: [String: JSONValue] = [:]

        if error is CancellationError {
            failureCode = "cancelled"
            rawMessage = "Session execution was cancelled."
        } else if let error = error as? AgentError {
            failureCode = code(for: error)
            rawMessage = error.localizedDescription
        } else if let error = error as? any ModelClientFailure {
            failureCode = error.modelFailureCode
            rawMessage = error.localizedDescription
            details = error.modelFailureDetails
        } else {
            failureCode = "runtime_error"
            if let localizedError = error as? any LocalizedError,
               let errorDescription = localizedError.errorDescription {
                rawMessage = errorDescription
            } else {
                rawMessage = String(describing: error)
            }
            details["type"] = .string(String(reflecting: type(of: error)))
        }

        let bounded = boundedMessage(rawMessage, maximumUTF8Bytes: maximumMessageUTF8Bytes)
        if bounded.wasTruncated {
            details["messageTruncated"] = .bool(true)
            details["originalMessageUTF8Bytes"] = .integer(Int64(bounded.originalUTF8Bytes))
        }

        return SessionFailure(
            code: failureCode,
            message: bounded.message,
            occurredAt: timestamp,
            details: details
        )
    }

    static func boundedMessage(
        _ message: String,
        maximumUTF8Bytes: Int
    ) -> (message: String, wasTruncated: Bool, originalUTF8Bytes: Int) {
        let originalUTF8Bytes = message.utf8.count
        guard originalUTF8Bytes > maximumUTF8Bytes else {
            return (message, false, originalUTF8Bytes)
        }

        var output = ""
        output.reserveCapacity(maximumUTF8Bytes)
        var usedBytes = 0
        for character in message {
            let fragment = String(character)
            let fragmentBytes = fragment.utf8.count
            guard fragmentBytes <= maximumUTF8Bytes - usedBytes else {
                break
            }
            output.append(character)
            usedBytes += fragmentBytes
        }
        return (output, true, originalUTF8Bytes)
    }

    private static func code(for error: AgentError) -> String {
        switch error {
        case .invalidConfiguration: "invalid_configuration"
        case .invalidToolCall: "invalid_tool_call"
        case .toolNotFound: "tool_not_found"
        case .approvalDenied: "approval_denied"
        case .sessionNotFound: "session_not_found"
        case .sessionBusy: "session_busy"
        case .sessionWaiting: "session_waiting"
        case .persistenceFailure: "persistence_failure"
        case .effectLedgerFailure: "effect_ledger_failure"
        case .modelFailure: "model_failure"
        case .accessDenied: "access_denied"
        case .unsupportedSurface: "unsupported_surface"
        case .pathOutsideSandbox: "path_outside_sandbox"
        case .invariantViolation: "invariant_violation"
        case .maxTurnsExceeded: "max_turns_exceeded"
        case .budgetExceeded: "budget_exceeded"
        case .unavailableProvider: "unavailable_provider"
        case .notFound: "not_found"
        }
    }
}
