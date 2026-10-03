import Foundation
import KnowledgeRuntime
import DocumentCore
import DocumentRuntime
import PageIndex

public struct ASKKnowledgeWorkspaceRuntime: Sendable {
    public let workspace: ASKKnowledgeWorkspacePaths
    public let knowledge: ASKRuntimeKnowledgeReader
    public let pageLoader: any ASKPageRuntimePackageLoader
    public let pageIndex: ASKPageIndexIOSService
    private let allowsReadMaterialization: Bool

    public init(
        workspace: ASKKnowledgeWorkspacePaths,
        pageLoader: any ASKPageRuntimePackageLoader = ASKPageFileSystemRuntimeLoader(),
        knowledgeRootURL: URL? = nil,
        allowsReadMaterialization: Bool = true,
        createsWorkspace: Bool = true
    ) throws {
        if createsWorkspace { try workspace.ensureDirectories() }
        let knowledgeRoot = knowledgeRootURL ?? workspace.askRoot
        self.workspace = workspace
        self.knowledge = ASKRuntimeKnowledgeReader(root: knowledgeRoot)
        self.pageLoader = pageLoader
        self.pageIndex = try ASKPageIndexIOSService(workspaceURL: workspace.pageIndexRoot)
        self.allowsReadMaterialization = allowsReadMaterialization
    }

    public func ensureKnowledgeBase() throws {
        try knowledge.ensureKnowledgeBase()
    }

    public func loadPresentationBundle(named bundleName: String) async throws -> ASKPageRuntimePackage {
        try await pageLoader.loadPackage(
            from: ASKPageDocumentLocation(rootURL: try workspace.presentationBundleRoot(named: bundleName))
        )
    }

    @discardableResult
    public func materializeProjectionPresentation(slug: String) throws -> ASKProjectionPresentationPackage {
        try workspace.ensureDirectories()
        return try ASKPresentationBuilder().materializeProjection(
            slug: slug,
            reader: knowledge,
            workspace: workspace
        )
    }

    public func loadProjectionPresentation(slug: String) throws -> ASKProjectionPresentationPackage {
        guard let projection = try knowledge.projectionDocument(slug: slug) else {
            throw ASKKnowledgeWorkspaceError.projectionNotFound(slug)
        }
        let bundleRoot = try workspace.presentationBundleRoot(named: slug)
        guard let manifest = try ASKProjectionPresentationBundleValidator().loadExistingManifest(
            bundleRoot: bundleRoot, fileManager: .default
        ) else {
            guard allowsReadMaterialization else {
                throw ASKKnowledgeWorkspaceError.presentationNotMaterialized(slug)
            }
            return try materializeProjectionPresentation(slug: slug)
        }
        guard manifest.generatedFromHash == projection.generatedFromHash else {
            guard allowsReadMaterialization else {
                throw ASKKnowledgeWorkspaceError.presentationNotMaterialized(slug)
            }
            return try materializeProjectionPresentation(slug: slug)
        }
        return ASKProjectionPresentationPackage(
            projection: projection, manifest: manifest, bundleRootURL: bundleRoot
        )
    }

    public func loadProjectionReadingContext(slug: String) async throws -> ASKProjectionReadingContext {
        let loaded = try await loadPresentationAndRuntimePackage(slug: slug)
        let bridge = ASKProjectionPageIndexBridge(pageIndex: pageIndex)
        return ASKProjectionReadingContext(
            presentation: loaded.presentation,
            runtimePackage: loaded.runtimePackage,
            sourceCatalogs: try await bridge.sourceCatalogs(for: loaded.presentation.manifest),
            backlinkAudit: try await bridge.backlinkAudit(for: loaded.presentation.manifest)
        )
    }

    public func loadProjectionReadingContext(from queryResult: QueryResult) async throws -> ASKProjectionReadingContext? {
        guard let slug = ASKProjectionPresentationSelector.selectProjectionSlug(from: queryResult) else { return nil }
        return try await loadProjectionReadingContext(slug: slug)
    }

    private func loadPresentationAndRuntimePackage(
        slug: String
    ) async throws -> (presentation: ASKProjectionPresentationPackage, runtimePackage: ASKPageRuntimePackage) {
        let presentation = try loadProjectionPresentation(slug: slug)
        do {
            return (presentation, try await pageLoader.loadPackage(from: presentation.location))
        } catch is ASKPageRuntimeError {
            guard allowsReadMaterialization else {
                throw ASKKnowledgeWorkspaceError.presentationNotMaterialized(slug)
            }
            let rematerialized = try materializeProjectionPresentation(slug: slug)
            return (rematerialized, try await pageLoader.loadPackage(from: rematerialized.location))
        }
    }
}
