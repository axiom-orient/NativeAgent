
import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct ASKStoreTests {
    @Test
    func applyApprovedPatchMovesRowsIntoStore() throws {
        var store = KnowledgeStore.openInMemory()
        let plan = makeDemoPlan(patchID: "patch_demo")
        let receipt = makeReceipt(patchID: "patch_demo", decision: .approved)

        try store.putPatchPlan(plan)
        try store.applyPatchReceipt(plan: plan, receipt: receipt)

        #expect(store.sources["src_demo"] != nil)
        #expect(store.patchStatus("patch_demo") == .applied)
        #expect(store.pendingReviewCount("patch_demo") == 0)
    }

    @Test
    func decidedPatchCannotBeAppliedTwiceAndStoreRemainsStable() throws {
        var store = KnowledgeStore.openInMemory()
        let plan = makeDemoPlan(patchID: "patch_repeat")
        let receipt = makeReceipt(patchID: "patch_repeat", decision: .approved)

        try store.putPatchPlan(plan)
        try store.applyPatchReceipt(plan: plan, receipt: receipt)

        let sourceCount = store.sources.count
        let evidenceCount = store.evidence.count
        let logCount = store.operationLogs.count

        #expect(throws: Error.self) {
            try store.applyPatchReceipt(plan: plan, receipt: receipt)
        }

        #expect(store.patchStatus("patch_repeat") == .applied)
        #expect(store.sources.count == sourceCount)
        #expect(store.evidence.count == evidenceCount)
        #expect(store.operationLogs.count == logCount)
    }

    @Test
    func canonicalPlanRejectsDuplicateSourceIDs() throws {
        var store = KnowledgeStore.openInMemory()
        var plan = makeDemoPlan(patchID: "patch_duplicate")
        plan.sourceReceipts += plan.sourceReceipts
        #expect(throws: ASKError.self) {
            try store.putPatchPlan(plan)
        }
    }

    @Test
    func canonicalPlanRejectsUnsupportedRecordAndProjectionVersions() throws {
        var store = KnowledgeStore.openInMemory()
        var plan = makeDemoPlan(patchID: "patch_unsupported")
        plan.sourceReceipts[0].version = "knowledge-source-receipt.v1"
        #expect(throws: ASKError.self) { try store.putPatchPlan(plan) }

        var projection = makeProjectionWriteForCAS(body: "content", precondition: nil)
        projection.document.version = "knowledge-projection-document.v2"
        let projectionPlan = makeProjectionPlan(patchID: "patch_projection_unsupported", write: projection)
        #expect(throws: ASKError.self) { try store.putPatchPlan(projectionPlan) }
    }
}

private func makeDemoPlan(patchID: String) -> KnowledgePatchPlan {
    KnowledgePatchPlan(
        version: knowledgePatchPlanVersion,
        patchID: patchID,
        patchKind: .evidenceIngest,
        generatedAt: "2026-04-07T10:00:00Z",
        sourceReceipts: [
            SourceReceipt(
                version: sourceReceiptVersion,
                sourceID: "src_demo",
                connector: "manual",
                sourceKind: .text,
                title: "Demo",
                observedAt: "2026-04-07T10:00:00Z",
                capturedAt: nil,
                canonicalURI: sourceURI("src_demo"),
                contentHash: "sha256:demo",
                rawRelpath: "raw/evidence/demo.txt",
                mimeType: "text/plain",
                language: "en",
                tags: ["demo"],
                metadata: [:]
            )
        ],
        sourceFragments: [
            SourceFragment(
                version: sourceFragmentVersion,
                fragmentID: "frag_demo",
                sourceID: "src_demo",
                ordinal: 0,
                locator: [:],
                text: "Ask works.",
                fingerprint: nil,
                metadata: [:]
            )
        ],
        authorityRecords: [],
        projectionInvalidations: [],
        projectionWrites: [],
        claims: [],
        evidence: [
            EvidenceRecord(
                evidenceID: "evidence_demo",
                sourceID: "src_demo",
                fragmentID: "frag_demo",
                excerpt: "Ask works."
            )
        ],
        claimEvidence: [],
        reviewItems: [],
        warnings: [],
        verification: VerificationReport(
            patchID: patchID,
            riskLevel: .low,
            disposition: .autoPublish,
            reasons: ["low_risk_append_only"],
            requiresHumanApproval: false
        ),
        operations: []
    )
}

private func makeReceipt(patchID: String, decision: PatchDecision) -> PatchDecisionReceipt {
    PatchDecisionReceipt(
        version: patchDecisionReceiptVersion,
        patchID: patchID,
        decision: decision,
        decidedBy: "tester",
        decidedAt: "2026-04-07T10:01:00Z",
        reason: "ok"
    )
}

@Test
func projectionWritePreconditionIsEnforcedByAuthoritativeStoreTransition() throws {
    var store = KnowledgeStore.openInMemory()
    let original = makeProjectionWriteForCAS(body: "v1", precondition: nil)
    let seed = makeProjectionPlan(patchID: "patch_projection_seed", write: original)
    try store.putPatchPlan(seed)
    try store.applyPatchReceipt(
        plan: seed,
        receipt: makeReceipt(patchID: seed.patchID, decision: .approved)
    )

    let conflicting = makeProjectionWriteForCAS(
        body: "v2",
        precondition: ProjectionWritePrecondition(expectedBaseRevision: "wrong-revision")
    )
    let update = makeProjectionPlan(patchID: "patch_projection_conflict", write: conflicting)
    try store.putPatchPlan(update)

    #expect(throws: Error.self) {
        try store.applyPatchReceipt(
            plan: update,
            receipt: makeReceipt(patchID: update.patchID, decision: .approved)
        )
    }
    #expect(store.visibleProjectionWrites().first(where: { $0.slug == original.slug })?.document.bodyMD == "v1")
}

private func makeProjectionWriteForCAS(
    body: String,
    precondition: ProjectionWritePrecondition?
) -> ProjectionWrite {
    let metadata = ProjectionMetadata(
        projectionKind: .queryArtifact,
        projectionSpace: .wiki,
        subjectKind: "work_report",
        subjectID: "cas-report",
        authorityIDs: [],
        sourceIDs: [],
        claimIDs: [],
        historical: false,
        approvalRequired: false
    )
    var document = ProjectionDocument(
        version: projectionDocumentVersion,
        slug: "work/reports/cas-report",
        title: "CAS Report",
        bodyMD: body,
        metadata: metadata,
        generatedFromHash: "pending",
        generatedAt: "2026-04-07T10:00:00Z"
    )
    document.generatedFromHash = projectionDocumentHash(document)
    return ProjectionWrite(
        slug: document.slug,
        state: .draft,
        document: document,
        precondition: precondition
    )
}

private func makeProjectionPlan(patchID: String, write: ProjectionWrite) -> KnowledgePatchPlan {
    KnowledgePatchPlan(
        version: knowledgePatchPlanVersion,
        patchID: patchID,
        patchKind: .projectionRefresh,
        generatedAt: "2026-04-07T10:00:00Z",
        sourceReceipts: [],
        sourceFragments: [],
        authorityRecords: [],
        projectionInvalidations: [],
        projectionWrites: [write],
        claims: [],
        evidence: [],
        claimEvidence: [],
        reviewItems: [],
        warnings: [],
        verification: VerificationReport(
            patchID: patchID,
            riskLevel: .medium,
            disposition: .needsReview,
            reasons: ["projection_cas_test"],
            requiresHumanApproval: true
        ),
        operations: []
    )
}
