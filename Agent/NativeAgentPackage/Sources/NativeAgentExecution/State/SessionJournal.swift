import Foundation
import NativeAgentDomain

struct SessionJournal: Sendable {
    /// Explicit journal work emitted at the state/effect boundary.
    ///
    /// These are values rather than async callbacks so transactional stores can
    /// materialize their event batch directly. No temporary event-store actor is
    /// needed merely to turn events back into an array.
    enum Entry: Sendable {
        case sessionCreated
        case sessionForked(sourceSessionID: String)
        case snapshotSaved(reason: String)
        case waitEntered(SessionWaitState)
        case waitCleared(SessionWaitState?)
        case approvalResolved(ApprovalRequest, ApprovalDecision)
        case modelInvocationResolved(identifier: String, outcome: String)
        case signalReceived(SessionSignal)
        case waitTimedOut(SessionFailure)
        case assistantTurn(AgentMessage)
        case toolResult(AgentMessage)
        case toolError(AgentMessage)
        case sessionCompleted
        case sessionFailed(errorType: String?)
    }

    let now: @Sendable () -> Date
    let idGenerator: @Sendable () -> String

    func events(
        for entries: [Entry],
        snapshot: SessionSnapshot
    ) throws -> [SessionEvent] {
        try entries.map { try event(for: $0, snapshot: snapshot) }
    }

    private func event(
        for entry: Entry,
        snapshot: SessionSnapshot
    ) throws -> SessionEvent {
        let kind: SessionEventKind
        let payload: JSONValue

        switch entry {
        case .sessionCreated:
            kind = .sessionCreated
            payload = .object(try sessionPayload(snapshot))

        case .sessionForked(let sourceSessionID):
            kind = "session.forked"
            payload = .object([
                "sourceSessionID": .string(sourceSessionID)
            ])

        case .snapshotSaved(let reason):
            kind = .snapshotSaved
            var summary = try snapshotSummaryPayload(snapshot)
            summary["reason"] = .string(reason)
            payload = .object(summary)

        case .waitEntered(let waitState):
            kind = .waitEntered
            payload = try JSONValue.encode(waitState)

        case .waitCleared(let waitState):
            kind = .waitCleared
            var value: [String: JSONValue] = [:]
            if let waitState {
                value["waitState"] = try JSONValue.encode(waitState)
            }
            payload = .object(value)

        case .approvalResolved(let request, let decision):
            kind = .approvalResolved
            var value: [String: JSONValue] = [
                "requestID": .string(request.id),
                "toolCallID": .string(request.toolCall.id),
                "toolName": .string(request.toolCall.name),
                "capabilityID": .string(request.definition.capabilityID.rawValue),
                "approved": .bool(decision.isApproved)
            ]
            if let reason = decision.reason {
                value["reason"] = .string(reason)
            }
            payload = .object(value)

        case .modelInvocationResolved(let identifier, let outcome):
            kind = .modelInvocationResolved
            payload = .object([
                "identifier": .string(identifier),
                "outcome": .string(outcome)
            ])

        case .signalReceived(let signal):
            kind = .signalReceived
            payload = try JSONValue.encode(signal)

        case .waitTimedOut(let failure):
            kind = .waitTimedOut
            payload = try JSONValue.encode(failure)

        case .assistantTurn(let message):
            kind = .assistantTurnAppended
            var value = try messagePayload(message)
            value["toolCallCount"] = .integer(Int64(message.toolCalls.count))
            payload = .object(value)

        case .toolResult(let message):
            kind = .toolResultAppended
            var value = try messagePayload(message)
            value["artifactCount"] = .integer(
                Int64(message.metadata["artifacts"]?.arrayValue?.count ?? 0)
            )
            payload = .object(value)

        case .toolError(let message):
            kind = .toolErrorAppended
            payload = .object(try messagePayload(message))

        case .sessionCompleted:
            kind = .sessionCompleted
            payload = .object(try snapshotSummaryPayload(snapshot))

        case .sessionFailed(let errorType):
            kind = .sessionFailed
            var value = try snapshotSummaryPayload(snapshot)
            if let failure = snapshot.failure {
                value["error"] = .string(failure.message)
            } else if let errorType {
                // The durable failure is authoritative. This fallback stores only
                // a type name, never an unbounded or sensitive error description.
                value["errorType"] = .string(errorType)
            }
            payload = .object(value)
        }

        return SessionEvent(
            id: idGenerator(),
            sessionID: snapshot.sessionID,
            kind: kind,
            createdAt: now(),
            payload: payload
        )
    }

    private func sessionPayload(_ snapshot: SessionSnapshot) throws -> [String: JSONValue] {
        var payload = try snapshotSummaryPayload(snapshot)
        if let title = snapshot.title {
            payload["title"] = .string(title)
        }
        if let providerID = snapshot.providerID {
            payload["providerID"] = .string(providerID)
        }
        if let modelID = snapshot.modelID {
            payload["modelID"] = .string(modelID)
        }
        payload["hasSystemPrompt"] = .bool(snapshot.messages.contains(where: { $0.role == .system }))
        return payload
    }

    private func snapshotSummaryPayload(_ snapshot: SessionSnapshot) throws -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "status": .string(snapshot.status.rawValue),
            "messageCount": .integer(Int64(snapshot.messages.count)),
            "artifactCount": .integer(Int64(snapshot.artifacts.count)),
            "updatedAt": .integer(try millisecondsSince1970(snapshot.updatedAt))
        ]
        if let waitState = snapshot.waitState {
            payload["waitState"] = try JSONValue.encode(waitState)
        }
        if let failure = snapshot.failure {
            payload["failure"] = try JSONValue.encode(failure)
        }
        if let lastSignal = snapshot.lastSignal {
            payload["lastSignal"] = try JSONValue.encode(lastSignal)
        }
        return payload
    }

    private func millisecondsSince1970(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value < Double(Int64.max) else {
            throw AgentError.invariantViolation("Session timestamp is outside the supported range.")
        }
        return Int64(value)
    }

    private func messagePayload(_ message: AgentMessage) throws -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "message": try JSONValue.encode(message),
            "messageID": .string(message.id),
            "role": .string(message.role.rawValue),
            "contentLength": .integer(Int64(message.content.count))
        ]
        if let toolCallID = message.toolCallID {
            payload["toolCallID"] = .string(toolCallID)
        }
        if let toolName = message.toolName {
            payload["toolName"] = .string(toolName)
        }
        return payload
    }
}
