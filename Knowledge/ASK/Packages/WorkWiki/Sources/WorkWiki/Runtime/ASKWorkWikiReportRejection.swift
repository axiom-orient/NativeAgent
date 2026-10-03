import Foundation
import KnowledgeRuntime

public enum ASKWorkWikiReportRejection {
    public static func validate(_ request: ASKWorkWikiReportRejectionRequest) throws {
        try ASKWorkWikiReportPatchDecision.validate(
            patchID: request.patchID,
            decidedBy: request.decidedBy,
            decidedAt: request.decidedAt,
            reason: request.reason,
            action: "rejection"
        )
    }

    public static func resolvePendingWorkReportPlan(
        patchID: String,
        pendingPlans: [KnowledgePatchPlan]
    ) throws -> KnowledgePatchPlan {
        try ASKWorkWikiReportPatchDecision.pendingPlan(
            patchID: patchID,
            pendingPlans: pendingPlans,
            action: "rejection",
            requiresSourceIDs: false
        )
    }

    public static func requireWorkReportProjectionPatch(_ plan: KnowledgePatchPlan) throws {
        try ASKWorkWikiReportPatchDecision.requireProjectionPatch(plan, action: "rejection", requiresSourceIDs: false)
    }

    public static func buildReceipt(_ request: ASKWorkWikiReportRejectionRequest) throws -> PatchDecisionReceipt {
        try ASKWorkWikiReportPatchDecision.receipt(
            patchID: request.patchID,
            decision: .rejected,
            decidedBy: request.decidedBy,
            decidedAt: request.decidedAt,
            reason: request.reason
        )
    }
}
