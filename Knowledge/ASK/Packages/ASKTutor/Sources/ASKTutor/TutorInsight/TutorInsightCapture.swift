import Foundation
import KnowledgeCore
import KnowledgeRuntime

public struct TutorInsightCapture: Sendable {
    public let store: TutorInsightCandidateStore
    public let knowledgeReader: (any ASKKnowledgeReader)?

    public init(store: TutorInsightCandidateStore, knowledgeReader: (any ASKKnowledgeReader)? = nil) {
        self.store = store
        self.knowledgeReader = knowledgeReader
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
        try resolver.validateTimestamp(reply.createdAt)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw ASKProductIntegrationError.invalidTutorInsightPrompt(prompt)
        }
        guard session.sessionID == reply.sessionID else {
            throw ASKProductIntegrationError.tutorSessionMismatch(expected: session.sessionID, actual: reply.sessionID)
        }

        let evidence = resolver.uniqueEvidence(reply.citations.map(TutorInsightCaptureResolver.makeEvidence))
        let citationProjectionSlugs = resolver.projectionSlugs(from: evidence, fallback: session.scope.projectionSlug)
        let primaryProjectionSlug = citationProjectionSlugs.first
        let sourceIDs = try resolver.resolveSourceIDs(for: primaryProjectionSlug, evidence: evidence)
        let resolvedCandidateID = candidateID ?? Self.makeCandidateID(
            kind: .narrative,
            learnerID: learnerID,
            sessionID: session.sessionID,
            createdAt: reply.createdAt,
            discriminator: "\(reply.turnID):\(normalizedPrompt)"
        )
        let candidate = TutorInsightCandidate(
            candidateID: resolvedCandidateID,
            learnerID: learnerID,
            sessionID: session.sessionID,
            createdAt: reply.createdAt,
            kind: .narrative,
            scope: session.scope,
            primaryProjectionSlug: primaryProjectionSlug,
            citationProjectionSlugs: citationProjectionSlugs,
            sourceIDs: sourceIDs,
            prompt: normalizedPrompt,
            title: reply.title,
            summary: reply.summary,
            bodyMarkdown: TutorInsightMarkdownFormatter.narrative(prompt: normalizedPrompt, reply: reply),
            evidence: evidence,
            relatedConceptIDs: [],
            suggestedActions: TutorInsightSuggestedActionPolicies.make(
                primaryProjectionSlug: primaryProjectionSlug,
                includePracticeReview: false,
                includeStudyPlanReview: false
            ),
            knowledgeGap: reply.knowledgeGap
        )
        try store.save(candidate, fileManager: fileManager)
        return candidate
    }

    @discardableResult
    public func capturePracticeSet(
        learnerID: String,
        session: TutorSession,
        practiceSet: TutorPracticeSet,
        candidateID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> TutorInsightCandidate {
        try resolver.validateTimestamp(practiceSet.createdAt)
        guard practiceSet.sessionID == session.sessionID else {
            throw ASKProductIntegrationError.tutorPracticeSetMismatch(expectedSessionID: session.sessionID, actualSessionID: practiceSet.sessionID)
        }

        let evidence = resolver.uniqueEvidence(TutorInsightCaptureResolver.makeEvidence(practiceSet: practiceSet))
        let citationProjectionSlugs = resolver.projectionSlugs(from: evidence, fallback: session.scope.projectionSlug)
        let primaryProjectionSlug = citationProjectionSlugs.first
        let sourceIDs = try resolver.resolveSourceIDs(for: primaryProjectionSlug, evidence: evidence)
        let resolvedCandidateID = candidateID ?? Self.makeCandidateID(
            kind: .practiceSet,
            learnerID: learnerID,
            sessionID: session.sessionID,
            createdAt: practiceSet.createdAt,
            discriminator: practiceSet.practiceSetID
        )
        let candidate = TutorInsightCandidate(
            candidateID: resolvedCandidateID,
            learnerID: learnerID,
            sessionID: session.sessionID,
            createdAt: practiceSet.createdAt,
            kind: .practiceSet,
            scope: session.scope,
            primaryProjectionSlug: primaryProjectionSlug,
            citationProjectionSlugs: citationProjectionSlugs,
            sourceIDs: sourceIDs,
            prompt: practiceSet.topic,
            title: "Practice set: \(practiceSet.topic)",
            summary: practiceSet.recap.first ?? "Practice set generated for \(practiceSet.topic)",
            bodyMarkdown: TutorInsightMarkdownFormatter.practiceSet(practiceSet),
            evidence: evidence,
            relatedConceptIDs: TutorInsightCaptureResolver.uniqueStrings(practiceSet.questions.flatMap(\.conceptIDs)),
            suggestedActions: TutorInsightSuggestedActionPolicies.make(
                primaryProjectionSlug: primaryProjectionSlug,
                includePracticeReview: false,
                includeStudyPlanReview: false
            ),
            knowledgeGap: nil
        )
        try store.save(candidate, fileManager: fileManager)
        return candidate
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
        try resolver.validateTimestamp(evaluation.createdAt)
        guard practiceSet.sessionID == session.sessionID else {
            throw ASKProductIntegrationError.tutorPracticeSetMismatch(expectedSessionID: session.sessionID, actualSessionID: practiceSet.sessionID)
        }
        guard evaluation.practiceSetID == practiceSet.practiceSetID else {
            throw ASKProductIntegrationError.tutorPracticeEvaluationMismatch(expectedPracticeSetID: practiceSet.practiceSetID, actualPracticeSetID: evaluation.practiceSetID)
        }

        let evidence = resolver.uniqueEvidence(TutorInsightCaptureResolver.makeEvidence(practiceSet: practiceSet))
        let citationProjectionSlugs = resolver.projectionSlugs(from: evidence, fallback: session.scope.projectionSlug)
        let primaryProjectionSlug = citationProjectionSlugs.first
        let sourceIDs = try resolver.resolveSourceIDs(for: primaryProjectionSlug, evidence: evidence)
        let resolvedCandidateID = candidateID ?? Self.makeCandidateID(
            kind: .practiceEvaluation,
            learnerID: learnerID,
            sessionID: session.sessionID,
            createdAt: evaluation.createdAt,
            discriminator: practiceSet.practiceSetID
        )
        let candidate = TutorInsightCandidate(
            candidateID: resolvedCandidateID,
            learnerID: learnerID,
            sessionID: session.sessionID,
            createdAt: evaluation.createdAt,
            kind: .practiceEvaluation,
            scope: session.scope,
            primaryProjectionSlug: primaryProjectionSlug,
            citationProjectionSlugs: citationProjectionSlugs,
            sourceIDs: sourceIDs,
            prompt: practiceSet.topic,
            title: "Practice evaluation: \(practiceSet.topic)",
            summary: evaluation.summary,
            bodyMarkdown: TutorInsightMarkdownFormatter.practiceEvaluation(practiceSet: practiceSet, evaluation: evaluation),
            evidence: evidence,
            relatedConceptIDs: TutorInsightCaptureResolver.uniqueStrings(evaluation.itemResults.flatMap(\.conceptIDs)),
            suggestedActions: TutorInsightSuggestedActionPolicies.make(
                primaryProjectionSlug: primaryProjectionSlug,
                includePracticeReview: true,
                includeStudyPlanReview: false
            ),
            knowledgeGap: nil
        )
        try store.save(candidate, fileManager: fileManager)
        return candidate
    }

    @discardableResult
    public func captureStudyPlan(
        learnerID: String,
        scope: TutorScope? = nil,
        plan: TutorStudyPlan,
        candidateID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> TutorInsightCandidate {
        try resolver.validateTimestamp(plan.generatedAt)
        let primaryProjectionSlug = scope?.projectionSlug
        let resolvedCandidateID = candidateID ?? Self.makeCandidateID(
            kind: .studyPlan,
            learnerID: learnerID,
            sessionID: nil,
            createdAt: plan.generatedAt,
            discriminator: plan.headline
        )
        let candidate = TutorInsightCandidate(
            candidateID: resolvedCandidateID,
            learnerID: learnerID,
            sessionID: nil,
            createdAt: plan.generatedAt,
            kind: .studyPlan,
            scope: scope,
            primaryProjectionSlug: primaryProjectionSlug,
            citationProjectionSlugs: primaryProjectionSlug.map { [$0] } ?? [],
            sourceIDs: try resolver.resolveSourceIDs(for: primaryProjectionSlug, evidence: []),
            prompt: nil,
            title: plan.headline,
            summary: plan.rationale.first ?? plan.headline,
            bodyMarkdown: TutorInsightMarkdownFormatter.studyPlan(plan),
            evidence: [],
            relatedConceptIDs: TutorInsightCaptureResolver.uniqueStrings(plan.dueConceptIDs),
            suggestedActions: TutorInsightSuggestedActionPolicies.make(
                primaryProjectionSlug: primaryProjectionSlug,
                includePracticeReview: false,
                includeStudyPlanReview: true
            ),
            knowledgeGap: nil
        )
        try store.save(candidate, fileManager: fileManager)
        return candidate
    }

    public static func makeCandidateID(
        kind: TutorInsightCandidateKind,
        learnerID: String,
        sessionID: String?,
        createdAt: String,
        discriminator: String
    ) -> String {
        stableID(prefix: "insight", parts: [
            kind.rawValue,
            learnerID,
            sessionID ?? "",
            createdAt,
            discriminator,
        ])
    }

    private var resolver: TutorInsightCaptureResolver {
        TutorInsightCaptureResolver(knowledgeReader: knowledgeReader)
    }
}
