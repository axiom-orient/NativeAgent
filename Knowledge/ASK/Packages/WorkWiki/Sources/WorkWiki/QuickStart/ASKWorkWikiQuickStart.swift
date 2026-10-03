import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public struct ASKWorkWikiQuickStartRequest: Sendable, Equatable {
    public var workspaceURL: URL
    public var requestedAt: String
    public var indexURL: URL?
    public var vaultURL: URL?
    public var decidedBy: String
    public var reason: String
    public var resetExistingWorkspace: Bool

    public init(
        workspaceURL: URL,
        requestedAt: String,
        indexURL: URL? = nil,
        vaultURL: URL? = nil,
        decidedBy: String = "quickstart",
        reason: String = "quick-start approval",
        resetExistingWorkspace: Bool = false
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.requestedAt = requestedAt
        self.indexURL = indexURL?.standardizedFileURL
        self.vaultURL = vaultURL?.standardizedFileURL
        self.decidedBy = decidedBy
        self.reason = reason
        self.resetExistingWorkspace = resetExistingWorkspace
    }
}

public struct ASKWorkWikiFromExistingWorkspaceRequest: Sendable, Equatable {
    public var sourceRootURL: URL
    public var workspaceURL: URL
    public var title: String
    public var queryText: String
    public var requestedAt: String
    public var indexURL: URL?
    public var vaultURL: URL?
    public var decidedBy: String
    public var reason: String
    public var slug: String?
    public var subjectID: String?
    public var filter: ASKEvidenceFilter
    public var maxEvidenceBytes: Int
    public var includeStaleEvidence: Bool
    public var resetExistingWorkspace: Bool

    public init(
        sourceRootURL: URL,
        workspaceURL: URL,
        title: String,
        queryText: String,
        requestedAt: String,
        indexURL: URL? = nil,
        vaultURL: URL? = nil,
        decidedBy: String = "existing-workspace",
        reason: String = "from-existing-workspace approval",
        slug: String? = nil,
        subjectID: String? = nil,
        filter: ASKEvidenceFilter = .none,
        maxEvidenceBytes: Int = 262_144,
        includeStaleEvidence: Bool = false,
        resetExistingWorkspace: Bool = false
    ) {
        self.sourceRootURL = sourceRootURL
        self.workspaceURL = workspaceURL
        self.title = title
        self.queryText = queryText
        self.requestedAt = requestedAt
        self.indexURL = indexURL?.standardizedFileURL
        self.vaultURL = vaultURL?.standardizedFileURL
        self.decidedBy = decidedBy
        self.reason = reason
        self.slug = slug
        self.subjectID = subjectID
        self.filter = filter
        self.maxEvidenceBytes = maxEvidenceBytes
        self.includeStaleEvidence = includeStaleEvidence
        self.resetExistingWorkspace = resetExistingWorkspace
    }
}

public struct ASKWorkWikiSkippedSource: Codable, Sendable, Equatable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ASKWorkWikiQuickStartResult: Codable, Sendable, Equatable {
    public var ok: Bool { applyDecision == "approved" }
    public var operation: String
    public var status: String { ok ? "applied" : applyDecision }
    public var workspacePath: String
    public var sourceRootPath: String
    public var indexPath: String
    public var vaultPath: String
    public var sourcePath: String
    public var indexedCount: Int { indexedSourceIDs.count }
    public var indexedSourceIDs: [String]
    public var queryText: String
    public var reportTitle: String
    public var patchID: String
    public var projectionSlug: String
    public var evidenceHitCount: Int
    public var doctorFindingCountBeforeApproval: Int
    public var applyDecision: String
    public var remainingPendingPatchIDs: [String]
    public var publishedProjectionPath: String?
    public var publishedProjectionTitle: String
    public var publishedProjectionPreview: String
    public var followUpActions: [String]

    public init(
        operation: String,
        workspacePath: String,
        sourceRootPath: String,
        indexPath: String,
        vaultPath: String,
        sourcePath: String,
        indexedSourceIDs: [String],
        queryText: String,
        reportTitle: String,
        patchID: String,
        projectionSlug: String,
        evidenceHitCount: Int,
        doctorFindingCountBeforeApproval: Int,
        applyDecision: String,
        remainingPendingPatchIDs: [String],
        publishedProjectionPath: String?,
        publishedProjectionTitle: String,
        publishedProjectionPreview: String,
        followUpActions: [String]
    ) {
        self.operation = operation
        self.workspacePath = workspacePath
        self.sourceRootPath = sourceRootPath
        self.indexPath = indexPath
        self.vaultPath = vaultPath
        self.sourcePath = sourcePath
        self.indexedSourceIDs = indexedSourceIDs
        self.queryText = queryText
        self.reportTitle = reportTitle
        self.patchID = patchID
        self.projectionSlug = projectionSlug
        self.evidenceHitCount = evidenceHitCount
        self.doctorFindingCountBeforeApproval = doctorFindingCountBeforeApproval
        self.applyDecision = applyDecision
        self.remainingPendingPatchIDs = remainingPendingPatchIDs
        self.publishedProjectionPath = publishedProjectionPath
        self.publishedProjectionTitle = publishedProjectionTitle
        self.publishedProjectionPreview = publishedProjectionPreview
        self.followUpActions = followUpActions
    }

