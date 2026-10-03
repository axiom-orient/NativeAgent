import Foundation

/// In-process serialization boundary for a filesystem-backed source index.
public actor SourceIndexStore {
  public nonisolated static let manifestFileName = SourceIndexWorkspace.manifestFileName

  private let workspace: SourceIndexWorkspace

  public init(workspaceURL: URL) throws {
    self.workspace = try SourceIndexWorkspace(workspaceURL: workspaceURL)
  }

  /// Restores an interrupted publication, if present. No new index is created.
  /// Returns whether a pending transaction was recovered. Safe to repeat.
  @discardableResult
  public func recoverPendingWrite() throws -> Bool {
    try workspace.recoverPendingWrite()
  }

  public func list() throws -> [SourceIndexManifestEntry] {
    try workspace.list()
  }

  public func snapshot() throws -> [SourceIndexArtifact] {
    try workspace.snapshot()
  }

  /// Attributes of the manifest file; every mutation rewrites it, so equal
  /// tokens imply the artifact set is unchanged since the last read.
  public func revisionToken() throws -> SourceIndexRevisionToken? {
    try workspace.revisionToken()
  }

  @discardableResult
  public func put(_ artifact: SourceIndexArtifact) throws -> SourceIndexManifestEntry {
    try workspace.put(artifact)
  }

  /// Recoverably publishes one batch. Interrupted writes block observations;
  /// an explicit recovery or subsequent write restores the previous state.
  public func put(_ artifacts: [SourceIndexArtifact]) throws -> [SourceIndexManifestEntry] {
    try workspace.put(artifacts)
  }

  public func get(sourceID: SourceID) throws -> SourceIndexArtifact? {
    try workspace.get(sourceID: sourceID)
  }

  /// Exact version lookup, including inactive sources. No current-version fallback.
  public func get(sourceID: SourceID, versionChecksum: String) throws -> SourceIndexArtifact? {
    if let current = try workspace.get(sourceID: sourceID), current.version.checksum == versionChecksum {
      return current
    }
    return try workspace.history(sourceID: sourceID).first { $0.version.checksum == versionChecksum }
  }

  /// Atomically replaces one source root's active membership, retaining historical evidence.
  /// Discovered but unsupported files retain their previous active entry.
  @discardableResult
  public func reconcile(
    _ artifacts: [SourceIndexArtifact], sourceRootURL: URL, discoveredSourceURLs: [URL]
  ) throws -> [SourceIndexManifestEntry] {
    try workspace.put(artifacts, sourceRootURL: sourceRootURL, discoveredSourceURLs: discoveredSourceURLs)
  }

  /// Immutable prior artifacts for a logical source, ordered by checksum.
  public func history(sourceID: SourceID) throws -> [SourceIndexArtifact] {
    try workspace.history(sourceID: sourceID)
  }

  public func retainedSourcePaths() throws -> [String] {
    try workspace.retainedSourcePaths()
  }

  public func delete(sourceID: SourceID) throws {
    try workspace.delete(sourceID: sourceID)
  }

  public func put(backlink: KnowledgeBacklink) throws {
    try workspace.put(backlink: backlink)
  }

  public func getBacklink(knowledgeID: String) throws -> KnowledgeBacklink? {
    try workspace.getBacklink(knowledgeID: knowledgeID)
  }

  public func resolve(anchor: SourceAnchor) throws -> ResolvedSourceAnchor? {
    let checksum = anchor.sourceVersionChecksum
    guard let artifact = try get(sourceID: anchor.sourceID, versionChecksum: checksum) else { return nil }
    return SourceAnchorResolver.resolve(anchor: anchor, in: artifact)
  }

  public func resolveBacklink(knowledgeID: String) throws -> [ResolvedSourceAnchor] {
    try auditBacklink(knowledgeID: knowledgeID).resolved
  }

  /// Resolves every stored backlink anchor against its checksum-bound current
  /// or retained historical source artifact.
  public func auditBacklink(knowledgeID: String) throws -> BacklinkAuditReport {
    guard let backlink = try workspace.getBacklink(knowledgeID: knowledgeID) else {
      return BacklinkAuditReport(
        knowledgeID: knowledgeID,
        resolved: [],
        unresolved: []
      )
    }

    var artifacts: [SourceID: [SourceIndexArtifact]] = [:]
    for sourceID in Set(backlink.anchors.map(\.sourceID)) {
      var versions = try workspace.history(sourceID: sourceID)
      if let artifact = try workspace.get(sourceID: sourceID) {
        versions.append(artifact)
      }
      if !versions.isEmpty {
        artifacts[sourceID] = versions
      }
    }
    return SourceAnchorResolver.audit(backlink: backlink, artifacts: artifacts)
  }
  /// Repairs app-owned file locators after a container move. Does not reindex,
  /// change source identity/version/root ownership, or create knowledge effects.
  @discardableResult
  public func relocateSourcePaths(
    _ replacements: [String: URL], allowedDestinationRoots: [URL]
  ) throws -> Int {
    try workspace.relocateSourcePaths(replacements, allowedDestinationRoots: allowedDestinationRoots)
  }

}
