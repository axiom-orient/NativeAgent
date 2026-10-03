import Foundation
import PageIndex

/// Public concurrency boundary around a mutable source index workspace.
///
/// The actor memoizes decoded artifacts between manifest revisions. Freshness
/// is evaluated from current source bytes on every query so an external edit
/// cannot reuse a stale mtime/size verdict.
public actor ASKEvidenceIndex {
  private let store: SourceIndexStore
  private let freshnessInspector = ASKEvidenceFreshnessInspector()
  private var artifactCache: (token: SourceIndexRevisionToken?, artifacts: [SourceIndexArtifact])?
  private var searchRowCache: (
    token: SourceIndexRevisionToken?,
    rows: [ASKEvidenceQueryEngine.SearchRow],
    excerptLookups: [[Int: SourceExcerpt]]
  )?

  public init(workspaceURL: URL) throws {
    self.store = try SourceIndexStore(workspaceURL: workspaceURL)
  }

  public init(store: SourceIndexStore) {
    self.store = store
    self.artifactCache = (token: nil, artifacts: [])
  }

  /// Returns the shared long-lived handle for this workspace so repeated
  /// queries reuse one actor and its caches. Handles are bounded FIFO; an
  /// evicted workspace simply rebuilds its handle on the next open.
  public static func open(workspaceURL: URL) async throws -> ASKEvidenceIndex {
    let canonicalURL = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    return try await EvidenceHandlePool.shared.index(at: canonicalURL) {
      try ASKEvidenceIndex(workspaceURL: canonicalURL)
    }
  }

  public func listDocuments(
    filter: ASKEvidenceFilter = .none
  ) async throws -> [ASKEvidenceMetadata] {
    ASKEvidenceQueryEngine.documents(
      in: try await snapshots(),
      filter: filter
    )
  }

  public func search(_ query: ASKEvidenceQuery) async throws -> [ASKEvidenceHit] {
    try ASKEvidenceQueryEngine.validate(query)
    let state = try await preparedState()
    return Array(ASKEvidenceQueryEngine.rankedHits(
      query,
      in: state.snapshots,
      rows: state.rows,
      excerptLookups: state.excerptLookups
    ).prefix(query.limit))
  }

  public func buildPack(_ request: ASKEvidencePackRequest) async throws -> ASKEvidencePack {
    try ASKEvidenceQueryEngine.validate(request.query)
    guard request.maxBytes >= 0 else {
      throw ASKPageIndexError.invalidArguments("evidence pack maxBytes must be non-negative")
    }

    let state = try await preparedState()
    let allHits = ASKEvidenceQueryEngine.rankedHits(
      request.query,
      in: state.snapshots,
      rows: state.rows,
      excerptLookups: state.excerptLookups
    )
    let eligibleHits =
      request.includeStale
      ? allHits
      : allHits.filter { $0.freshness == .ok || $0.freshness == .unknown }
    return ASKEvidencePackRenderer.render(
      queryText: request.query.text,
      hits: Array(eligibleHits.prefix(request.query.limit)),
      maxBytes: request.maxBytes
    )
  }

  /// Exact resolution is read-only and never substitutes the active version.
  /// A source freshness requirement is checked separately from indexed integrity.
  public func resolve(
    _ reference: ASKEvidenceReference,
    freshnessRequirement: ASKEvidenceFreshnessRequirement = .currentSource
  ) async throws -> ASKEvidenceResolution {
    try Task.checkCancellation()
    guard let artifact = try await store.get(
      sourceID: reference.sourceID, versionChecksum: reference.sourceVersionChecksum
    ) else { return .unavailable(.versionMissing) }
    try Task.checkCancellation()
    guard artifact.extractionQuality != .unsupported, artifact.extractionQuality != .ocrRequired else {
      return .unavailable(.extractionUnavailable)
    }
    guard let excerpts = ASKEvidenceGrounding.excerpts(
      nodeID: reference.nodeID, range: reference.range, in: artifact
    ) else { return .unavailable(.rangeUnavailable) }
    guard ASKEvidenceGrounding.digest(excerpts) == reference.contentSHA256 else {
      return .unavailable(.digestMismatch)
    }
    let freshness = try freshnessInspector.evaluate(artifact).status
    if let reason = ASKEvidenceGrounding.rejection(for: freshness, requirement: freshnessRequirement) {
      return .unavailable(reason)
    }
    try Task.checkCancellation()
    return .available(ASKEvidenceContent(
      reference: reference, excerpts: excerpts, sourceFreshness: freshness
    ))
  }

  /// Broad search remains unchanged. This separate path admits only exact,
  /// resolvable references; unknown original freshness is rejected by default.
  public func buildGroundedPack(
    _ query: ASKEvidenceQuery,
    maxBytes: Int = ASKEvidencePackRequest.defaultMaxBytes,
    freshnessRequirement: ASKEvidenceFreshnessRequirement = .currentSource
  ) async throws -> ASKEvidenceGroundedPack {
    try ASKEvidenceQueryEngine.validate(query)
    guard maxBytes >= 0 else {
      throw ASKPageIndexError.invalidArguments("evidence pack maxBytes must be non-negative")
    }
    let state = try await preparedState()
    let candidates = ASKEvidenceQueryEngine.rankedHits(
      query,
      in: state.snapshots,
      rows: state.rows,
      excerptLookups: state.excerptLookups
    )
    var admitted: [ASKEvidenceGroundedHit] = []
    var rejected: [ASKEvidenceRejection] = []
    for hit in candidates {
      // `query.limit` is the number of grounded results requested, not the
      // number of pre-validation candidates. Keep scanning past stale or
      // otherwise invalid candidates until the requested grounded count is met.
      if admitted.count >= query.limit { break }
      try Task.checkCancellation()
      // Re-read the exact revision after the actor suspension. A search cache
      // or concurrent reindex cannot replace it with a newer source revision.
      guard let checksum = hit.sourceVersionChecksum,
            let artifact = try await store.get(sourceID: hit.sourceID, versionChecksum: checksum) else {
        rejected.append(.init(sourceID: hit.sourceID, nodeID: hit.nodeID,
                              sourceVersionChecksum: hit.sourceVersionChecksum, reason: .versionMissing))
        continue
      }
      guard artifact.extractionQuality != .unsupported, artifact.extractionQuality != .ocrRequired else {
        rejected.append(.init(sourceID: hit.sourceID, nodeID: hit.nodeID,
                              sourceVersionChecksum: checksum, reason: .extractionUnavailable))
        continue
      }
      guard let excerpts = ASKEvidenceGrounding.excerpts(nodeID: hit.nodeID, range: hit.range, in: artifact) else {
        rejected.append(.init(sourceID: hit.sourceID, nodeID: hit.nodeID,
                              sourceVersionChecksum: checksum, reason: .rangeUnavailable))
        continue
      }
      let freshness = try freshnessInspector.evaluate(artifact).status
      if let reason = ASKEvidenceGrounding.rejection(for: freshness, requirement: freshnessRequirement) {
        rejected.append(.init(sourceID: hit.sourceID, nodeID: hit.nodeID,
                              sourceVersionChecksum: checksum, reason: reason))
        continue
      }
      let reference = try ASKEvidenceReference(
        sourceID: hit.sourceID, sourceVersionChecksum: checksum, nodeID: hit.nodeID,
        range: hit.range, contentSHA256: ASKEvidenceGrounding.digest(excerpts)
      )
      var view = hit
      view.freshness = freshness
      // The view must come from the same exact artifact as its reference, not
      // from an earlier cached row that survived an actor suspension.
      view.excerpt = ASKEvidenceQueryEngine.excerptText(
        excerpts: excerpts, queryText: query.text, maxLines: query.excerptLineLimit
      )
      admitted.append(.init(hit: view, reference: reference))
    }
    try Task.checkCancellation()
    let rendered = ASKEvidencePackRenderer.render(
      queryText: query.text, hits: admitted.map(\.hit), maxBytes: maxBytes
    )
    return ASKEvidenceGroundedPack(
      queryText: query.text, evidence: Array(admitted.prefix(rendered.hits.count)), rejected: rejected,
      renderedMarkdown: rendered.renderedMarkdown, maxBytes: rendered.maxBytes, truncated: rendered.truncated
    )
  }

  public func freshness(sourceID: SourceID) async throws -> ASKEvidenceDocumentStatus? {
    guard let artifact = try await store.get(sourceID: sourceID) else { return nil }
    return ASKEvidenceQueryEngine.status(for: try snapshot(for: artifact))
  }

  public func freshnessReport(
    filter: ASKEvidenceFilter = .none
  ) async throws -> [ASKEvidenceDocumentStatus] {
    ASKEvidenceQueryEngine.statuses(
      in: try await snapshots(),
      filter: filter
    )
  }

  private func snapshots() async throws -> [ASKEvidenceSnapshot] {
    let token = try await store.revisionToken()
    if artifactCache?.token != token {
      let artifacts = try await store.snapshot()
      artifactCache = (token: token, artifacts: artifacts)
      searchRowCache = nil
    }
    return try (artifactCache?.artifacts ?? []).map(snapshot(for:))
  }

  /// Materializes artifacts, freshness verdicts, and precomputed search rows
  /// under one revision check; unchanged workspaces reuse decoded artifacts
  /// and rows. Current source bytes are still read to evaluate freshness.
  private func preparedState() async throws -> (
    snapshots: [ASKEvidenceSnapshot],
    rows: [ASKEvidenceQueryEngine.SearchRow],
    excerptLookups: [[Int: SourceExcerpt]]
  ) {
    let token = try await store.revisionToken()
    if artifactCache?.token != token {
      let artifacts = try await store.snapshot()
      artifactCache = (token: token, artifacts: artifacts)
      searchRowCache = nil
    }
    let snapshots = try (artifactCache?.artifacts ?? []).map(snapshot(for:))
    if searchRowCache?.token != token {
      var rows: [ASKEvidenceQueryEngine.SearchRow] = []
      rows.reserveCapacity(snapshots.count * 4)
      let lookups: [[Int: SourceExcerpt]] = snapshots.map { snapshot in
        snapshot.artifact.excerpts.reduce(into: [Int: SourceExcerpt]()) {
          lookup, excerpt in
          lookup[excerpt.index] = excerpt
        }
      }
      for (snapshotIndex, snapshot) in snapshots.enumerated() {
        for entry in SourceIndexNavigator.catalogEntries(
          sourceID: snapshot.artifact.document.sourceID,
          in: snapshot.artifact
        ) {
          rows.append(ASKEvidenceQueryEngine.SearchRow(
            snapshotIndex: snapshotIndex,
            entry: entry,
            artifact: snapshot.artifact,
            metadata: snapshot.metadata,
            excerptsByIndex: lookups[snapshotIndex]
          ))
        }
      }
      searchRowCache = (token: token, rows: rows, excerptLookups: lookups)
    }
    return (
      snapshots,
      searchRowCache?.rows ?? [],
      searchRowCache?.excerptLookups ?? []
    )
  }

  private func snapshot(for artifact: SourceIndexArtifact) throws -> ASKEvidenceSnapshot {
    ASKEvidenceSnapshot(
      artifact: artifact,
      metadata: try ASKEvidenceMetadataExtractor.metadata(for: artifact),
      freshness: try freshnessInspector.evaluate(artifact)
    )
  }
}

private actor EvidenceHandlePool {
  static let shared = EvidenceHandlePool()

  private var handles: [URL: ASKEvidenceIndex] = [:]
  private var order: [URL] = []

  func index(
    at canonicalURL: URL,
    make: @Sendable () throws -> ASKEvidenceIndex
  ) throws -> ASKEvidenceIndex {
    if let existing = handles[canonicalURL] { return existing }
    let created = try make()
    handles[canonicalURL] = created
    order.append(canonicalURL)
    while order.count > 16 {
      handles[order.removeFirst()] = nil
    }
    return created
  }
}
