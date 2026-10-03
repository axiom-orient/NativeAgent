import Foundation
import KnowledgeCore

extension ASKRuntime {
    public func patchPlan(patchID: String) throws -> KnowledgePatchPlan? {
        let vault = Vault(root: root)
        return try vault.loadPatchPlan(patchID: patchID)
    }

    public func pendingPatchPlans() throws -> [KnowledgePatchPlan] {
        let snapshot = try self.snapshot()
        return try snapshot.pendingPatchIDs.map { patchID in
            guard let plan = try patchPlan(patchID: patchID) else {
                throw ASKError.notFound("patch plan `\(patchID)`")
            }
            return plan
        }
    }

    public func decidePendingPatch(
        patchID: String,
        decision: PatchDecision,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil
    ) throws -> ASKApplySummary {
        let plan = try resolvePendingPlan(patchID: patchID)
        let receipt = try buildReceipt(
            for: plan,
            decision: decision,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
        return try apply(plan, receipt)
    }

    public func choosePendingPatch(
        patchID: String,
        choice: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil
    ) throws -> ASKApplySummary {
        let plan = try resolvePendingPlan(patchID: patchID)
        let receipt = try receiptFromChoice(
            for: plan,
            choice: choice,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
        return try apply(plan, receipt)
    }

    private func resolvePendingPlan(patchID: String) throws -> KnowledgePatchPlan {
        let snapshot = try self.snapshot()
        guard snapshot.pendingPatchIDs.contains(patchID) else {
            throw ASKError.notFound("pending patch `\(patchID)`")
        }
        guard let plan = try patchPlan(patchID: patchID) else {
            throw ASKError.notFound("patch plan `\(patchID)`")
        }
        return plan
    }
}
