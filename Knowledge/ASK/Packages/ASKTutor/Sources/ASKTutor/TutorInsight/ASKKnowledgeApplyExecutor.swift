import KnowledgePresentation
import KnowledgeRuntime
import Foundation

struct ASKKnowledgeApplyExecutor: Sendable {
    let workspace: ASKProductWorkspacePaths
    let maintainer: any ASKKnowledgeMaintainer
    let candidateStore: TutorInsightCandidateStore
    let appliedStore: TutorInsightAppliedRecordStore
    let pageIndexBuilder: ASKProjectionPageIndexBuilder
    let presentationBuilder: ASKPresentationBuilder

    @discardableResult
    func apply(
        proposal: TutorInsightProposal,
        decidedBy: String,
        decidedAt: String,
        reason: String?,
        fileManager: FileManager = .default
    ) async throws -> TutorInsightApplyResult {
        try maintainer.stage(proposal.patch)
        let receipt = try approvedReceipt(
            patchID: proposal.patch.patchID,
            candidateID: proposal.candidate.candidateID,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
        let applySummary = try maintainer.apply(proposal.patch, receipt)
        let record = TutorInsightAppliedRecord(
            candidate: proposal.candidate,
            targetProjectionSlug: proposal.targetProjectionSlug,
            patchID: proposal.patch.patchID,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: receipt.reason,
            applySummary: applySummary,
            presentationBundleName: proposal.targetProjectionSlug
        )
        do {
            try appliedStore.save(record, fileManager: fileManager)
        } catch {
            throw TutorInsightPostCommitError(
                committedRecord: record,
                failedEffect: .persistAppliedRecord,
                cause: String(describing: error)
            )
        }

        let pageIndexBuild: ASKProjectionPageIndexBuildResult
        do {
            pageIndexBuild = try await pageIndexBuilder.build(
                slug: proposal.targetProjectionSlug,
                reader: maintainer,
                workspace: workspace.knowledgeWorkspace,
                fileManager: fileManager
            )
        } catch {
            throw TutorInsightPostCommitError(
                committedRecord: record,
                failedEffect: .rebuildPageIndex,
                cause: String(describing: error)
            )
        }

        let presentation: ASKProjectionPresentationPackage
        do {
            presentation = try presentationBuilder.materializeProjection(
                slug: proposal.targetProjectionSlug,
                reader: maintainer,
                workspace: workspace.knowledgeWorkspace,
                fileManager: fileManager
            )
        } catch {
            throw TutorInsightPostCommitError(
                committedRecord: record,
                failedEffect: .materializePresentation,
                cause: String(describing: error)
            )
        }

        // Candidate removal is the workflow-completion marker. Keeping it until
        // every dependent derived effect succeeds makes post-commit retry safe.
        do {
            try candidateStore.remove(candidateID: proposal.candidate.candidateID, fileManager: fileManager)
        } catch {
            throw TutorInsightPostCommitError(
                committedRecord: record,
                failedEffect: .removeCandidate,
                cause: String(describing: error)
            )
        }

        return TutorInsightApplyResult(
            record: record,
            pageIndexBuild: pageIndexBuild,
            presentation: presentation
        )
    }

    private func approvedReceipt(
        patchID: String,
        candidateID: String,
        decidedBy: String,
        decidedAt: String,
        reason: String?
    ) throws -> PatchDecisionReceipt {
        let receipt = PatchDecisionReceipt(
            version: patchDecisionReceiptVersion,
            patchID: patchID,
            decision: .approved,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason ?? "approved tutor insight \(candidateID)"
        )
        try receipt.validate()
        return receipt
    }
}