    public init(
        ok: Bool,
        operation: String,
        status: String,
        workspacePath: String,
        sourceRootPath: String,
        indexPath: String,
        vaultPath: String,
        sourcePath: String,
        indexedCount: Int,
        indexedSourceIDs: [String],
        queryText: String,
        reportTitle: String,
        patchID: String,
        projectionSlug: String,
        evidenceHitCount: Int,
        doctorFindingCountBeforeApproval: Int,
        applyDecision: String,
        remainingPendingPatchIDs: [String],
        publishedProjectionPath: String?,
        publishedProjectionTitle: String,
        publishedProjectionPreview: String,
        followUpActions: [String]
    ) {
        self.init(
            operation: operation,
            workspacePath: workspacePath,
            sourceRootPath: sourceRootPath,
            indexPath: indexPath,
            vaultPath: vaultPath,
            sourcePath: sourcePath,
            indexedSourceIDs: indexedSourceIDs,
            queryText: queryText,
            reportTitle: reportTitle,
            patchID: patchID,
            projectionSlug: projectionSlug,
            evidenceHitCount: evidenceHitCount,
            doctorFindingCountBeforeApproval: doctorFindingCountBeforeApproval,
            applyDecision: applyDecision,
            remainingPendingPatchIDs: remainingPendingPatchIDs,
            publishedProjectionPath: publishedProjectionPath,
            publishedProjectionTitle: publishedProjectionTitle,
            publishedProjectionPreview: publishedProjectionPreview,
            followUpActions: followUpActions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case operation
        case status
        case workspacePath
        case sourceRootPath
        case indexPath
        case vaultPath
        case sourcePath
        case indexedCount
        case indexedSourceIDs
        case queryText
        case reportTitle
        case patchID
        case projectionSlug
        case evidenceHitCount
        case doctorFindingCountBeforeApproval
        case applyDecision
        case remainingPendingPatchIDs
        case publishedProjectionPath
        case publishedProjectionTitle
        case publishedProjectionPreview
        case followUpActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Bool.self, forKey: .ok)
        _ = try container.decode(String.self, forKey: .status)
        _ = try container.decode(Int.self, forKey: .indexedCount)
        self.init(
            operation: try container.decode(String.self, forKey: .operation),
            workspacePath: try container.decode(String.self, forKey: .workspacePath),
            sourceRootPath: try container.decode(String.self, forKey: .sourceRootPath),
            indexPath: try container.decode(String.self, forKey: .indexPath),
            vaultPath: try container.decode(String.self, forKey: .vaultPath),
            sourcePath: try container.decode(String.self, forKey: .sourcePath),
            indexedSourceIDs: try container.decode([String].self, forKey: .indexedSourceIDs),
            queryText: try container.decode(String.self, forKey: .queryText),
            reportTitle: try container.decode(String.self, forKey: .reportTitle),
            patchID: try container.decode(String.self, forKey: .patchID),
            projectionSlug: try container.decode(String.self, forKey: .projectionSlug),
            evidenceHitCount: try container.decode(Int.self, forKey: .evidenceHitCount),
            doctorFindingCountBeforeApproval: try container.decode(Int.self, forKey: .doctorFindingCountBeforeApproval),
            applyDecision: try container.decode(String.self, forKey: .applyDecision),
            remainingPendingPatchIDs: try container.decode([String].self, forKey: .remainingPendingPatchIDs),
            publishedProjectionPath: try container.decodeIfPresent(String.self, forKey: .publishedProjectionPath),
            publishedProjectionTitle: try container.decode(String.self, forKey: .publishedProjectionTitle),
            publishedProjectionPreview: try container.decode(String.self, forKey: .publishedProjectionPreview),
            followUpActions: try container.decode([String].self, forKey: .followUpActions)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(operation, forKey: .operation)
        try container.encode(status, forKey: .status)
        try container.encode(workspacePath, forKey: .workspacePath)
        try container.encode(sourceRootPath, forKey: .sourceRootPath)
        try container.encode(indexPath, forKey: .indexPath)
        try container.encode(vaultPath, forKey: .vaultPath)
        try container.encode(sourcePath, forKey: .sourcePath)
        try container.encode(indexedCount, forKey: .indexedCount)
        try container.encode(indexedSourceIDs, forKey: .indexedSourceIDs)
        try container.encode(queryText, forKey: .queryText)
        try container.encode(reportTitle, forKey: .reportTitle)
        try container.encode(patchID, forKey: .patchID)
        try container.encode(projectionSlug, forKey: .projectionSlug)
        try container.encode(evidenceHitCount, forKey: .evidenceHitCount)
        try container.encode(doctorFindingCountBeforeApproval, forKey: .doctorFindingCountBeforeApproval)
        try container.encode(applyDecision, forKey: .applyDecision)
        try container.encode(remainingPendingPatchIDs, forKey: .remainingPendingPatchIDs)
        try container.encodeIfPresent(publishedProjectionPath, forKey: .publishedProjectionPath)
        try container.encode(publishedProjectionTitle, forKey: .publishedProjectionTitle)
        try container.encode(publishedProjectionPreview, forKey: .publishedProjectionPreview)
        try container.encode(followUpActions, forKey: .followUpActions)
    }
}

public struct ASKWorkWikiFromExistingWorkspaceResult: Codable, Sendable, Equatable {
    public var ok: Bool { applyDecision == "approved" }
    public var operation: String
    public var status: String { ok ? "applied" : applyDecision }
    public var workspacePath: String
    public var sourceRootPath: String
    public var indexPath: String
    public var vaultPath: String
    public var indexedCount: Int { indexedSourceIDs.count }
    public var indexedSourceIDs: [String]
    public var indexedPaths: [String]
    public var skippedCount: Int { skippedSources.count }
    public var skippedSources: [ASKWorkWikiSkippedSource]
    public var queryText: String
    public var reportTitle: String
    public var patchID: String
    public var projectionSlug: String
    public var evidenceHitCount: Int
    public var doctorFindingCountBeforeApproval: Int
    public var applyDecision: String
    public var remainingPendingPatchIDs: [String]
    public var publishedProjectionPath: String?
    public var publishedProjectionTitle: String
    public var publishedProjectionPreview: String
    public var followUpActions: [String]

