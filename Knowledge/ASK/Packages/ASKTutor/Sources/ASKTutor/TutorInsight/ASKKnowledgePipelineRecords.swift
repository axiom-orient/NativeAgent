import Foundation
import KnowledgeRuntime
import KnowledgePresentation

public struct TutorInsightProposal: Codable, Sendable, Equatable {
    public let candidate: TutorInsightCandidate
    public let targetProjectionSlug: String
    public let patch: KnowledgePatchPlan

    public init(candidate: TutorInsightCandidate, targetProjectionSlug: String, patch: KnowledgePatchPlan) {
        self.candidate = candidate
        self.targetProjectionSlug = targetProjectionSlug
        self.patch = patch
    }
}

public struct TutorInsightAppliedRecord: Codable, Sendable, Equatable {
    public let candidate: TutorInsightCandidate
    public let targetProjectionSlug: String
    public let patchID: String
    public let decidedBy: String
    public let decidedAt: String
    public let reason: String
    public let applySummary: ASKApplySummary
    public let presentationBundleName: String

    public init(
        candidate: TutorInsightCandidate,
        targetProjectionSlug: String,
        patchID: String,
        decidedBy: String,
        decidedAt: String,
        reason: String,
        applySummary: ASKApplySummary,
        presentationBundleName: String
    ) {
        self.candidate = candidate
        self.targetProjectionSlug = targetProjectionSlug
        self.patchID = patchID
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.reason = reason
        self.applySummary = applySummary
        self.presentationBundleName = presentationBundleName
    }
}

public struct TutorInsightAppliedRecordStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    @discardableResult
    public func save(_ record: TutorInsightAppliedRecord, fileManager: FileManager = .default) throws -> URL {
        let url = try recordFileURL(record.candidate.candidateID)
        return try TutorJSONDirectoryStore.save(record, to: url, rootURL: rootURL, fileManager: fileManager)
    }

    public func load(candidateID: String, fileManager: FileManager = .default) throws -> TutorInsightAppliedRecord? {
        let url = try recordFileURL(candidateID)
        return try TutorJSONDirectoryStore.load(TutorInsightAppliedRecord.self, from: url)
    }

    public func list(fileManager: FileManager = .default) throws -> [TutorInsightAppliedRecord] {
        try TutorJSONDirectoryStore.list(TutorInsightAppliedRecord.self, in: rootURL, fileManager: fileManager)
            .sorted {
                switch ASKTimestamp.compare($0.decidedAt, $1.decidedAt) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return $0.candidate.candidateID < $1.candidate.candidateID
                }
            }
    }

    private func recordFileURL(_ candidateID: String) throws -> URL {
        let normalized = try askProductNormalizedTutorInsightCandidateID(candidateID)
        return rootURL.appendingPathComponent("\(normalized).json", isDirectory: false)
    }
}

public enum TutorInsightPostCommitEffect: String, Codable, Sendable, Equatable {
    case persistAppliedRecord = "persist_applied_record"
    case rebuildPageIndex = "rebuild_page_index"
    case materializePresentation = "materialize_presentation"
    case removeCandidate = "remove_candidate"
}

/// Canonical knowledge is already committed. The candidate is intentionally
/// retained until every derived effect succeeds so the same decision context
/// can be retried without reconstructing hidden state.
public struct TutorInsightPostCommitError: Error, Sendable, Equatable, LocalizedError {
    public let committedRecord: TutorInsightAppliedRecord
    public let failedEffect: TutorInsightPostCommitEffect
    public let cause: String

    public init(
        committedRecord: TutorInsightAppliedRecord,
        failedEffect: TutorInsightPostCommitEffect,
        cause: String
    ) {
        self.committedRecord = committedRecord
        self.failedEffect = failedEffect
        self.cause = cause
    }

    public var errorDescription: String? {
        "tutor insight \(committedRecord.candidate.candidateID) committed as patch \(committedRecord.patchID), but post-commit effect \(failedEffect.rawValue) failed: \(cause)"
    }
}

public struct TutorInsightApplyResult: Sendable {
    public let record: TutorInsightAppliedRecord
    public let pageIndexBuild: ASKProjectionPageIndexBuildResult
    public let presentation: ASKProjectionPresentationPackage

    public init(
        record: TutorInsightAppliedRecord,
        pageIndexBuild: ASKProjectionPageIndexBuildResult,
        presentation: ASKProjectionPresentationPackage
    ) {
        self.record = record
        self.pageIndexBuild = pageIndexBuild
        self.presentation = presentation
    }
}
