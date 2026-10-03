import Foundation
import KnowledgeCore

package func planProjectionRefreshRequest(_ request: RefreshProjectionRequest) throws -> RefreshProjectionOutcome {
    try request.validate()

    let patchID = stableID(
        prefix: "patch",
        parts: [
            PatchKind.projectionRefresh.rawValue,
            request.trigger,
            request.requestedAt,
        ]
    )

    var projectionWrites: [ProjectionWrite] = []
    var reviewItems: [ReviewItem] = []
    var warnings: [String] = []
    var invalidations: [ProjectionInvalidation] = []

    for write in request.proposedWrites {
        let metadata = write.document.metadata
        if metadata.historical && !metadata.approvalRequired {
            warnings.append("historical_rewrite_blocked")
            reviewItems.append(
                reviewItem(
                    reviewKind: .historicalRewriteBlocked,
                    severity: .high,
                    subjectKind: metadata.subjectKind,
                    subjectID: metadata.subjectID,
                    summary: "historical projection rewrite blocked without explicit approval",
                    createdAt: request.requestedAt,
                    details: ["slug": write.slug]
                )
            )
            continue
        }
        if metadata.projectionSpace == .playbook && !metadata.approvalRequired {
            warnings.append("playbook_promotion_blocked")
            reviewItems.append(
                reviewItem(
                    reviewKind: .playbookPromotionBlocked,
                    severity: .high,
                    subjectKind: metadata.subjectKind,
                    subjectID: metadata.subjectID,
                    summary: "playbook publication requires explicit approval",
                    createdAt: request.requestedAt,
                    details: ["slug": write.slug]
                )
            )
            continue
        }
        invalidations.append(
            ProjectionInvalidation(
                invalidationID: stableID(prefix: "invalidate", parts: [patchID, write.slug]),
                slug: write.slug,
                reason: request.trigger,
                triggeredByPatchID: patchID,
                createdAt: request.requestedAt
            )
        )
        projectionWrites.append(write)
    }

    var plan = KnowledgePatchPlan(
        version: knowledgePatchPlanVersion,
        patchID: patchID,
        patchKind: .projectionRefresh,
        generatedAt: request.requestedAt,
        sourceReceipts: [],
        sourceFragments: [],
        authorityRecords: [],
        projectionInvalidations: invalidations,
        projectionWrites: projectionWrites,
        claims: [],
        evidence: [],
        claimEvidence: [],
        reviewItems: reviewItems,
        warnings: warnings,
        verification: emptyVerification(patchID: patchID),
        operations: [
            OperationLogEntry(
                logID: stableID(prefix: "log", parts: [patchID, "projection_refresh"]),
                occurredAt: request.requestedAt,
                opKind: "projection_refresh",
                summary: "projection refresh triggered by \(request.trigger)"
            )
        ]
    )
    plan.verification = try verifyPatchPlan(plan)
    try plan.validate()
    return RefreshProjectionOutcome(patch: plan)
}

package func planProjectionRefresh(_ request: RefreshProjectionRequest) throws -> RefreshProjectionOutcome {
    try planProjectionRefreshRequest(request)
}
