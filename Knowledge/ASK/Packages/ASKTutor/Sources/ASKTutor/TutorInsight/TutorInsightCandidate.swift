import Foundation

public enum TutorInsightCandidateKind: String, Codable, Sendable, Equatable {
    case narrative
    case practiceSet
    case practiceEvaluation
    case studyPlan
}

public enum TutorInsightSuggestedAction: String, Codable, Sendable, Equatable {
    case createProjection
    case updateProjection
    case reviewKnowledgeGap
    case reviewPracticeWeaknesses
    case reviewStudyPlan
}

public enum TutorInsightEvidenceKind: String, Codable, Sendable, Equatable {
    case citation
    case searchHit
}

public struct TutorInsightEvidence: Codable, Sendable, Equatable, Hashable {
    public let kind: TutorInsightEvidenceKind
    public let docID: String
    public let title: String
    public let projectionSlug: String?
    public let askSourceIDs: [String]
    public let snippet: String?
    public let subjectKind: String?
    public let subjectID: String?
    public let metadata: [String: String]

    public init(
        kind: TutorInsightEvidenceKind,
        docID: String,
        title: String,
        projectionSlug: String?,
        askSourceIDs: [String],
        snippet: String?,
        subjectKind: String?,
        subjectID: String?,
        metadata: [String: String]
    ) {
        self.kind = kind
        self.docID = docID
        self.title = title
        self.projectionSlug = projectionSlug
        self.askSourceIDs = askSourceIDs
        self.snippet = snippet
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.metadata = metadata
    }
}

public struct TutorInsightCandidate: Codable, Sendable, Equatable {
    public let candidateID: String
    public let learnerID: String
    public let sessionID: String?
    public let createdAt: String
    public let kind: TutorInsightCandidateKind
    public let scope: TutorScope?
    public let primaryProjectionSlug: String?
    public let preferredProjectionSlug: String?
    public let citationProjectionSlugs: [String]
    public let sourceIDs: [String]
    public let prompt: String?
    public let title: String
    public let summary: String
    public let bodyMarkdown: String
    public let evidence: [TutorInsightEvidence]
    public let relatedConceptIDs: [String]
    public let suggestedActions: [TutorInsightSuggestedAction]
    public let knowledgeGap: TutorKnowledgeGap?

    public init(
        candidateID: String,
        learnerID: String,
        sessionID: String?,
        createdAt: String,
        kind: TutorInsightCandidateKind,
        scope: TutorScope?,
        primaryProjectionSlug: String?,
        preferredProjectionSlug: String? = nil,
        citationProjectionSlugs: [String],
        sourceIDs: [String] = [],
        prompt: String?,
        title: String,
        summary: String,
        bodyMarkdown: String,
        evidence: [TutorInsightEvidence],
        relatedConceptIDs: [String],
        suggestedActions: [TutorInsightSuggestedAction],
        knowledgeGap: TutorKnowledgeGap?
    ) {
        self.candidateID = candidateID
        self.learnerID = learnerID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.kind = kind
        self.scope = scope
        self.primaryProjectionSlug = primaryProjectionSlug
        self.preferredProjectionSlug = preferredProjectionSlug ?? primaryProjectionSlug
        self.citationProjectionSlugs = citationProjectionSlugs
        self.sourceIDs = sourceIDs
        self.prompt = prompt
        self.title = title
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.evidence = evidence
        self.relatedConceptIDs = relatedConceptIDs
        self.suggestedActions = suggestedActions
        self.knowledgeGap = knowledgeGap
    }
}
