import Foundation
import KnowledgeRuntime
import PageIndex

public enum ASKProjectionPageIndexBuildStatus: String, Codable, Hashable, Sendable {
    case indexed
    case missingSourceReceipt
    case missingRawFile
    case unsupportedFileFormat
    case failed
}

public struct ASKProjectionPageIndexBuildEntry: Codable, Hashable, Sendable {
    public let askSourceID: String
    public let pageIndexSourceID: SourceID?
    public let title: String?
    public let rawRelpath: String?
    public let status: ASKProjectionPageIndexBuildStatus
    public let detail: String?
    public let catalogEntryCount: Int
    public let rootAnchorCount: Int

    public init(
        askSourceID: String,
        pageIndexSourceID: SourceID?,
        title: String?,
        rawRelpath: String?,
        status: ASKProjectionPageIndexBuildStatus,
        detail: String? = nil,
        catalogEntryCount: Int = 0,
        rootAnchorCount: Int = 0
    ) {
        self.askSourceID = askSourceID
        self.pageIndexSourceID = pageIndexSourceID
        self.title = title
        self.rawRelpath = rawRelpath
        self.status = status
        self.detail = detail
        self.catalogEntryCount = catalogEntryCount
        self.rootAnchorCount = rootAnchorCount
    }
}

public struct ASKProjectionPageIndexBuildResult: Codable, Hashable, Sendable {
    public let projectionSlug: String
    public let knowledgeID: String
    public let entries: [ASKProjectionPageIndexBuildEntry]
    public let bindings: [ASKPageIndexSourceBinding]
    public let unboundASKSourceIDs: [String]
    public let backlinkAudit: BacklinkAuditReport

    public init(
        projectionSlug: String,
        knowledgeID: String,
        entries: [ASKProjectionPageIndexBuildEntry],
        bindings: [ASKPageIndexSourceBinding],
        unboundASKSourceIDs: [String],
        backlinkAudit: BacklinkAuditReport
    ) {
        self.projectionSlug = projectionSlug
        self.knowledgeID = knowledgeID
        self.entries = entries
        self.bindings = bindings
        self.unboundASKSourceIDs = unboundASKSourceIDs
        self.backlinkAudit = backlinkAudit
    }
}

public struct ASKProjectionPageIndexBuilder: Sendable {
    public init() {}

    @discardableResult
    public func build(
        slug: String,
        reader: any ASKKnowledgeReader,
        workspace: ASKKnowledgeWorkspacePaths,
        fileManager: FileManager = .default
    ) async throws -> ASKProjectionPageIndexBuildResult {
        guard let projection = try reader.projectionDocument(slug: slug) else {
            throw ASKKnowledgeWorkspaceError.projectionNotFound(slug)
        }
        return try await build(
            for: projection,
            knowledgeRoot: workspace.askRoot,
            workspace: workspace,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func build(
        for projection: ProjectionDocument,
        knowledgeRoot: URL,
        workspace: ASKKnowledgeWorkspacePaths,
        fileManager: FileManager = .default
    ) async throws -> ASKProjectionPageIndexBuildResult {
        try workspace.ensureDirectories(fileManager: fileManager)

        let pageIndex = try ASKPageIndexMacService(workspaceURL: workspace.pageIndexRoot)
        let bindingStore = ASKPageIndexSourceBindingStore(rootURL: workspace.pageIndexRoot)
        let knowledgeID = ASKProjectionPresentationManifest.makePageIndexKnowledgeID(forProjectionSlug: projection.slug)

        var entries: [ASKProjectionPageIndexBuildEntry] = []
        entries.reserveCapacity(projection.metadata.sourceIDs.count)

        var bindings: [ASKPageIndexSourceBinding] = []
        bindings.reserveCapacity(projection.metadata.sourceIDs.count)

        var anchors: [SourceAnchor] = []
        let sourceProcessor = ASKProjectionPageIndexSourceProcessor(
            knowledgeRoot: knowledgeRoot,
            pageIndex: pageIndex,
            fileManager: fileManager,
            sourceReceipts: try ASKRuntime(root: knowledgeRoot).sourceReceipts(sourceIDs: projection.metadata.sourceIDs)
        )

        for askSourceID in projection.metadata.sourceIDs {
            let output = await sourceProcessor.process(askSourceID: askSourceID)
            entries.append(output.entry)
            if let binding = output.binding {
                bindings.append(binding)
                anchors.append(contentsOf: output.anchors)
            }
        }

        try bindingStore.upsert(bindings, fileManager: fileManager)
        _ = try await pageIndex.attach(knowledgeID: knowledgeID, anchors: anchors)
        let backlinkAudit = try await pageIndex.auditBacklink(knowledgeID: knowledgeID)
        let unboundASKSourceIDs = entries
            .filter { $0.status != .indexed }
            .map(\.askSourceID)

        return ASKProjectionPageIndexBuildResult(
            projectionSlug: projection.slug,
            knowledgeID: knowledgeID,
            entries: entries,
            bindings: bindings.sorted { lhs, rhs in
                lhs.askSourceID < rhs.askSourceID
            },
            unboundASKSourceIDs: unboundASKSourceIDs,
            backlinkAudit: backlinkAudit
        )
    }

}
