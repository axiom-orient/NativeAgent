import Foundation

public actor ASKPageIndexMacService: ASKPageIndexWriteServing {
    private let extensionID: ASKPageIndexExtension

    public init(
        workspaceURL: URL,
        builder: any SourceArtifactBuilding = DefaultSourceArtifactBuilder(),
        configLoader: ConfigLoader? = nil,
        optionOverrides: ASKPageIndexOptionOverrides = ASKPageIndexOptionOverrides()
    ) throws {
        self.extensionID = try ASKPageIndexExtension(
            workspaceURL: workspaceURL,
            builder: builder,
            configLoader: configLoader,
            optionOverrides: optionOverrides
        )
    }

    @discardableResult
    public func ingest(sourceAt url: URL) async throws -> SourceIndexManifestEntry {
        try await extensionID.ingest(sourceAt: url)
    }

    public func listSources() async throws -> [SourceIndexManifestEntry] {
        try await extensionID.listSources()
    }

    public func artifact(sourceID: SourceID) async throws -> SourceIndexArtifact? {
        try await extensionID.artifact(sourceID: sourceID)
    }

    public func attach(knowledgeID: String, anchors: [SourceAnchor]) async throws -> KnowledgeBacklink {
        try await extensionID.attach(knowledgeID: knowledgeID, anchors: anchors)
    }

    public func resolve(anchor: SourceAnchor) async throws -> ResolvedSourceAnchor? {
        try await extensionID.resolve(anchor: anchor)
    }

    public func resolveBacklink(knowledgeID: String) async throws -> [ResolvedSourceAnchor] {
        try await extensionID.resolveBacklink(knowledgeID: knowledgeID)
    }

    public func auditBacklink(knowledgeID: String) async throws -> BacklinkAuditReport {
        try await extensionID.auditBacklink(knowledgeID: knowledgeID)
    }

    public func retrieveEvidence(
        query: SourceEvidenceQuery,
        navigator: any VectorlessTreeNavigating
    ) async throws -> SourceEvidenceResult {
        try await extensionID.retrieveEvidence(query: query, navigator: navigator)
    }

    public func delete(sourceID: SourceID) async throws {
        try await extensionID.delete(sourceID: sourceID)
    }
}

public actor ASKPageIndexIOSService: ASKPageIndexReadServing {
    private let store: SourceIndexStore

    public init(workspaceURL: URL) throws {
        self.store = try SourceIndexStore(workspaceURL: workspaceURL)
    }

    public func listSources() async throws -> [SourceIndexManifestEntry] {
        try await store.list()
    }

    public func artifact(sourceID: SourceID) async throws -> SourceIndexArtifact? {
        try await store.get(sourceID: sourceID)
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
        navigator: any VectorlessTreeNavigating
    ) async throws -> SourceEvidenceResult {
        let artifacts = try await store.snapshot()
        return try await VectorlessTreeRAG(navigator: navigator).retrieve(query: query, artifacts: artifacts)
    }
}
