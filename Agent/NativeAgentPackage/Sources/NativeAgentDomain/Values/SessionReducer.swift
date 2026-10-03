import LanguageModelCore
import Foundation

/// Semantic reason for a durable mutation emitted by the pure session reducer.
package enum SessionMutationReason: String, Sendable, Equatable {
    case userPromptAppended = "user_prompt_appended"
    case statusResumedToRunning = "status_resumed_to_running"
    case contextCompacted = "context_compacted"
    case responseContinuationPromptAppended = "response_continuation_prompt_appended"
    case assistantTurnAppended = "assistant_turn_appended"
    case waitEntered = "wait_entered"
    case waitCleared = "wait_cleared"
    case signalReceived = "signal_received"
    case waitTimedOut = "wait_timed_out"
    case toolResultAppended = "tool_result_appended"
    case toolErrorAppended = "tool_error_appended"
    case sessionCompleted = "session_completed"
    case sessionFailed = "session_failed"
    case commandRecorded = "command_recorded"
}

/// Explicit state-machine input. Values are complete so reduction remains pure.
package enum SessionAction: Sendable {
    case appendUserPrompt(AgentMessage, updatedAt: Date)
    case append(
        messages: [AgentMessage],
        artifacts: [ArtifactRecord],
        updatedAt: Date,
        reason: SessionMutationReason
    )
    case resumeAndAppend(
        messages: [AgentMessage],
        artifacts: [ArtifactRecord],
        updatedAt: Date,
        reason: SessionMutationReason
    )
    case resolveWaitAndAppend(
        messages: [AgentMessage],
        artifacts: [ArtifactRecord],
        updatedAt: Date,
        reason: SessionMutationReason
    )
    case replaceMessages(
        [AgentMessage],
        updatedAt: Date,
        reason: SessionMutationReason
    )
    case recordCommand([String: JSONValue], updatedAt: Date)
    case replaceMetadata([String: JSONValue])
    case updateContextCheckpoint(SessionContextCheckpoint, updatedAt: Date)
    case resume(updatedAt: Date)
    case enterWait(SessionWaitState, updatedAt: Date)
    case clearWait(updatedAt: Date)
    case receiveSignal(SessionSignal, updatedAt: Date)
    case resolveWaitAndUpdateMetadata(
        signal: SessionSignal?,
        metadata: [String: JSONValue],
        updatedAt: Date
    )
    case complete(updatedAt: Date)
    case fail(SessionFailure, updatedAt: Date, reason: SessionMutationReason)
    case appendAndFail(
        messages: [AgentMessage],
        failure: SessionFailure,
        updatedAt: Date,
        reason: SessionMutationReason
    )
}

package struct SessionReduction: Sendable, Equatable {
    package let snapshot: SessionSnapshot
    package let mutationReason: SessionMutationReason?
    package let persistenceDelta: SessionPersistenceDelta?

    package init(
        snapshot: SessionSnapshot,
        mutationReason: SessionMutationReason?,
        persistenceDelta: SessionPersistenceDelta? = nil
    ) {
        self.snapshot = snapshot
        self.mutationReason = mutationReason
        self.persistenceDelta = persistenceDelta
    }
}

