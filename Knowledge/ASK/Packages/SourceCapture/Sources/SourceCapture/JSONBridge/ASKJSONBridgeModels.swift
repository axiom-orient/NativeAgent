import Foundation
import KnowledgeCore
import KnowledgeRuntime

public enum ASKJSONBridgeError: Error, Equatable, Sendable {
    case invalidArguments(tool: String, reason: String)
    case mutationDenied(String)
    case unknownTool(String)
}

public struct ASKStateSummary: Codable, Equatable, Sendable {
    public var approvedPatchCount: Int
    public var rejectedPatchCount: Int
    public var pendingPatchCount: Int
    public var authorityRecordCount: Int
    public var visibleProjectionCount: Int
    public var searchDocCount: Int
    public var mirrorCounts: [String: Int]
    public var fileCount: Int

    public init(
        approvedPatchCount: Int,
        rejectedPatchCount: Int,
        pendingPatchCount: Int,
        authorityRecordCount: Int,
        visibleProjectionCount: Int,
        searchDocCount: Int,
        mirrorCounts: [String: Int],
        fileCount: Int
    ) {
        self.approvedPatchCount = approvedPatchCount
        self.rejectedPatchCount = rejectedPatchCount
        self.pendingPatchCount = pendingPatchCount
        self.authorityRecordCount = authorityRecordCount
        self.visibleProjectionCount = visibleProjectionCount
        self.searchDocCount = searchDocCount
        self.mirrorCounts = mirrorCounts
        self.fileCount = fileCount
    }

    package init(snapshot: ASKStateSnapshot) {
        self.init(
            approvedPatchCount: snapshot.approvedPatchIDs.count,
            rejectedPatchCount: snapshot.rejectedPatchIDs.count,
            pendingPatchCount: snapshot.pendingPatchIDs.count,
            authorityRecordCount: snapshot.authorityRecordCount,
            visibleProjectionCount: snapshot.visibleProjections.count,
            searchDocCount: snapshot.searchDocCount,
            mirrorCounts: snapshot.mirrorCounts,
            fileCount: snapshot.fileCount
        )
    }
}
