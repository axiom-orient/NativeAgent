import Foundation

public struct TutorCitation: Codable, Sendable, Equatable {
    public var docID: String
    public var title: String
    public var projectionSlug: String?

    public init(docID: String, title: String, projectionSlug: String?) {
        self.docID = docID
        self.title = title
        self.projectionSlug = projectionSlug
    }
}

public struct TutorEvidenceHit: Codable, Sendable, Equatable {
    public var docID: String
    public var docKind: String
    public var title: String
    public var subjectKind: String
    public var subjectID: String
    public var projectionSlug: String?
    public var score: Double
    public var snippet: String
    public var metadata: [String: String]

    public init(
        docID: String,
        docKind: String,
        title: String,
        subjectKind: String,
        subjectID: String,
        projectionSlug: String?,
        score: Double,
        snippet: String,
        metadata: [String: String]
    ) {
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

public struct TutorKnowledgeGap: Codable, Sendable, Equatable {
    public var patchID: String
    public var requiresHumanApproval: Bool
    public var requiresHumanChoice: Bool
    public var warnings: [String]

    public init(patchID: String, requiresHumanApproval: Bool, requiresHumanChoice: Bool, warnings: [String]) {
        self.patchID = patchID
        self.requiresHumanApproval = requiresHumanApproval
        self.requiresHumanChoice = requiresHumanChoice
        self.warnings = warnings
    }
}

public struct TutorGrounding: Codable, Sendable, Equatable {
    public var question: String
    public var answer: String
    public var citations: [TutorCitation]
    public var results: [TutorEvidenceHit]
    public var knowledgeGap: TutorKnowledgeGap?

    public init(
        question: String,
        answer: String,
        citations: [TutorCitation],
        results: [TutorEvidenceHit],
        knowledgeGap: TutorKnowledgeGap?
    ) {
        self.question = question
        self.answer = answer
        self.citations = citations
        self.results = results
        self.knowledgeGap = knowledgeGap
    }
}

public struct TutorProjectionSnapshot: Codable, Sendable, Equatable {
    public var slug: String
    public var title: String
    public var bodyMD: String
    public var subjectKind: String
    public var subjectID: String

    public init(slug: String, title: String, bodyMD: String, subjectKind: String, subjectID: String) {
        self.slug = slug
        self.title = title
        self.bodyMD = bodyMD
        self.subjectKind = subjectKind
        self.subjectID = subjectID
    }
}

public struct TutorKnowledgeStateSummary: Codable, Sendable, Equatable {
    public var approvedPatchCount: Int
    public var rejectedPatchCount: Int
    public var pendingPatchCount: Int
    public var authorityRecordCount: Int
    public var visibleProjectionCount: Int
    public var searchDocCount: Int
    public var fileCount: Int

    public init(
        approvedPatchCount: Int,
        rejectedPatchCount: Int,
        pendingPatchCount: Int,
        authorityRecordCount: Int,
        visibleProjectionCount: Int,
        searchDocCount: Int,
        fileCount: Int
    ) {
        self.approvedPatchCount = approvedPatchCount
        self.rejectedPatchCount = rejectedPatchCount
        self.pendingPatchCount = pendingPatchCount
        self.authorityRecordCount = authorityRecordCount
        self.visibleProjectionCount = visibleProjectionCount
        self.searchDocCount = searchDocCount
        self.fileCount = fileCount
    }
}

public struct TutorKnowledgeMaintenanceItem: Codable, Sendable, Equatable {
    public var kind: String
    public var summary: String

    public init(kind: String, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public struct TutorKnowledgeHealthSnapshot: Codable, Sendable, Equatable {
    public var pendingReviewCount: Int
    public var choiceRequiredCount: Int
    public var lintFindingCount: Int
    public var maintenanceItems: [TutorKnowledgeMaintenanceItem]

    public init(
        pendingReviewCount: Int,
        choiceRequiredCount: Int,
        lintFindingCount: Int,
        maintenanceItems: [TutorKnowledgeMaintenanceItem]
    ) {
        self.pendingReviewCount = pendingReviewCount
        self.choiceRequiredCount = choiceRequiredCount
        self.lintFindingCount = lintFindingCount
        self.maintenanceItems = maintenanceItems
    }
}
