import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public enum ASKWorkWikiReportApproval {
    public static func validate(_ request: ASKWorkWikiReportApprovalRequest) throws {
        try ASKWorkWikiReportPatchDecision.validate(
            patchID: request.patchID,
            decidedBy: request.decidedBy,
            decidedAt: request.decidedAt,
            reason: request.reason,
            action: "approval"
        )
    }

    public static func resolvePendingWorkReportPlan(
        patchID: String,
        pendingPlans: [KnowledgePatchPlan]
    ) throws -> KnowledgePatchPlan {
        try ASKWorkWikiReportPatchDecision.pendingPlan(
            patchID: patchID,
            pendingPlans: pendingPlans,
            action: "approval",
            requiresSourceIDs: true
        )
    }

    public static func requireWorkReportPatch(_ plan: KnowledgePatchPlan) throws {
        try ASKWorkWikiReportPatchDecision.requireProjectionPatch(plan, action: "approval", requiresSourceIDs: true)
    }

    public static func buildReceipt(_ request: ASKWorkWikiReportApprovalRequest) throws -> PatchDecisionReceipt {
        try ASKWorkWikiReportPatchDecision.receipt(
            patchID: request.patchID,
            decision: .approved,
            decidedBy: request.decidedBy,
            decidedAt: request.decidedAt,
            reason: request.reason
        )
    }

    public static func sourceIDs(in plan: KnowledgePatchPlan) -> [String] {
        ASKWorkWikiReportPatchDecision.sourceIDs(in: plan)
    }

    public static func sourceStatusItem(_ status: ASKEvidenceDocumentStatus) -> ASKWorkWikiReportApprovalSourceStatus {
        ASKWorkWikiReportApprovalSourceStatus(
            sourceID: status.sourceID.rawValue,
            freshness: status.freshness.rawValue,
            sourcePath: status.sourcePath
        )
    }
}
