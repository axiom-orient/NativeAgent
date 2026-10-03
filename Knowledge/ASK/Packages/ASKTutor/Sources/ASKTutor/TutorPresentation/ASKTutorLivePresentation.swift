import KnowledgePresentation
import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public enum ASKTutorLivePresentationResolverError: Error, Sendable, Equatable {
    case sessionNotProjectionScoped(sessionID: String)
}

public enum TutorEvidenceDrawerItemStatus: String, Codable, Sendable, Equatable {
    case bound
    case unbound
    case missingSourceReceipt
}

public struct TutorEvidenceDrawerItem: Sendable, Equatable {
    public let askSourceID: String
    public let title: String?
    public let rawRelpath: String?
    public let status: TutorEvidenceDrawerItemStatus
    public let pageIndexSourceID: SourceID?
    public let catalogEntries: [SourceCatalogEntry]
    public let resolvedAnchors: [ResolvedSourceAnchor]

    public init(
        askSourceID: String,
        title: String?,
        rawRelpath: String?,
        status: TutorEvidenceDrawerItemStatus,
        pageIndexSourceID: SourceID?,
        catalogEntries: [SourceCatalogEntry],
        resolvedAnchors: [ResolvedSourceAnchor]
    ) {
        self.askSourceID = askSourceID
        self.title = title
        self.rawRelpath = rawRelpath
        self.status = status
        self.pageIndexSourceID = pageIndexSourceID
        self.catalogEntries = catalogEntries
        self.resolvedAnchors = resolvedAnchors
    }
}

public struct TutorScopedProjectionPresentation: Sendable {
    public let sessionID: String
    public let turnID: String
    public let projectionSlug: String
    public let reply: TutorReply
    public let readingContext: ASKProjectionReadingContext
    public let evidence: [TutorEvidenceDrawerItem]

    public init(
        sessionID: String,
        turnID: String,
        projectionSlug: String,
        reply: TutorReply,
        readingContext: ASKProjectionReadingContext,
        evidence: [TutorEvidenceDrawerItem]
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.projectionSlug = projectionSlug
        self.reply = reply
        self.readingContext = readingContext
        self.evidence = evidence
    }
}

public struct ASKTutorLivePresentationResolver: Sendable {
    public init() {}

    public func resolve(
        reply: TutorReply,
        session: TutorSession,
        runtime: ASKProductReadRuntime,
        fileManager: FileManager = .default
    ) async throws -> TutorScopedProjectionPresentation {
        guard let projectionSlug = session.scope.projectionSlug else {
            throw ASKTutorLivePresentationResolverError.sessionNotProjectionScoped(sessionID: session.sessionID)
        }
        guard reply.sessionID == session.sessionID else {
            throw ASKProductIntegrationError.tutorSessionMismatch(expected: session.sessionID, actual: reply.sessionID)
        }

        let readingContext = try await runtime.loadProjectionReadingContext(slug: projectionSlug)
        let evidence = try resolveEvidence(
            from: readingContext,
            workspace: runtime.workspace,
            fileManager: fileManager
        )

        return TutorScopedProjectionPresentation(
            sessionID: session.sessionID,
            turnID: reply.turnID,
            projectionSlug: projectionSlug,
            reply: reply,
            readingContext: readingContext,
            evidence: evidence
        )
    }

    private func resolveEvidence(
        from context: ASKProjectionReadingContext,
        workspace: ASKProductWorkspacePaths,
        fileManager: FileManager
    ) throws -> [TutorEvidenceDrawerItem] {
        let catalogsByASKSourceID = Dictionary(
            uniqueKeysWithValues: context.sourceCatalogs.map { ($0.askSourceID, $0) }
        )
        let resolvedBySourceID = Dictionary(grouping: context.backlinkAudit.resolved, by: \ .anchor.sourceID)
        let bindingsByASKSourceID = Dictionary(
            uniqueKeysWithValues: context.presentation.manifest.pageIndexBindings.map { ($0.askSourceID, $0.pageIndexSourceID) }
        )

        return try context.presentation.manifest.sourceIDs.map { askSourceID in
            let receipt = try loadSourceReceipt(
                askSourceID: askSourceID,
                workspace: workspace,
                fileManager: fileManager
            )
            let pageIndexSourceID = bindingsByASKSourceID[askSourceID]
            let catalog = catalogsByASKSourceID[askSourceID]
            let resolvedAnchors = pageIndexSourceID.flatMap { resolvedBySourceID[$0] } ?? []

            let status: TutorEvidenceDrawerItemStatus
            if pageIndexSourceID != nil {
                status = .bound
            } else if receipt != nil {
                status = .unbound
            } else {
                status = .missingSourceReceipt
            }

            return TutorEvidenceDrawerItem(
                askSourceID: askSourceID,
                title: receipt?.title,
                rawRelpath: receipt?.rawRelpath,
                status: status,
                pageIndexSourceID: pageIndexSourceID,
                catalogEntries: catalog?.entries ?? [],
                resolvedAnchors: resolvedAnchors
            )
        }
    }

    /// Canonical receipts come from the runtime rather than from the vault's
    /// file layout, which the vault owns and regenerates.
    private func loadSourceReceipt(
        askSourceID: String,
        workspace: ASKProductWorkspacePaths,
        fileManager: FileManager
    ) throws -> SourceReceipt? {
        try ASKRuntime(root: workspace.askRoot).sourceReceipts(sourceIDs: [askSourceID])[askSourceID]
    }
}