    public init(
        operation: String,
        workspacePath: String,
        sourceRootPath: String,
        indexPath: String,
        vaultPath: String,
        indexedSourceIDs: [String],
        indexedPaths: [String],
        skippedSources: [ASKWorkWikiSkippedSource] = [],
        queryText: String,
        reportTitle: String,
        patchID: String,
        projectionSlug: String,
        evidenceHitCount: Int,
        doctorFindingCountBeforeApproval: Int,
        applyDecision: String,
        remainingPendingPatchIDs: [String],
        publishedProjectionPath: String?,
        publishedProjectionTitle: String,
        publishedProjectionPreview: String,
        followUpActions: [String]
    ) {
        self.operation = operation
        self.workspacePath = workspacePath
        self.sourceRootPath = sourceRootPath
        self.indexPath = indexPath
        self.vaultPath = vaultPath
        self.indexedSourceIDs = indexedSourceIDs
        self.indexedPaths = indexedPaths
        self.skippedSources = skippedSources
        self.queryText = queryText
        self.reportTitle = reportTitle
        self.patchID = patchID
        self.projectionSlug = projectionSlug
        self.evidenceHitCount = evidenceHitCount
        self.doctorFindingCountBeforeApproval = doctorFindingCountBeforeApproval
        self.applyDecision = applyDecision
        self.remainingPendingPatchIDs = remainingPendingPatchIDs
        self.publishedProjectionPath = publishedProjectionPath
        self.publishedProjectionTitle = publishedProjectionTitle
        self.publishedProjectionPreview = publishedProjectionPreview
        self.followUpActions = followUpActions
    }

