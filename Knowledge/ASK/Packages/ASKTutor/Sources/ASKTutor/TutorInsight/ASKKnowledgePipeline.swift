import KnowledgePresentation
import KnowledgeRuntime
import Foundation

public struct ASKKnowledgePipeline: Sendable {
    public let workspace: ASKProductWorkspacePaths
    public let maintainer: any ASKKnowledgeMaintainer
    public let candidateStore: TutorInsightCandidateStore
    public let appliedStore: TutorInsightAppliedRecordStore
    public let insightCapture: TutorInsightCapture
    public let pageIndexBuilder: ASKProjectionPageIndexBuilder
    public let presentationBuilder: ASKPresentationBuilder

    public init(
        workspace: ASKProductWorkspacePaths,
        maintainer: any ASKKnowledgeMaintainer,
        pageIndexBuilder: ASKProjectionPageIndexBuilder = ASKProjectionPageIndexBuilder(),
        presentationBuilder: ASKPresentationBuilder = ASKPresentationBuilder(),
        candidateStore: TutorInsightCandidateStore? = nil,
        appliedStore: TutorInsightAppliedRecordStore? = nil,
        insightCapture: TutorInsightCapture? = nil
    ) throws {
        try workspace.ensureDirectories()
        self.workspace = workspace
        self.maintainer = maintainer
        self.pageIndexBuilder = pageIndexBuilder
        self.presentationBuilder = presentationBuilder
        self.candidateStore = candidateStore ?? TutorInsightCandidateStore(rootURL: workspace.pendingTutorInsightsRoot)
        self.appliedStore = appliedStore ?? TutorInsightAppliedRecordStore(rootURL: workspace.appliedTutorInsightsRoot)
        self.insightCapture = insightCapture ?? TutorInsightCapture(
            store: self.candidateStore,
            knowledgeReader: maintainer
        )
    }

    @discardableResult
    public func captureNarrative(
        learnerID: String,
        session: TutorSession,
        prompt: String,
        reply: TutorReply,
        candidateID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> TutorInsightCandidate {
        try insightCapture.captureNarrative(
            learnerID: learnerID,
            session: session,
            prompt: prompt,
            reply: reply,
            candidateID: candidateID,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func capturePracticeSet(
        learnerID: String,
        session: TutorSession,
        practiceSet: TutorPracticeSet,
        candidateID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> TutorInsightCandidate {
        try insightCapture.capturePracticeSet(
            learnerID: learnerID,
            session: session,
            practiceSet: practiceSet,
            candidateID: candidateID,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func capturePracticeEvaluation(
        learnerID: String,
        session: TutorSession,
        practiceSet: TutorPracticeSet,
        evaluation: TutorPracticeEvaluation,
        candidateID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> TutorInsightCandidate {
        try insightCapture.capturePracticeEvaluation(
            learnerID: learnerID,
            session: session,
            practiceSet: practiceSet,
            evaluation: evaluation,
            candidateID: candidateID,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func captureStudyPlan(
        learnerID: String,
        scope: TutorScope? = nil,
        plan: TutorStudyPlan,
        candidateID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> TutorInsightCandidate {
        try insightCapture.captureStudyPlan(
            learnerID: learnerID,
            scope: scope,
            plan: plan,
            candidateID: candidateID,
            fileManager: fileManager
        )
    }

    public func candidate(candidateID: String) throws -> TutorInsightCandidate {
        guard let candidate = try candidateStore.load(candidateID: candidateID) else {
            throw ASKProductIntegrationError.tutorInsightCandidateNotFound(candidateID)
        }
        return candidate
    }

    public func listCandidates() throws -> [TutorInsightCandidate] {
        try candidateStore.list()
    }

    public func listAppliedRecords() throws -> [TutorInsightAppliedRecord] {
        try appliedStore.list()
    }

    public func buildProposal(candidateID: String) throws -> TutorInsightProposal {
        try proposalBuilder.buildProposal(for: candidate(candidateID: candidateID))
    }

    @discardableResult
    public func stageProposal(candidateID: String) throws -> TutorInsightProposal {
        let proposal = try buildProposal(candidateID: candidateID)
        try maintainer.stage(proposal.patch)
        return proposal
    }

    @discardableResult
    public func applyCandidate(
        candidateID: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil,
        fileManager: FileManager = .default
    ) async throws -> TutorInsightApplyResult {
        let proposal = try buildProposal(candidateID: candidateID)
        return try await applyExecutor.apply(
            proposal: proposal,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason,
            fileManager: fileManager
        )
    }

    private var proposalBuilder: ASKKnowledgeProposalBuilder {
        ASKKnowledgeProposalBuilder(maintainer: maintainer)
    }

    private var applyExecutor: ASKKnowledgeApplyExecutor {
        ASKKnowledgeApplyExecutor(
            workspace: workspace,
            maintainer: maintainer,
            candidateStore: candidateStore,
            appliedStore: appliedStore,
            pageIndexBuilder: pageIndexBuilder,
            presentationBuilder: presentationBuilder
        )
    }
}
