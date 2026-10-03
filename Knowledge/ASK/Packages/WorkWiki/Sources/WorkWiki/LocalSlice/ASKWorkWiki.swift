import Foundation
import KnowledgeCore

public struct ASKWorkWikiConfiguration: Sendable {
    public var projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }
}

public struct ASKWorkWikiKernel: Sendable {
    public let configuration: ASKWorkWikiConfiguration

    public init(configuration: ASKWorkWikiConfiguration) {
        self.configuration = configuration
    }

    public init(projectRoot: URL) {
        self.init(configuration: ASKWorkWikiConfiguration(projectRoot: projectRoot))
    }

    public func resolve() -> ASKWorkWikiProjectResolution {
        ASKWorkWikiProjectRootPolicy(projectRoot: configuration.projectRoot).resolve()
    }

    public func refresh() throws -> ASKWorkWikiSnapshot {
        let project = resolve()
        let indexedDocuments = try ASKWorkWikiKnowledgeIndex.load(projectRoot: configuration.projectRoot)
        return ASKWorkWikiSnapshot(
            project: project,
            indexedDocuments: indexedDocuments,
            capabilities: ASKWorkWikiCapabilities.mobileLocalSlice
        )
    }
}

public struct ASKWorkWikiSnapshot: Sendable {
    public let project: ASKWorkWikiProjectResolution
    public let counts: ASKWorkWikiKnowledgeCounts
    public let documents: [ASKWorkWikiKnowledgeDocumentSummary]
    public let indexedPaths: [String]
    public let capabilities: [ASKWorkWikiCapability]

    package let indexedDocuments: [ASKWorkWikiIndexedDocument]

    package init(
        project: ASKWorkWikiProjectResolution,
        indexedDocuments: [ASKWorkWikiIndexedDocument],
        capabilities: [ASKWorkWikiCapability]
    ) {
        self.project = project
        self.counts = ASKWorkWikiKnowledgeIndex.counts(for: indexedDocuments)
        self.documents = indexedDocuments.map {
            ASKWorkWikiKnowledgeDocumentSummary(
                relativePath: $0.relativePath,
                category: $0.category,
                title: $0.title
            )
        }
        self.indexedPaths = indexedDocuments.map(\.relativePath)
        self.capabilities = capabilities
        self.indexedDocuments = indexedDocuments
    }

    public var knowledgeStatus: ASKWorkWikiKnowledgeStatus {
        ASKWorkWikiKnowledgeStatus(project: project, counts: counts, indexedPaths: indexedPaths)
    }

    public var status: ASKWorkWikiStatus {
        ASKWorkWikiStatus(project: project, knowledge: knowledgeStatus, capabilities: capabilities)
    }

    public func knowledgeDocument(relativePath: String) throws -> ASKWorkWikiKnowledgeDocument {
        guard let document = indexedDocuments.first(where: { $0.relativePath == relativePath }) else {
            throw ASKError.notFound("work-wiki knowledge document not found: \(relativePath)")
        }
        return ASKWorkWikiKnowledgeDocument(
            relativePath: document.relativePath,
            category: document.category,
            title: document.title,
            body: document.body
        )
    }

    public func knowledgeSearch(_ query: String, limit: Int = 100) throws -> ASKWorkWikiKnowledgeSearchResult {
        let hits = try ASKWorkWikiSearch.search(query: query, documents: indexedDocuments, limit: limit)
        return ASKWorkWikiKnowledgeSearchResult(project: project, query: query, hits: hits)
    }

    public func convergence() -> ASKWorkWikiConvergenceReport {
        ASKWorkWikiConvergence.build(project: project, documents: indexedDocuments)
    }
}

enum ASKWorkWikiCapabilities {
    static let mobileLocalSlice: [ASKWorkWikiCapability] = [
        ASKWorkWikiCapability(name: "knowledge index", support: .supported, reason: "Scans conventional work-wiki knowledge directories inside one local project root."),
        ASKWorkWikiCapability(name: "knowledge search", support: .supported, reason: "Searches indexed knowledge documents inside one refreshed local snapshot."),
        ASKWorkWikiCapability(name: "knowledge resolve", support: .supported, reason: "Resolves the current project from the provided local project root."),
        ASKWorkWikiCapability(name: "knowledge status", support: .supported, reason: "Reports indexed knowledge counts for conventional work-wiki directories."),
        ASKWorkWikiCapability(name: "convergence", support: .partial, reason: "Provides a local-only knowledge convergence view from conventional document paths. It does not include lower-layer code/topic linkage."),
        ASKWorkWikiCapability(name: "status", support: .partial, reason: "Reports knowledge-layer status only; diff, PTY, funnel chaos, and lower-layer signals are unavailable in the mobile-local slice."),
        ASKWorkWikiCapability(name: "search", support: .unsupported, reason: "Cross-layer search requires knowledge, code, git, and diff layers."),
        ASKWorkWikiCapability(name: "timeline", support: .unsupported, reason: "Temporal activity logs are not part of the mobile-local slice."),
        ASKWorkWikiCapability(name: "sessions", support: .unsupported, reason: "Session reconstruction requires temporal save history outside the mobile-local slice."),
        ASKWorkWikiCapability(name: "recent", support: .unsupported, reason: "Recent file activity requires a temporal layer outside the mobile-local slice."),
        ASKWorkWikiCapability(name: "diff", support: .unsupported, reason: "Diff history is not available in the mobile-local slice."),
        ASKWorkWikiCapability(name: "impact", support: .unsupported, reason: "Impact analysis requires code or diff graph support."),
        ASKWorkWikiCapability(name: "patterns", support: .unsupported, reason: "Pattern analysis requires temporal and lower-layer signals."),
        ASKWorkWikiCapability(name: "intent", support: .unsupported, reason: "Intent extraction requires session metadata not present in local knowledge documents."),
        ASKWorkWikiCapability(name: "knowledge link", support: .unsupported, reason: "Repo-to-project linking is not part of the mobile-local slice."),
        ASKWorkWikiCapability(name: "all-projects", support: .unsupported, reason: "Multi-project registry is not part of the mobile-local slice."),
        ASKWorkWikiCapability(name: "reindex", support: .partial, reason: "Refresh rescans the local knowledge layer only; there is no lower-layer cascade in the mobile-local slice.")
    ]
}