/// Pure state transition function for the durable session lifecycle.
package enum SessionReducer {
    package static func reduce(
        _ action: SessionAction,
        state current: SessionSnapshot
    ) throws -> SessionReduction {
        // Load/create performs the full transcript-prefix check. Actions that
        // do not replace the prefix preserve that already-proven invariant.
        try current.validateState(checkpointPrefixValidation: false)
        guard current.revision < Int64.max else {
            throw AgentError.persistenceFailure(
                "Session \(current.sessionID) exhausted its revision range."
            )
        }

        let reduced: SessionSnapshot
        let reason: SessionMutationReason?
        let persistenceDelta: SessionPersistenceDelta?

        switch action {
        case let .appendUserPrompt(message, updatedAt):
            try require(current.status != .waiting, current, "user prompt cannot be appended while waiting")
            let messageStart = current.messages.count
            let expectedRevision = current.revision
            reduced = current.applying(.userPromptAppended(message, updatedAt: updatedAt))
            reason = .userPromptAppended
            persistenceDelta = SessionPersistenceDelta(
                expectedRevision: expectedRevision,
                messages: .append(startingAt: messageStart, messages: [message])
            )

        case let .append(messages, artifacts, updatedAt, mutationReason):
            try require(current.status == .running, current, "append requires a running session")
            try require(
                artifacts.count >= current.artifacts.count
                    && artifacts.prefix(current.artifacts.count)
                        .elementsEqual(current.artifacts),
                current,
                "append cannot replace or reorder existing artifacts"
            )
            let messageStart = current.messages.count
            let artifactStart = current.artifacts.count
            let expectedRevision = current.revision
            let appendedArtifacts = Array(artifacts.dropFirst(artifactStart))
            reduced = current.applying(.appended(
                messages: messages,
                artifacts: artifacts,
                updatedAt: updatedAt
            ))
            reason = mutationReason
            persistenceDelta = SessionPersistenceDelta(
                expectedRevision: expectedRevision,
                messages: messages.isEmpty
                    ? .unchanged
                    : .append(startingAt: messageStart, messages: messages),
                artifacts: appendedArtifacts.isEmpty
                    ? .unchanged
                    : .append(startingAt: artifactStart, artifacts: appendedArtifacts)
            )

        case let .resumeAndAppend(messages, artifacts, updatedAt, mutationReason):
            try require(
                current.status == .failed,
                current,
                "resume-and-append requires a failed session"
            )
            try require(
                artifacts.count >= current.artifacts.count
                    && artifacts.prefix(current.artifacts.count)
                        .elementsEqual(current.artifacts),
                current,
                "resume-and-append cannot replace or reorder existing artifacts"
            )
            let messageStart = current.messages.count
            let artifactStart = current.artifacts.count
            let expectedRevision = current.revision
            let appendedArtifacts = Array(artifacts.dropFirst(artifactStart))
            reduced = current.applying(
                .resumedAndAppended(
                    messages: messages,
                    artifacts: artifacts,
                    updatedAt: updatedAt
                )
            )
            reason = mutationReason
            persistenceDelta = SessionPersistenceDelta(
                expectedRevision: expectedRevision,
                messages: messages.isEmpty
                    ? .unchanged
                    : .append(startingAt: messageStart, messages: messages),
                artifacts: appendedArtifacts.isEmpty
                    ? .unchanged
                    : .append(startingAt: artifactStart, artifacts: appendedArtifacts)
            )

        case let .resolveWaitAndAppend(messages, artifacts, updatedAt, mutationReason):
            try require(
                current.status == .waiting,
                current,
                "wait resolution with append requires a waiting session"
            )
            try require(
                artifacts.count >= current.artifacts.count
                    && artifacts.prefix(current.artifacts.count)
                        .elementsEqual(current.artifacts),
                current,
                "wait resolution cannot replace or reorder existing artifacts"
            )
            let messageStart = current.messages.count
            let artifactStart = current.artifacts.count
            let expectedRevision = current.revision
            let appendedArtifacts = Array(artifacts.dropFirst(artifactStart))
            reduced = current.applying(
                .waitResolvedAndAppended(
                    messages: messages,
                    artifacts: artifacts,
                    updatedAt: updatedAt
                )
            )
            reason = mutationReason
            persistenceDelta = SessionPersistenceDelta(
                expectedRevision: expectedRevision,
                messages: messages.isEmpty
                    ? .unchanged
                    : .append(startingAt: messageStart, messages: messages),
                artifacts: appendedArtifacts.isEmpty
                    ? .unchanged
                    : .append(startingAt: artifactStart, artifacts: appendedArtifacts)
            )

        case let .replaceMessages(messages, updatedAt, mutationReason):
            try require(current.status == .running, current, "message replacement requires a running session")
            let expectedRevision = current.revision
            reduced = current.applying(.messagesReplaced(messages, updatedAt: updatedAt))
            try reduced.validateState()
            reason = mutationReason
            persistenceDelta = SessionPersistenceDelta(
                expectedRevision: expectedRevision,
                messages: .replace(messages: messages)
            )

        case let .recordCommand(metadata, updatedAt):
            try require(current.status != .waiting, current, "command recording is not allowed while waiting")
            let expectedRevision = current.revision
            reduced = current.applying(.commandRecorded(metadata, updatedAt: updatedAt))
            reason = .commandRecorded
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .replaceMetadata(metadata):
            try require(current.status != .waiting, current, "metadata replacement is not allowed while waiting")
            reduced = current.applying(.metadataChanged(metadata))
            reason = nil
            persistenceDelta = nil

        case let .updateContextCheckpoint(checkpoint, updatedAt):
            try require(
                current.status == .running,
                current,
                "context checkpoint update requires a running session"
            )
            let expectedRevision = current.revision
            reduced = current.applying(
                .contextCheckpointChanged(checkpoint, updatedAt: updatedAt)
            )
            try reduced.validateState()
            reason = .contextCompacted
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .resume(updatedAt):
            try require(
                current.status == .failed,
                current,
                "resume requires a failed session"
            )
            let expectedRevision = current.revision
            reduced = current.applying(.resumed(updatedAt: updatedAt))
            reason = .statusResumedToRunning
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .enterWait(waitState, updatedAt):
            try require(current.status == .running, current, "wait entry requires a running session")
            let expectedRevision = current.revision
            reduced = current.applying(.enteredWait(waitState, updatedAt: updatedAt))
            reason = .waitEntered
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .clearWait(updatedAt):
            try require(current.status == .waiting, current, "wait clearing requires a waiting session")
            let expectedRevision = current.revision
            reduced = current.applying(.clearedWait(updatedAt: updatedAt))
            reason = .waitCleared
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .receiveSignal(signal, updatedAt):
            guard current.status == .waiting,
                  let waitState = current.waitState,
                  waitState.kind == .signal,
                  waitState.identifier == signal.identifier else {
                throw invalidTransition(current, "signal does not match the pending wait")
            }
            let expectedRevision = current.revision
            reduced = current.applying(.signalReceived(signal, updatedAt: updatedAt))
            reason = .signalReceived
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .resolveWaitAndUpdateMetadata(signal, metadata, updatedAt):
            try require(current.status == .waiting, current, "wait resolution requires a waiting session")
            let expectedRevision = current.revision
            if let signal {
                guard let waitState = current.waitState,
                      waitState.kind == .signal,
                      waitState.identifier == signal.identifier else {
                    throw invalidTransition(current, "signal does not match the pending wait")
                }
                reduced = snapshotWithMetadata(
                    metadata,
                    replacing: current.applying(
                        .signalReceived(signal, updatedAt: updatedAt)
                    )
                )
                reason = .signalReceived
            } else {
                reduced = snapshotWithMetadata(
                    metadata,
                    replacing: current.applying(.clearedWait(updatedAt: updatedAt))
                )
                reason = .waitCleared
            }
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .complete(updatedAt):
            try require(current.status == .running, current, "completion requires a running session")
            let expectedRevision = current.revision
            reduced = current.applying(.completed(updatedAt: updatedAt))
            reason = .sessionCompleted
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .fail(failure, updatedAt, mutationReason):
            try require(
                current.status == .running || current.status == .waiting,
                current,
                "failure requires a running or waiting session"
            )
            let expectedRevision = current.revision
            reduced = current.applying(.failed(failure, updatedAt: updatedAt))
            reason = mutationReason
            persistenceDelta = SessionPersistenceDelta(expectedRevision: expectedRevision)

        case let .appendAndFail(messages, failure, updatedAt, mutationReason):
            try require(
                current.status == .running || current.status == .waiting,
                current,
                "append-and-fail requires a running or waiting session"
            )
            let messageStart = current.messages.count
            let expectedRevision = current.revision
            reduced = current.applying(
                .appendedAndFailed(
                    messages: messages,
                    failure: failure,
                    updatedAt: updatedAt
                )
            )
            reason = mutationReason
            persistenceDelta = SessionPersistenceDelta(
                expectedRevision: expectedRevision,
                messages: messages.isEmpty
                    ? .unchanged
                    : .append(startingAt: messageStart, messages: messages)
            )
        }

        try reduced.validateState(checkpointPrefixValidation: false)
        return SessionReduction(
            snapshot: reduced,
            mutationReason: reason,
            persistenceDelta: persistenceDelta
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ snapshot: SessionSnapshot,
        _ message: String
    ) throws {
        guard condition() else {
            throw invalidTransition(snapshot, message)
        }
    }

    private static func invalidTransition(
        _ snapshot: SessionSnapshot,
        _ message: String
    ) -> AgentError {
        AgentError.invariantViolation(
            "Invalid session transition for \(snapshot.sessionID) from \(snapshot.status.rawValue): \(message)."
        )
    }

    private static func snapshotWithMetadata(
        _ metadata: [String: JSONValue],
        replacing snapshot: SessionSnapshot
    ) -> SessionSnapshot {
        SessionSnapshot(
            schemaVersion: snapshot.schemaVersion,
            revision: snapshot.revision,
            sessionID: snapshot.sessionID,
            title: snapshot.title,
            status: snapshot.status,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            messages: snapshot.messages,
            artifacts: snapshot.artifacts,
            providerID: snapshot.providerID,
            modelID: snapshot.modelID,
            metadata: metadata,
            contextCheckpoint: snapshot.contextCheckpoint,
            waitState: snapshot.waitState,
            failure: snapshot.failure,
            lastSignal: snapshot.lastSignal
        )
    }
}
