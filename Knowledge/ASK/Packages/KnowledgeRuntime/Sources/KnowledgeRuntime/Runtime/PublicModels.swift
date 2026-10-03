import Foundation
import KnowledgeCore

public struct ASKImportedCapture: Codable, Equatable, Sendable {
    public var sourceID: String
    public var rawRelpath: String
    public var contentHash: String
    public var rawPath: String
    public var manifestPath: String
    public var collectedPath: String
    public var notePath: String

    public init(sourceID: String, rawRelpath: String, contentHash: String, rawPath: String, manifestPath: String, collectedPath: String, notePath: String) {
        self.sourceID = sourceID
        self.rawRelpath = rawRelpath
        self.contentHash = contentHash
        self.rawPath = rawPath
        self.manifestPath = manifestPath
        self.collectedPath = collectedPath
        self.notePath = notePath
    }

}

public struct ASKVisibleProjection: Codable, Equatable, Sendable {
    public var state: ProjectionState
    public var title: String
    public var space: ProjectionSpace

    public init(state: ProjectionState, title: String, space: ProjectionSpace) {
        self.state = state
        self.title = title
        self.space = space
    }

    package init(_ snapshot: VisibleProjectionSnapshot) {
        self.init(state: snapshot.state, title: snapshot.title, space: snapshot.space)
    }
}

public struct ASKStateSnapshot: Codable, Equatable, Sendable {
    public var approvedPatchIDs: [String]
    public var rejectedPatchIDs: [String]
    public var pendingPatchIDs: [String]
    public var authorityRecordCount: Int
    public var visibleProjections: [String: ASKVisibleProjection]
    public var searchDocCount: Int
    public var mirrorCounts: [String: Int]
    public var fileCount: Int

    public init(
        approvedPatchIDs: [String],
        rejectedPatchIDs: [String],
        pendingPatchIDs: [String],
        authorityRecordCount: Int,
        visibleProjections: [String: ASKVisibleProjection],
        searchDocCount: Int,
        mirrorCounts: [String: Int],
        fileCount: Int
    ) {
        self.approvedPatchIDs = approvedPatchIDs
        self.rejectedPatchIDs = rejectedPatchIDs
        self.pendingPatchIDs = pendingPatchIDs
        self.authorityRecordCount = authorityRecordCount
        self.visibleProjections = visibleProjections
        self.searchDocCount = searchDocCount
        self.mirrorCounts = mirrorCounts
        self.fileCount = fileCount
    }

    package init(_ snapshot: VaultDumpState) {
        self.init(
            approvedPatchIDs: snapshot.approvedPatchIDs,
            rejectedPatchIDs: snapshot.rejectedPatchIDs,
            pendingPatchIDs: snapshot.pendingPatchIDs,
            authorityRecordCount: snapshot.authorityRecords.count,
            visibleProjections: snapshot.visibleProjections.mapValues(ASKVisibleProjection.init),
            searchDocCount: snapshot.searchDocs.count,
            mirrorCounts: snapshot.mirrorCounts,
            fileCount: snapshot.files.count
        )
    }
}

public struct ASKRebuildSummary: Sendable, Equatable, Codable {
    public var approvedPatchIDs: [String]
    public var rejectedPatchIDs: [String]
    public var pendingPatchIDs: [String]
    public var mirrorCounts: [String: Int]

    public init(approvedPatchIDs: [String], rejectedPatchIDs: [String], pendingPatchIDs: [String], mirrorCounts: [String: Int]) {
        self.approvedPatchIDs = approvedPatchIDs
        self.rejectedPatchIDs = rejectedPatchIDs
        self.pendingPatchIDs = pendingPatchIDs
        self.mirrorCounts = mirrorCounts
    }

    package init(_ report: RebuildReport) {
        self.init(
            approvedPatchIDs: report.approvedPatchIDs,
            rejectedPatchIDs: report.rejectedPatchIDs,
            pendingPatchIDs: report.pendingPatchIDs,
            mirrorCounts: report.mirrorCounts
        )
    }
}

/// Outcome of `applyBatch`: what reached the journal, the single rebuild that
/// followed, and the decision that stopped the batch if one did. Entries in
/// `applied` are committed even when `failure` is present.
public struct ASKBatchApplySummary: Sendable, Equatable, Codable {
    public struct Decision: Sendable, Equatable, Codable {
        public var patchID: String
        public var decision: String

        public init(patchID: String, decision: String) {
            self.patchID = patchID
            self.decision = decision
        }
    }

    public struct Failure: Sendable, Equatable, Codable {
        public var patchID: String
        public var message: String

        public init(patchID: String, message: String) {
            self.patchID = patchID
            self.message = message
        }
    }

    public var applied: [Decision]
    public var rebuild: ASKRebuildSummary
    public var failure: Failure?

    public init(applied: [Decision], rebuild: ASKRebuildSummary, failure: Failure?) {
        self.applied = applied
        self.rebuild = rebuild
        self.failure = failure
    }

    package init(_ result: BatchApplyResult) {
        self.init(
            applied: result.applied.map { Decision(patchID: $0.patchID, decision: $0.decision) },
            rebuild: ASKRebuildSummary(result.rebuild),
            failure: result.failure.map { Failure(patchID: $0.patchID, message: $0.message) }
        )
    }
}

public struct ASKApplySummary: Sendable, Equatable, Codable {
    public var patchID: String
    public var decision: String
    public var rebuild: ASKRebuildSummary

    public init(patchID: String, decision: String, rebuild: ASKRebuildSummary) {
        self.patchID = patchID
        self.decision = decision
        self.rebuild = rebuild
    }

    package init(_ result: ApplyResult) {
        self.init(
            patchID: result.patchID,
            decision: result.decision,
            rebuild: ASKRebuildSummary(result.rebuild)
        )
    }
}

package struct StagePatchResult: Sendable, Equatable, Codable {
    package var patchID: String
    package var status: String
    package var pendingPatchIDs: [String]

    package init(patchID: String, status: String, pendingPatchIDs: [String]) {
        self.patchID = patchID
        self.status = status
        self.pendingPatchIDs = pendingPatchIDs
    }
}