    public init(
        ok: Bool,
        operation: String,
        status: String,
        workspacePath: String,
        sourceRootPath: String,
        indexPath: String,
        vaultPath: String,
        indexedCount: Int,
        indexedSourceIDs: [String],
        indexedPaths: [String],
        skippedCount: Int = 0,
        skippedSources: [ASKWorkWikiSkippedSource] = [],
        queryText: String,
        reportTitle: String,
        patchID: String,
        projectionSlug: String,
        evidenceHitCount: Int,
        doctorFindingCountBeforeApproval: Int,
        applyDecision: String,
        remainingPendingPatchIDs: [String],
        publishedProjectionPath: String?,
        publishedProjectionTitle: String,
        publishedProjectionPreview: String,
        followUpActions: [String]
    ) {
        self.init(
            operation: operation,
            workspacePath: workspacePath,
            sourceRootPath: sourceRootPath,
            indexPath: indexPath,
            vaultPath: vaultPath,
            indexedSourceIDs: indexedSourceIDs,
            indexedPaths: indexedPaths,
            skippedSources: skippedSources,
            queryText: queryText,
            reportTitle: reportTitle,
            patchID: patchID,
            projectionSlug: projectionSlug,
            evidenceHitCount: evidenceHitCount,
            doctorFindingCountBeforeApproval: doctorFindingCountBeforeApproval,
            applyDecision: applyDecision,
            remainingPendingPatchIDs: remainingPendingPatchIDs,
            publishedProjectionPath: publishedProjectionPath,
            publishedProjectionTitle: publishedProjectionTitle,
            publishedProjectionPreview: publishedProjectionPreview,
            followUpActions: followUpActions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case operation
        case status
        case workspacePath
        case sourceRootPath
        case indexPath
        case vaultPath
        case indexedCount
        case indexedSourceIDs
        case indexedPaths
        case skippedCount
        case skippedSources
        case queryText
        case reportTitle
        case patchID
        case projectionSlug
        case evidenceHitCount
        case doctorFindingCountBeforeApproval
        case applyDecision
        case remainingPendingPatchIDs
        case publishedProjectionPath
        case publishedProjectionTitle
        case publishedProjectionPreview
        case followUpActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Bool.self, forKey: .ok)
        _ = try container.decode(String.self, forKey: .status)
        _ = try container.decode(Int.self, forKey: .indexedCount)
        _ = try container.decode(Int.self, forKey: .skippedCount)
        self.init(
            operation: try container.decode(String.self, forKey: .operation),
            workspacePath: try container.decode(String.self, forKey: .workspacePath),
            sourceRootPath: try container.decode(String.self, forKey: .sourceRootPath),
            indexPath: try container.decode(String.self, forKey: .indexPath),
            vaultPath: try container.decode(String.self, forKey: .vaultPath),
            indexedSourceIDs: try container.decode([String].self, forKey: .indexedSourceIDs),
            indexedPaths: try container.decode([String].self, forKey: .indexedPaths),
            skippedSources: try container.decode([ASKWorkWikiSkippedSource].self, forKey: .skippedSources),
            queryText: try container.decode(String.self, forKey: .queryText),
            reportTitle: try container.decode(String.self, forKey: .reportTitle),
            patchID: try container.decode(String.self, forKey: .patchID),
            projectionSlug: try container.decode(String.self, forKey: .projectionSlug),
            evidenceHitCount: try container.decode(Int.self, forKey: .evidenceHitCount),
            doctorFindingCountBeforeApproval: try container.decode(Int.self, forKey: .doctorFindingCountBeforeApproval),
            applyDecision: try container.decode(String.self, forKey: .applyDecision),
            remainingPendingPatchIDs: try container.decode([String].self, forKey: .remainingPendingPatchIDs),
            publishedProjectionPath: try container.decodeIfPresent(String.self, forKey: .publishedProjectionPath),
            publishedProjectionTitle: try container.decode(String.self, forKey: .publishedProjectionTitle),
            publishedProjectionPreview: try container.decode(String.self, forKey: .publishedProjectionPreview),
            followUpActions: try container.decode([String].self, forKey: .followUpActions)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(operation, forKey: .operation)
        try container.encode(status, forKey: .status)
        try container.encode(workspacePath, forKey: .workspacePath)
        try container.encode(sourceRootPath, forKey: .sourceRootPath)
        try container.encode(indexPath, forKey: .indexPath)
        try container.encode(vaultPath, forKey: .vaultPath)
        try container.encode(indexedCount, forKey: .indexedCount)
        try container.encode(indexedSourceIDs, forKey: .indexedSourceIDs)
        try container.encode(indexedPaths, forKey: .indexedPaths)
        try container.encode(skippedCount, forKey: .skippedCount)
        try container.encode(skippedSources, forKey: .skippedSources)
        try container.encode(queryText, forKey: .queryText)
        try container.encode(reportTitle, forKey: .reportTitle)
        try container.encode(patchID, forKey: .patchID)
        try container.encode(projectionSlug, forKey: .projectionSlug)
        try container.encode(evidenceHitCount, forKey: .evidenceHitCount)
        try container.encode(doctorFindingCountBeforeApproval, forKey: .doctorFindingCountBeforeApproval)
        try container.encode(applyDecision, forKey: .applyDecision)
        try container.encode(remainingPendingPatchIDs, forKey: .remainingPendingPatchIDs)
        try container.encodeIfPresent(publishedProjectionPath, forKey: .publishedProjectionPath)
        try container.encode(publishedProjectionTitle, forKey: .publishedProjectionTitle)
        try container.encode(publishedProjectionPreview, forKey: .publishedProjectionPreview)
        try container.encode(followUpActions, forKey: .followUpActions)
    }
}

public struct ASKWorkWikiQuickStartRunner: Sendable {
    let sourceArtifactBuilder: any SourceArtifactBuilding

    public init() {
        self.sourceArtifactBuilder = DefaultSourceArtifactBuilder()
    }

    init(sourceArtifactBuilder: any SourceArtifactBuilding) {
        self.sourceArtifactBuilder = sourceArtifactBuilder
    }

}
