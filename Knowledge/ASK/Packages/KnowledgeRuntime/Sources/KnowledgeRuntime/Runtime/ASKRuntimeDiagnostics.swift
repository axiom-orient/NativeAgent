import Foundation
import KnowledgeCore

/// Pure projection of pending review state into the public queue contract.
enum ASKRuntimeReviewQueueBuilder {
  static func build(from store: KnowledgeStore) -> ReviewQueueResult {
    let items = store.reviewItems.values
      .filter { $0.status == .pending }
      .sorted {
        switch ASKTimestamp.compare($0.createdAt, $1.createdAt) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return $0.reviewID < $1.reviewID
        }
      }
      .map { item in
        ReviewQueueItem(
          reviewID: item.reviewID,
          reviewKind: item.reviewKind.rawValue,
          severity: item.severity.rawValue,
          subjectKind: item.subjectKind,
          subjectID: item.subjectID,
          summary: item.summary,
          createdAt: item.createdAt,
          requiresChoice: item.requiresChoice,
          details: item.details,
          options: item.options.map { option in
            ReviewQueueOption(
              optionID: option.optionID,
              label: option.label,
              summary: option.summary,
              effect: option.effect,
              details: option.details
            )
          }
        )
      }

    return ReviewQueueResult(
      pendingCount: items.count,
      choiceRequiredCount: items.filter(\.requiresChoice).count,
      items: items
    )
  }
}

/// Deterministic lint evaluation over an already-loaded knowledge state.
enum ASKRuntimeLinter {
  static func lint(_ store: KnowledgeStore) -> LintResult {
    var findings: [LintFinding] = []

    let pendingReviews = store.reviewItems.values
      .filter { $0.status == .pending }
      .sorted { $0.reviewID < $1.reviewID }
    if !pendingReviews.isEmpty {
      findings.append(
        LintFinding(
          kind: "pending_review",
          severity: "high",
          count: pendingReviews.count,
          items: pendingReviews.map(\.reviewID)
        )
      )
    }

    let staleWithoutReplacement = store.projections.keys.sorted().filter { slug in
      store.projections[slug]?.last?.state == .stale
    }
    if !staleWithoutReplacement.isEmpty {
      findings.append(
        LintFinding(
          kind: "stale_projection",
          severity: "medium",
          count: staleWithoutReplacement.count,
          items: staleWithoutReplacement
        )
      )
    }

    let visibleWrites = store.visibleProjectionWrites()
    let graph = ProjectionLinkGraph(writes: visibleWrites)

    let brokenLinks = graph.edges
      .filter { !graph.visibleSlugs.contains($0.toSlug) }
      .map { "\($0.fromSlug) -> \($0.toSlug)" }
    if !brokenLinks.isEmpty {
      findings.append(
        LintFinding(
          kind: "broken_link",
          severity: "high",
          count: brokenLinks.count,
          items: brokenLinks.sorted()
        )
      )
    }

    let orphanPages = visibleWrites.filter { write in
      let metadata = write.document.metadata
      return metadata.sourceIDs.isEmpty
        && metadata.authorityIDs.isEmpty
        && metadata.claimIDs.isEmpty
    }.map(\.slug)
    if !orphanPages.isEmpty {
      findings.append(
        LintFinding(
          kind: "orphan_projection",
          severity: "medium",
          count: orphanPages.count,
          items: orphanPages.sorted()
        )
      )
    }

    let duplicateEntities = Dictionary(
      grouping: visibleWrites.filter {
        $0.document.metadata.projectionKind == .entityOverview
      }
    ) {
      "\($0.document.metadata.subjectKind)::\($0.document.metadata.subjectID)"
    }.filter { $0.value.count > 1 }
    if !duplicateEntities.isEmpty {
      let items = duplicateEntities.keys.sorted().map { key in
        let slugs = duplicateEntities[key, default: []]
          .map(\.slug)
          .sorted()
          .joined(separator: ",")
        return "\(key) => \(slugs)"
      }
      findings.append(
        LintFinding(
          kind: "duplicate_entity_projection",
          severity: "medium",
          count: items.count,
          items: items
        )
      )
    }

    let staleCurrentSnapshots = visibleWrites.filter { write in
      write.document.metadata.projectionKind == .currentSnapshot
        && currentProjectionNeedsRefresh(write: write, store: store)
    }.map(\.slug)
    if !staleCurrentSnapshots.isEmpty {
      findings.append(
        LintFinding(
          kind: "stale_current_snapshot",
          severity: "medium",
          count: staleCurrentSnapshots.count,
          items: staleCurrentSnapshots.sorted()
        )
      )
    }

    let playbookMissingApproval = visibleWrites.filter { write in
      write.document.metadata.projectionSpace == .playbook
        && !write.document.metadata.approvalRequired
    }.map(\.slug)
    if !playbookMissingApproval.isEmpty {
      findings.append(
        LintFinding(
          kind: "playbook_missing_approval",
          severity: "high",
          count: playbookMissingApproval.count,
          items: playbookMissingApproval.sorted()
        )
      )
    }

    return LintResult(findingCount: findings.count, findings: findings)
  }

  private struct ProjectionLinkGraph {
    let visibleSlugs: Set<String>
    let edges: [PageLinkRow]

    init(writes: [ProjectionWrite]) {
      visibleSlugs = Set(writes.map { normalizeProjectionSlugPath($0.slug) })
      edges = writes.flatMap { write in
        extractWikiLinkRows(
          from: write.document.bodyMD,
          fromSlug: normalizeProjectionSlugPath(write.slug),
          createdAt: write.document.generatedAt
        )
      }
    }
  }

  private static func currentProjectionNeedsRefresh(
    write: ProjectionWrite,
    store: KnowledgeStore
  ) -> Bool {
    guard let generatedAt = ASKTimestamp.parse(write.document.generatedAt) else { return false }
    let newestSource: Date? = write.document.metadata.sourceIDs.compactMap { sourceID in
      store.sources[sourceID].flatMap { ASKTimestamp.parse($0.observedAt) }
    }.max()
    let newestAuthority: Date? = write.document.metadata.authorityIDs.compactMap { authorityID in
      guard let record = store.authorityRecords[authorityID] else { return nil }
      return ASKTimestamp.parse(record.effectiveTo ?? record.effectiveFrom)
    }.max()
    guard let newestDependency = [newestSource, newestAuthority].compactMap({ $0 }).max()
    else { return false }
    return newestDependency > generatedAt
  }
}
