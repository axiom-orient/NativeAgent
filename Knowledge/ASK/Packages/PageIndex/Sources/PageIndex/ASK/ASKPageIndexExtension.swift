import Foundation

public protocol ASKPageIndexReadServing: Sendable {
    func listSources() async throws -> [SourceIndexManifestEntry]
    func artifact(sourceID: SourceID) async throws -> SourceIndexArtifact?
    func resolve(anchor: SourceAnchor) async throws -> ResolvedSourceAnchor?
    func resolveBacklink(knowledgeID: String) async throws -> [ResolvedSourceAnchor]
    func auditBacklink(knowledgeID: String) async throws -> BacklinkAuditReport
    func retrieveEvidence(
        query: SourceEvidenceQuery,
        navigator: any VectorlessTreeNavigating
    ) async throws -> SourceEvidenceResult
}

public extension ASKPageIndexReadServing {
    func catalog(sourceID: SourceID) async throws -> [SourceCatalogEntry] {
        guard let artifact = try await artifact(sourceID: sourceID) else { return [] }
        return SourceIndexNavigator.catalogEntries(sourceID: sourceID, in: artifact)
    }

    func makeAnchor(sourceID: SourceID, nodeID: String) async throws -> SourceAnchor? {
        guard let artifact = try await artifact(sourceID: sourceID) else { return nil }
        return SourceIndexNavigator.makeAnchor(sourceID: sourceID, nodeID: nodeID, in: artifact)
    }
}

public protocol ASKPageIndexWriteServing: ASKPageIndexReadServing {
    @discardableResult
    func ingest(sourceAt url: URL) async throws -> SourceIndexManifestEntry
}

public extension ASKPageIndexWriteServing {
    @discardableResult
    func build(sourceAt url: URL) async throws -> SourceIndexManifestEntry {
        try await ingest(sourceAt: url)
    }

    @discardableResult
    func update(sourceAt url: URL) async throws -> SourceIndexManifestEntry {
        try await ingest(sourceAt: url)
    }
}

public actor ASKPageIndexExtension: ASKPageIndexWriteServing {
    private let builder: any SourceArtifactBuilding
    private let store: SourceIndexStore
    private let options: ASKPageIndexOptions

    public init(
        workspaceURL: URL,
        builder: any SourceArtifactBuilding = DefaultSourceArtifactBuilder(),
        configLoader: ConfigLoader? = nil,
        optionOverrides: ASKPageIndexOptionOverrides = ASKPageIndexOptionOverrides()
    ) throws {
        let resolvedConfigLoader = try configLoader ?? ConfigLoader()
        self.options = resolvedConfigLoader.load(overrides: optionOverrides)
        self.builder = builder
        self.store = try SourceIndexStore(workspaceURL: workspaceURL)
    }

    @discardableResult
    public func ingest(sourceAt url: URL) async throws -> SourceIndexManifestEntry {
        let artifact = try await builder.buildArtifact(from: url, options: options)
        return try await store.put(artifact)
    }

    public func listSources() async throws -> [SourceIndexManifestEntry] {
        try await store.list()
    }

    public func artifact(sourceID: SourceID) async throws -> SourceIndexArtifact? {
        try await store.get(sourceID: sourceID)
    }

    public func attach(knowledgeID: String, anchors: [SourceAnchor]) async throws -> KnowledgeBacklink {
        let uniqueAnchors = deduplicate(anchors)
        for anchor in uniqueAnchors {
            guard try await store.resolve(anchor: anchor) != nil else {
                throw ASKPageIndexError.unresolvedSourceAnchor(sourceID: anchor.sourceID.rawValue, nodeID: anchor.nodeID)
            }
        }
        let backlink = KnowledgeBacklink(knowledgeID: knowledgeID, anchors: uniqueAnchors)
        try await store.put(backlink: backlink)
        return backlink
    }

    public func resolve(anchor: SourceAnchor) async throws -> ResolvedSourceAnchor? {
        try await store.resolve(anchor: anchor)
    }

    public func resolveBacklink(knowledgeID: String) async throws -> [ResolvedSourceAnchor] {
        try await store.resolveBacklink(knowledgeID: knowledgeID)
    }

    public func auditBacklink(knowledgeID: String) async throws -> BacklinkAuditReport {
        try await store.auditBacklink(knowledgeID: knowledgeID)
    }

    public func retrieveEvidence(
        query: SourceEvidenceQuery,
        navigator: any VectorlessTreeNavigating = LexicalTreeNavigator()
    ) async throws -> SourceEvidenceResult {
        let artifacts = try await store.snapshot()
        return try await VectorlessTreeRAG(navigator: navigator).retrieve(query: query, artifacts: artifacts)
    }

    public func delete(sourceID: SourceID) async throws {
        try await store.delete(sourceID: sourceID)
    }

    private func deduplicate(_ anchors: [SourceAnchor]) -> [SourceAnchor] {
        var seen: Set<SourceAnchor> = []
        var result: [SourceAnchor] = []
        for anchor in anchors where !seen.contains(anchor) {
            seen.insert(anchor)
            result.append(anchor)
        }
        return result
    }
}
