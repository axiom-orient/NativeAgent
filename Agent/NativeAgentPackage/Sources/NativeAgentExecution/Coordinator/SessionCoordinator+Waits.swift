import Foundation
import NativeAgentDomain

extension SessionCoordinator {
    @discardableResult
    public func waitForSignal(
        sessionID: String,
        identifier: String,
        details: [String: JSONValue] = [:]
    ) async throws -> SessionSnapshot {
        guard identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invariantViolation("Signal wait identifier must not be empty.")
        }

        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(
                sessionID: sessionID
            )
            guard snapshot.status == .running else {
                throw AgentError.invariantViolation("Signal wait can only be entered from a running session: \(sessionID)")
            }

            return try await enterWait(
                SessionWaitState.signal(identifier: identifier, createdAt: now(), details: details),
                snapshot: snapshot
            )
        }
    }

    @discardableResult
    public func resumeSignalWait(
        sessionID: String,
        identifier: String,
        payload: JSONValue = .null,
        userPrompt: String? = nil,
        requestMetadata: [String: JSONValue] = [:],
        responseContinuation: ResponseContinuationPolicy? = nil
    ) async throws -> SessionSnapshot {
        if let userPrompt,
           userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try resourceValidator.validateUserPrompt(userPrompt)
        }
        try resourceValidator.validateSignalPayload(payload)

        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(
                sessionID: sessionID
            )
            guard let waitState = snapshot.waitState,
                  waitState.kind == .signal,
                  waitState.identifier == identifier else {
                throw AgentError.sessionWaiting(sessionID)
            }

            let signal = SessionSignal(
                identifier: identifier,
                payload: payload,
                receivedAt: now()
            )
            return try await resumeWaitedSession(
                from: snapshot,
                signal: signal,
                userPrompt: userPrompt,
                requestMetadata: requestMetadata,
                responseContinuation: responseContinuation
            )
        }
    }

    @discardableResult
    public func waitUntil(
        sessionID: String,
        resumeAt: Date,
        identifier: String = UUID().uuidString,
        details: [String: JSONValue] = [:]
    ) async throws -> SessionSnapshot {
        guard identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invariantViolation("Time wait identifier must not be empty.")
        }

        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(
                sessionID: sessionID
            )
            guard snapshot.status == .running else {
                throw AgentError.invariantViolation("Time wait can only be entered from a running session: \(sessionID)")
            }

            return try await enterWait(
                SessionWaitState.time(
                    identifier: identifier,
                    resumeAt: PersistedTimestamp.canonicalizing(resumeAt),
                    createdAt: now(),
                    details: details
                ),
                snapshot: snapshot
            )
        }
    }

    @discardableResult
    public func resumeTimeWait(
        sessionID: String,
        asOf: Date? = nil,
        userPrompt: String? = nil,
        requestMetadata: [String: JSONValue] = [:],
        responseContinuation: ResponseContinuationPolicy? = nil
    ) async throws -> SessionSnapshot {
        if let userPrompt,
           userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try resourceValidator.validateUserPrompt(userPrompt)
        }

        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(
                sessionID: sessionID
            )
            guard let waitState = snapshot.waitState,
                  waitState.kind == .time else {
                throw AgentError.sessionWaiting(sessionID)
            }

            let effectiveNow = asOf ?? now()
            guard let resumeAt = waitState.resumeAt, resumeAt <= effectiveNow else {
                throw AgentError.sessionWaiting(sessionID)
            }

            return try await resumeWaitedSession(
                from: snapshot,
                userPrompt: userPrompt,
                requestMetadata: requestMetadata,
                responseContinuation: responseContinuation
            )
        }
    }

    /// Converts a still-pending approval, signal, or time wait into a durable failed state.
    @discardableResult
    public func timeoutWait(
        sessionID: String,
        identifier: String,
        reason: String = "Pending wait timed out."
    ) async throws -> SessionSnapshot {
        try resourceValidator.validateFailureReason(reason)
        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(
                sessionID: sessionID
            )
            let timestamp = now()
            let failedReduction = try SessionSnapshotTransitions.timingOutWait(
                snapshot,
                identifier: identifier,
                reason: reason,
                timestamp: timestamp
            )
            let failure = failedReduction.snapshot.failure ?? SessionFailure(
                code: "wait_timed_out",
                message: reason,
                occurredAt: timestamp,
                details: ["identifier": .string(identifier)]
            )
            return try await snapshotWriter.persist(
                failedReduction,
                journalEntries: [
                    .waitTimedOut(failure),
                    .sessionFailed(errorType: nil)
                ]
            )
        }
    }
}
