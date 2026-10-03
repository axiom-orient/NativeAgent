import Foundation

/// Deterministic anchor validation and backlink auditing.
enum SourceAnchorResolver {
  static func resolve(
    anchor: SourceAnchor,
    in artifact: SourceIndexArtifact
  ) -> ResolvedSourceAnchor? {
    guard
      anchor.sourceVersionChecksum == artifact.version.checksum,
      let node = SourceIndexNavigator.node(
        forID: anchor.nodeID,
        in: artifact.document.rootNodes
      ),
      let sectionPath = SourceIndexNavigator.sectionPath(
        forID: anchor.nodeID,
        in: artifact.document.rootNodes
      ),
      node.range == anchor.range,
      sectionPath == anchor.sectionPath
    else {
      return nil
    }

    let excerpts = artifact.excerpts.filter { node.range.contains($0.index) }
    return ResolvedSourceAnchor(
      anchor: anchor,
      documentTitle: artifact.document.title,
      excerpts: excerpts
    )
  }

  static func audit(
    backlink: KnowledgeBacklink,
    artifacts: [SourceID: [SourceIndexArtifact]]
  ) -> BacklinkAuditReport {
    var resolved: [ResolvedSourceAnchor] = []
    var unresolved: [SourceAnchor] = []

    for anchor in backlink.anchors {
      guard
        let result = artifacts[anchor.sourceID]?.lazy.compactMap({ artifact in
          resolve(anchor: anchor, in: artifact)
        }).first
      else {
        unresolved.append(anchor)
        continue
      }
      resolved.append(result)
    }

    return BacklinkAuditReport(
      knowledgeID: backlink.knowledgeID,
      resolved: resolved,
      unresolved: unresolved
    )
  }
}
