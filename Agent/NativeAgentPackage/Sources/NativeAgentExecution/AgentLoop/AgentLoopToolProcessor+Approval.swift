import Foundation
import NativeAgentDomain

extension AgentLoopToolProcessor {
    func resolveApproval(
        definition: ToolDefinition,
        call: ToolCall,
        snapshot: SessionSnapshot
    ) async throws -> ApprovalResolution {
        switch definition.approvalPolicy {
        case .automatic:
            return ApprovalResolution(snapshot: snapshot, errorMessage: nil)

        case .alwaysDeny:
            return ApprovalResolution(snapshot: snapshot, errorMessage: "Tool is disabled by policy.")

        case .requireApproval:
            if let durableDecision = try await approvalLedger.decision(
                for: call,
                definition: definition,
                sessionID: snapshot.sessionID
            ) {
                return ApprovalResolution(
                    snapshot: snapshot,
                    errorMessage: durableDecision.isApproved
                        ? nil
                        : (durableDecision.reason ?? "Tool invocation denied.")
                )
            }

            let request = ApprovalRequest(
                sessionID: snapshot.sessionID,
                toolCall: call,
                definition: definition,
                createdAt: now()
            )
            let waitState = SessionWaitState.approval(
                request: request,
                createdAt: request.createdAt
            )
            let waitingReduction = try transitions.markingWaiting(waitState, in: snapshot)
            let waitingSnapshot = try await snapshotWriter.persist(
                waitingReduction,
                journalEntries: [.waitEntered(waitState)]
            )

            try Task.checkCancellation()
            let decision = await approvalRouter.resolve(request: request)
            try Task.checkCancellation()

            guard let approvalRecord = try approvalLedger.completedRecord(
                request: request,
                decision: decision
            ) else {
                throw AgentError.invalidConfiguration(
                    "Approval resolution requires an EffectLedgerStore."
                )
            }
            let resumedReduction = try transitions.clearingWait(in: waitingSnapshot)
            let persistedResumedSnapshot = try await snapshotWriter.persist(
                resumedReduction,
                effects: [approvalRecord],
                journalEntries: [
                    .waitCleared(waitingSnapshot.waitState),
                    .approvalResolved(request, decision)
                ]
            )
            return ApprovalResolution(
                snapshot: persistedResumedSnapshot,
                errorMessage: decision.isApproved ? nil : (decision.reason ?? "Tool invocation denied.")
            )
        }
    }
}

struct ApprovalResolution: Sendable {
    let snapshot: SessionSnapshot
    let errorMessage: String?
}
