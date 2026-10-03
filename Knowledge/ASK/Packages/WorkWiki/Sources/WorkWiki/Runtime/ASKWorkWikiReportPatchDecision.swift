import KnowledgeRuntime

enum ASKWorkWikiReportPatchDecision {
    static func validate(patchID: String, decidedBy: String, decidedAt: String, reason: String, action: String) throws {
        try requireWorkWikiPatchSafeID("patch_id", patchID)
        try ASKValidation.requireNonEmpty("decided_by", decidedBy)
        guard ASKTimestamp.isValidRFC3339(decidedAt) else {
            throw ASKError.validation("work-wiki report \(action) decided_at must be valid RFC3339")
        }
        try ASKValidation.requireNonEmpty("reason", reason)
    }

    static func pendingPlan(patchID: String, pendingPlans: [KnowledgePatchPlan], action: String, requiresSourceIDs: Bool) throws -> KnowledgePatchPlan {
        guard let plan = pendingPlans.first(where: { $0.patchID == patchID }) else {
            throw ASKWorkWikiError(.pendingPatchNotFound, "pending work-wiki report patch `\(patchID)`")
        }
        try requireProjectionPatch(plan, action: action, requiresSourceIDs: requiresSourceIDs)
        return plan
    }

    static func requireProjectionPatch(_ plan: KnowledgePatchPlan, action: String, requiresSourceIDs: Bool) throws {
        guard !plan.projectionWrites.isEmpty else {
            throw ASKError.validation("work-wiki report \(action) requires a projection patch")
        }
        guard plan.projectionWrites.allSatisfy({ $0.document.metadata.subjectKind == ASKWorkWikiProjectionSubjectKind.workReport }) else {
            throw ASKError.validation("work-wiki report \(action) can only \(action == "approval" ? "apply" : "reject") work_report projection patches")
        }
        if requiresSourceIDs {
            guard !sourceIDs(in: plan).isEmpty else {
                throw ASKError.validation("work-wiki report approval requires report source_ids")
            }
        }
    }

    static func receipt(patchID: String, decision: PatchDecision, decidedBy: String, decidedAt: String, reason: String) throws -> PatchDecisionReceipt {
        let receipt = PatchDecisionReceipt(
            version: patchDecisionReceiptVersion,
            patchID: patchID,
            decision: decision,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason,
            selectedOptionID: nil
        )
        try receipt.validate()
        return receipt
    }

    static func sourceIDs(in plan: KnowledgePatchPlan) -> [String] {
        Array(Set(plan.projectionWrites.flatMap { $0.document.metadata.sourceIDs })).sorted()
    }
}
