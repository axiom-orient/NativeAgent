import Foundation
import KnowledgeRuntime
import DocumentCore
import DocumentRuntime
import EvidenceIndex
import PageIndex
import KnowledgePresentation

public struct ASKProductReadRuntime: Sendable {
    public let workspace: ASKProductWorkspacePaths
    public let knowledge: ASKRuntimeKnowledgeReader
    public let maintainer: ASKRuntimeKnowledgeMaintainer
    public let tutor: TutorKernel
    public let pageLoader: any ASKPageRuntimePackageLoader
    public let pageIndex: ASKPageIndexIOSService
    public let tutorInsightStore: TutorInsightCandidateStore
    public let tutorInsightAppliedStore: TutorInsightAppliedRecordStore
    private let presentationRuntime: ASKKnowledgeWorkspaceRuntime

    public init(
        workspace: ASKProductWorkspacePaths,
        configuration: TutorConfiguration = TutorConfiguration(),
        model: (any TutorModelClient)? = nil,
        store: (any TutorStore)? = nil,
        pageLoader: any ASKPageRuntimePackageLoader = ASKPageFileSystemRuntimeLoader(),
        knowledgeRootURL: URL? = nil,
        allowsReadMaterialization: Bool = true,
        createsWorkspace: Bool = true
    ) throws {
        if createsWorkspace { try workspace.ensureDirectories() }
        let knowledgeRoot = knowledgeRootURL ?? workspace.askRoot
        let knowledge = ASKRuntimeKnowledgeReader(root: knowledgeRoot)
        let maintainer = ASKRuntimeKnowledgeMaintainer(root: knowledgeRoot)
        let resolvedStore = store ?? JSONFileTutorStore(rootURL: workspace.tutorStoreRoot)
        let resolvedModel = model ?? TutorUnavailableModelClient()
        let presentationRuntime = try ASKKnowledgeWorkspaceRuntime(
            workspace: ASKKnowledgeWorkspacePaths(rootURL: workspace.rootURL),
            pageLoader: pageLoader,
            knowledgeRootURL: knowledgeRoot,
            allowsReadMaterialization: allowsReadMaterialization,
            createsWorkspace: createsWorkspace
        )
        self.workspace = workspace
        self.knowledge = knowledge
        self.maintainer = maintainer
        self.tutor = TutorKernel(
            knowledge: ASKTutorKnowledgeProvider(reader: knowledge),
            model: resolvedModel,
            store: resolvedStore,
            configuration: configuration
        )
        self.pageLoader = presentationRuntime.pageLoader
        self.pageIndex = presentationRuntime.pageIndex
        self.tutorInsightStore = TutorInsightCandidateStore(rootURL: workspace.pendingTutorInsightsRoot)
        self.tutorInsightAppliedStore = TutorInsightAppliedRecordStore(rootURL: workspace.appliedTutorInsightsRoot)
        self.presentationRuntime = presentationRuntime
    }

    public func ensureKnowledgeBase() throws { try knowledge.ensureKnowledgeBase() }

    public func loadPresentationBundle(named bundleName: String) async throws -> ASKPageRuntimePackage {
        try await mapPresentationError { try await presentationRuntime.loadPresentationBundle(named: bundleName) }
    }

    public func makeTutorInsightCapture() -> TutorInsightCapture {
        TutorInsightCapture(store: tutorInsightStore, knowledgeReader: knowledge)
    }

    public func makeKnowledgePipeline() throws -> ASKKnowledgePipeline {
        try ASKKnowledgePipeline(
            workspace: workspace,
            maintainer: maintainer,
            candidateStore: tutorInsightStore,
            appliedStore: tutorInsightAppliedStore,
            insightCapture: makeTutorInsightCapture()
        )
    }

    @discardableResult
    public func materializeProjectionPresentation(slug: String) throws -> ASKProjectionPresentationPackage {
        try mapPresentationError { try presentationRuntime.materializeProjectionPresentation(slug: slug) }
    }

    public func loadProjectionPresentation(slug: String) throws -> ASKProjectionPresentationPackage {
        try mapPresentationError { try presentationRuntime.loadProjectionPresentation(slug: slug) }
    }

    public func loadProjectionReadingContext(slug: String) async throws -> ASKProjectionReadingContext {
        try await mapPresentationError { try await presentationRuntime.loadProjectionReadingContext(slug: slug) }
    }

    public func loadProjectionReadingContext(from queryResult: QueryResult) async throws -> ASKProjectionReadingContext? {
        try await mapPresentationError { try await presentationRuntime.loadProjectionReadingContext(from: queryResult) }
    }

    public func loadProjectionReadingContext(from grounding: TutorGrounding) async throws -> ASKProjectionReadingContext? {
        guard let slug = ASKProjectionPresentationSelector.selectProjectionSlug(from: grounding) else { return nil }
        return try await loadProjectionReadingContext(slug: slug)
    }

    public func loadProjectionReadingContext(
        from reply: TutorReply,
        fallbackScope: TutorScope? = nil
    ) async throws -> ASKProjectionReadingContext? {
        guard let slug = ASKProjectionPresentationSelector.selectProjectionSlug(
            from: reply, fallbackScope: fallbackScope
        ) else { return nil }
        return try await loadProjectionReadingContext(slug: slug)
    }
}

private func mapPresentationError<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as ASKKnowledgeWorkspaceError { throw error.asProductError }
}

private func mapPresentationError<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let error as ASKKnowledgeWorkspaceError { throw error.asProductError }
}

private extension ASKKnowledgeWorkspaceError {
    var asProductError: ASKProductIntegrationError {
        switch self {
        case .invalidPresentationBundleName(let value): .invalidPresentationBundleName(value)
        case .invalidASKSourceID(let value): .invalidASKSourceID(value)
        case .projectionNotFound(let slug): .projectionNotFound(slug)
        case .presentationNotMaterialized(let slug): .presentationNotMaterialized(slug)
        case .failedToWritePresentationMarkdown(let slug): .failedToWritePresentationMarkdown(slug)
        case .failedToWritePresentationDocument(let slug): .failedToWritePresentationDocument(slug)
        case .failedToWritePresentationManifest(let slug): .failedToWritePresentationManifest(slug)
        }
    }
}
