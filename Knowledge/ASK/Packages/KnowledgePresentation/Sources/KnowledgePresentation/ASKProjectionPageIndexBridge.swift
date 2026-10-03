import Foundation
import DocumentCore
import DocumentRuntime
import PageIndex

public struct ASKProjectionSourceCatalog: Sendable, Hashable {
    public let askSourceID: String
    public let pageIndexSourceID: SourceID
    public let entries: [SourceCatalogEntry]

    public init(askSourceID: String, pageIndexSourceID: SourceID, entries: [SourceCatalogEntry]) {
        self.askSourceID = askSourceID
        self.pageIndexSourceID = pageIndexSourceID
        self.entries = entries
    }
}

public struct ASKProjectionReadingContext: Sendable {
    public let presentation: ASKProjectionPresentationPackage
    public let runtimePackage: ASKPageRuntimePackage
    public let sourceCatalogs: [ASKProjectionSourceCatalog]
    public let backlinkAudit: BacklinkAuditReport

    public init(
        presentation: ASKProjectionPresentationPackage,
        runtimePackage: ASKPageRuntimePackage,
        sourceCatalogs: [ASKProjectionSourceCatalog],
        backlinkAudit: BacklinkAuditReport
    ) {
        self.presentation = presentation
        self.runtimePackage = runtimePackage
        self.sourceCatalogs = sourceCatalogs
        self.backlinkAudit = backlinkAudit
    }

    public var catalogEntries: [SourceCatalogEntry] {
        sourceCatalogs.flatMap(\.entries)
    }

    public var unboundSourceIDs: [String] {
        presentation.manifest.unboundSourceIDs
    }
}

public struct ASKProjectionPageIndexBridge: Sendable {
    public let pageIndex: ASKPageIndexIOSService

    public init(pageIndex: ASKPageIndexIOSService) {
        self.pageIndex = pageIndex
    }

    public func sourceCatalogs(for manifest: ASKProjectionPresentationManifest) async throws -> [ASKProjectionSourceCatalog] {
        var catalogs: [ASKProjectionSourceCatalog] = []
        catalogs.reserveCapacity(manifest.pageIndexBindings.count)
        for binding in manifest.pageIndexBindings {
            let entries = try await pageIndex.catalog(sourceID: binding.pageIndexSourceID)
            catalogs.append(
                ASKProjectionSourceCatalog(
                    askSourceID: binding.askSourceID,
                    pageIndexSourceID: binding.pageIndexSourceID,
                    entries: entries
                )
            )
        }
        return catalogs
    }

    public func makeAnchor(for entry: SourceCatalogEntry) async throws -> SourceAnchor? {
        try await pageIndex.makeAnchor(sourceID: entry.sourceID, nodeID: entry.nodeID)
    }

    public func makeAnchor(
        forASKSourceID askSourceID: String,
        nodeID: String,
        manifest: ASKProjectionPresentationManifest
    ) async throws -> SourceAnchor? {
        guard let pageIndexSourceID = manifest.pageIndexSourceID(forASKSourceID: askSourceID) else {
            return nil
        }
        return try await pageIndex.makeAnchor(sourceID: pageIndexSourceID, nodeID: nodeID)
    }

    public func resolve(anchor: SourceAnchor) async throws -> ResolvedSourceAnchor? {
        try await pageIndex.resolve(anchor: anchor)
    }

    public func backlinkAudit(for manifest: ASKProjectionPresentationManifest) async throws -> BacklinkAuditReport {
        try await pageIndex.auditBacklink(knowledgeID: manifest.pageIndexKnowledgeID)
    }
}
