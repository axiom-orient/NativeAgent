import Foundation
import KnowledgeCore

public struct ASKPostCommitMaterializationError: Error, Sendable, Equatable, LocalizedError {
    public var patchID: String
    public var decision: PatchDecision
    public var cause: String

    public init(patchID: String, decision: PatchDecision, cause: String) {
        self.patchID = patchID
        self.decision = decision
        self.cause = cause
    }

    public var errorDescription: String? {
        "canonical patch \(patchID) was committed as \(decision.rawValue), but derived materialization failed: \(cause)"
    }
}

/// `applyBatch` reached canonical decision state, but the single derived
/// materialization for that batch failed. `applied` contains only decisions
/// newly committed by this invocation. `failure` preserves any earlier
/// decision that stopped the batch before materialization was attempted.
public struct ASKBatchPostCommitMaterializationError: Error, Sendable, Equatable, LocalizedError {
    public var applied: [ASKBatchApplySummary.Decision]
    public var failure: ASKBatchApplySummary.Failure?
    public var cause: String

    public init(
        applied: [ASKBatchApplySummary.Decision],
        failure: ASKBatchApplySummary.Failure?,
        cause: String
    ) {
        self.applied = applied
        self.failure = failure
        self.cause = cause
    }

    package init(
        applied: [ApplyDecisionSummary],
        failure: BatchApplyFailure?,
        cause: String
    ) {
        self.init(
            applied: applied.map { ASKBatchApplySummary.Decision(patchID: $0.patchID, decision: $0.decision) },
            failure: failure.map { ASKBatchApplySummary.Failure(patchID: $0.patchID, message: $0.message) },
            cause: cause
        )
    }

    public var errorDescription: String? {
        var description = "canonical batch state contains \(applied.count) newly committed decision(s), but derived materialization failed: \(cause)"
        if let failure {
            description += "; batch had already stopped at patch \(failure.patchID): \(failure.message)"
        }
        return description
    }
}

public struct SearchHitSummary: Sendable, Equatable, Codable {
    public var docID: String
    public var docKind: String
    public var title: String
    public var subjectKind: String
    public var subjectID: String
    public var projectionSlug: String?
    public var score: Double
    public var snippet: String
    public var metadata: ASKFields

    public init(docID: String, docKind: String, title: String, subjectKind: String, subjectID: String, projectionSlug: String?, score: Double, snippet: String, metadata: ASKFields) {
        self.docID = docID
        self.docKind = docKind
        self.title = title
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.projectionSlug = projectionSlug
        self.score = score
        self.snippet = snippet
        self.metadata = metadata
    }
}

public struct SearchResult: Sendable, Equatable, Codable {
    public var query: String
    public var hits: [SearchHitSummary]

    public init(query: String, hits: [SearchHitSummary]) {
        self.query = query
        self.hits = hits
    }
}

public struct QueryCitation: Sendable, Equatable, Codable {
    public var docID: String
    public var title: String
    public var projectionSlug: String?

    public init(docID: String, title: String, projectionSlug: String?) {
        self.docID = docID
        self.title = title
        self.projectionSlug = projectionSlug
    }
}

public struct QueryResult: Sendable, Equatable, Codable {
    public var question: String
    public var answer: String
    public var citations: [QueryCitation]
    public var results: [SearchHitSummary]
    public var fileBackPatch: KnowledgePatchPlan?

    public init(question: String, answer: String, citations: [QueryCitation], results: [SearchHitSummary], fileBackPatch: KnowledgePatchPlan?) {
        self.question = question
        self.answer = answer
        self.citations = citations
        self.results = results
        self.fileBackPatch = fileBackPatch
    }
}

package struct DebugMirrorCandidate: Sendable, Equatable {
    package var docID: String
    package var docKind: String
    package var title: String
    package var subjectID: String
    package var snippet: String
    package var rank: Double
    package var metadata: ASKFields
}

package struct DebugQuerySelection: Sendable, Equatable {
    package var searchHitCount: Int
    package var preferredHitCount: Int
    package var selectedHitCount: Int
    package var failureKind: String?
    package var selectedHits: [SearchHitSummary]
}

public struct LintFinding: Sendable, Equatable, Codable {
    public var kind: String
    public var severity: String
    public var count: Int
    public var items: [String]?

    public init(kind: String, severity: String, count: Int, items: [String]? = nil) {
        self.kind = kind
        self.severity = severity
        self.count = count
        self.items = items
    }
}

public struct LintResult: Sendable, Equatable, Codable {
    public var findingCount: Int
    public var findings: [LintFinding]

    public init(findingCount: Int, findings: [LintFinding]) {
        self.findingCount = findingCount
        self.findings = findings
    }
}

public struct ReviewQueueOption: Sendable, Equatable, Codable {
    public var optionID: String
    public var label: String
    public var summary: String
    public var effect: String
    public var details: ASKFields

    public init(optionID: String, label: String, summary: String, effect: String, details: ASKFields) {
        self.optionID = optionID
        self.label = label
        self.summary = summary
        self.effect = effect
        self.details = details
    }
}

public struct ReviewQueueItem: Sendable, Equatable, Codable {
    public var reviewID: String
    public var reviewKind: String
    public var severity: String
    public var subjectKind: String
    public var subjectID: String
    public var summary: String
    public var createdAt: String
    public var requiresChoice: Bool
    public var details: ASKFields
    public var options: [ReviewQueueOption]

    public init(reviewID: String, reviewKind: String, severity: String, subjectKind: String, subjectID: String, summary: String, createdAt: String, requiresChoice: Bool, details: ASKFields, options: [ReviewQueueOption]) {
        self.reviewID = reviewID
        self.reviewKind = reviewKind
        self.severity = severity
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.summary = summary
        self.createdAt = createdAt
        self.requiresChoice = requiresChoice
        self.details = details
        self.options = options
    }
}

public struct ReviewQueueResult: Sendable, Equatable, Codable {
    public var pendingCount: Int
    public var choiceRequiredCount: Int
    public var items: [ReviewQueueItem]

    public init(pendingCount: Int, choiceRequiredCount: Int, items: [ReviewQueueItem]) {
        self.pendingCount = pendingCount
        self.choiceRequiredCount = choiceRequiredCount
        self.items = items
    }
}
