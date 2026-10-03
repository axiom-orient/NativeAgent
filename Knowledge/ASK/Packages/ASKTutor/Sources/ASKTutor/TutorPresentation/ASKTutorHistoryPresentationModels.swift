import KnowledgePresentation
import Foundation

public enum TutorProjectionLinkStatus: String, Sendable, Equatable {
    case linked
    case noProjection
    case projectionNotFound
}

public struct TutorProjectionLink: Sendable {
    public let projectionSlug: String?
    public let readingContext: ASKProjectionReadingContext?
    public let status: TutorProjectionLinkStatus

    public init(
        projectionSlug: String?,
        readingContext: ASKProjectionReadingContext?,
        status: TutorProjectionLinkStatus
    ) {
        self.projectionSlug = projectionSlug
        self.readingContext = readingContext
        self.status = status
    }
}

public struct TutorSessionScopePresentation: Sendable {
    public let sessionID: String
    public let scope: TutorScope
    public let projectionLink: TutorProjectionLink

    public init(
        sessionID: String,
        scope: TutorScope,
        projectionLink: TutorProjectionLink
    ) {
        self.sessionID = sessionID
        self.scope = scope
        self.projectionLink = projectionLink
    }
}

public struct TutorTranscriptEntryPresentation: Sendable {
    public let entry: TutorTranscriptEntry
    public let citationLinks: [TutorProjectionLink]

    public init(entry: TutorTranscriptEntry, citationLinks: [TutorProjectionLink]) {
        self.entry = entry
        self.citationLinks = citationLinks
    }
}

public struct TutorSessionHistoryPresentation: Sendable {
    public let session: TutorSession
    public let scopePresentation: TutorSessionScopePresentation
    public let transcript: [TutorTranscriptEntryPresentation]

    public init(
        session: TutorSession,
        scopePresentation: TutorSessionScopePresentation,
        transcript: [TutorTranscriptEntryPresentation]
    ) {
        self.session = session
        self.scopePresentation = scopePresentation
        self.transcript = transcript
    }
}

public struct TutorPracticeQuestionPresentation: Sendable {
    public let question: TutorPracticeQuestion
    public let citationLinks: [TutorProjectionLink]

    public init(question: TutorPracticeQuestion, citationLinks: [TutorProjectionLink]) {
        self.question = question
        self.citationLinks = citationLinks
    }
}

public struct TutorEvidenceHitPresentation: Sendable {
    public let evidenceHit: TutorEvidenceHit
    public let projectionLink: TutorProjectionLink

    public init(evidenceHit: TutorEvidenceHit, projectionLink: TutorProjectionLink) {
        self.evidenceHit = evidenceHit
        self.projectionLink = projectionLink
    }
}

public struct TutorPracticeSetHistoryPresentation: Sendable {
    public let practiceSet: TutorPracticeSet
    public let session: TutorSession
    public let scopePresentation: TutorSessionScopePresentation
    public let questions: [TutorPracticeQuestionPresentation]
    public let evidence: [TutorEvidenceHitPresentation]

    public init(
        practiceSet: TutorPracticeSet,
        session: TutorSession,
        scopePresentation: TutorSessionScopePresentation,
        questions: [TutorPracticeQuestionPresentation],
        evidence: [TutorEvidenceHitPresentation]
    ) {
        self.practiceSet = practiceSet
        self.session = session
        self.scopePresentation = scopePresentation
        self.questions = questions
        self.evidence = evidence
    }
}

public struct TutorPracticeEvaluationHistoryPresentation: Sendable {
    public let evaluation: TutorPracticeEvaluation
    public let practiceSetPresentation: TutorPracticeSetHistoryPresentation

    public init(
        evaluation: TutorPracticeEvaluation,
        practiceSetPresentation: TutorPracticeSetHistoryPresentation
    ) {
        self.evaluation = evaluation
        self.practiceSetPresentation = practiceSetPresentation
    }
}
