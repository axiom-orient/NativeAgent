import Foundation
import NativeAgentDomain

private func findReferencedToolCall(id callID: String, in messages: [AgentMessage]) -> ToolCall? {
    for message in messages where message.toolCalls.isEmpty == false {
        for call in message.toolCalls where call.id == callID {
            return call
        }
    }
    return nil
}

struct PendingApprovalResolver: Sendable {
    let registry: ToolRegistry

    func request(from snapshot: SessionSnapshot) throws -> ApprovalRequest {
        guard snapshot.status == .waiting,
              let waitState = snapshot.waitState,
              waitState.kind == .approval else {
            throw AgentError.sessionWaiting(snapshot.sessionID)
        }

        guard let callID = waitState.details["toolCallID"]?.stringValue else {
            throw AgentError.invariantViolation(
                "Approval wait state is missing toolCallID for session \(snapshot.sessionID)"
            )
        }
        guard let call = findReferencedToolCall(id: callID, in: snapshot.messages) else {
            throw AgentError.invariantViolation(
                "Approval wait state references missing tool call \(callID)"
            )
        }
        guard let definition = registry.definition(named: call.name) else {
            throw AgentError.toolNotFound(call.name)
        }
        return ApprovalRequest(
            id: waitState.identifier,
            sessionID: snapshot.sessionID,
            toolCall: call,
            definition: definition,
            createdAt: waitState.createdAt
        )
    }

}

extension SessionCoordinator {
    public func pendingApprovalRequest(sessionID: String) async throws -> ApprovalRequest? {
        let snapshot = try await loadExistingSnapshot(sessionID: sessionID)

        guard snapshot.status == .waiting,
              snapshot.waitState?.kind == .approval else {
            return nil
        }

        return try approvalRequest(from: snapshot)
    }

    @discardableResult
    public func resolvePendingApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws -> SessionSnapshot {
        try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(
                sessionID: sessionID
            )
            let request = try approvalRequest(from: snapshot)
            guard request.id == requestID else {
                throw AgentError.invariantViolation(
                    "Approval resolution does not match the pending request."
                )
            }
            let hostIssued = isHostIssuedToolCall(
                id: request.toolCall.id,
                in: snapshot.messages
            )
            let approvalLedger = ApprovalEffectLedger(
                store: store,
                now: now
            )
            guard let approvalRecord = try approvalLedger.completedRecord(
                request: request,
                decision: decision
            ) else {
                throw AgentError.invalidConfiguration(
                    "Approval resolution requires an EffectLedgerStore."
                )
            }
            let clearedReduction = try SessionSnapshotTransitions.clearingWait(
                snapshot,
                timestamp: now()
            )
            let clearedSnapshot = try await snapshotWriter.persist(
                clearedReduction,
                effects: [approvalRecord],
                journalEntries: [
                    .waitCleared(snapshot.waitState),
                    .approvalResolved(request, decision)
                ]
            )

            if decision.isApproved {
                if hostIssued {
                    return try await resumeHostIssuedToolCall(
                        request.toolCall,
                        snapshot: clearedSnapshot
                    )
                }
                return try await advanceLoadedSnapshot(clearedSnapshot)
            }

            let deniedSnapshot = try await appendToolErrorAndSave(
                callID: request.toolCall.id,
                toolName: request.toolCall.name,
                content: decision.reason ?? "Tool invocation denied.",
                metadata: toolFailureMetadata(.permissionDenied),
                definition: request.definition,
                to: clearedSnapshot
            )
            if hostIssued {
                return deniedSnapshot
            }
            return try await advanceLoadedSnapshot(deniedSnapshot)
        }
    }

    func approvalRequest(from snapshot: SessionSnapshot) throws -> ApprovalRequest {
        try PendingApprovalResolver(registry: registry).request(from: snapshot)
    }

    func referencedToolCall(id callID: String, in messages: [AgentMessage]) -> ToolCall? {
        findReferencedToolCall(id: callID, in: messages)
    }

    func isHostIssuedToolCall(id callID: String, in messages: [AgentMessage]) -> Bool {
        messages.contains { message in
            message.metadata["hostIssuedToolCall"]?.boolValue == true
                && message.toolCalls.contains(where: { $0.id == callID })
        }
    }

    func appendToolErrorAndSave(
        callID: String,
        toolName: String,
        content: String,
        metadata: [String: JSONValue] = [:],
        definition: ToolDefinition? = nil,
        to snapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        try await toolErrorAppender.append(
            callID: callID,
            toolName: toolName,
            content: content,
            metadata: metadata,
            definition: definition,
            to: snapshot
        )
    }
}
