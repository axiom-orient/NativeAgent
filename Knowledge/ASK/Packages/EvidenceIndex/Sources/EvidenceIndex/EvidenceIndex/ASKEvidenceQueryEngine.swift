import Foundation
import PageIndex

struct ASKEvidenceSnapshot: Sendable {
  let artifact: SourceIndexArtifact
  let metadata: ASKEvidenceMetadata
  let freshness: ASKEvidenceFreshnessEvaluation
}

/// Deterministic filtering, ranking, and projection of already-loaded evidence snapshots.
enum ASKEvidenceQueryEngine {
  static func validate(_ query: ASKEvidenceQuery) throws {
    guard query.limit >= 0 else {
      throw ASKPageIndexError.invalidArguments("evidence query limit must be non-negative")
    }
    guard query.excerptLineLimit >= 0 else {
      throw ASKPageIndexError.invalidArguments(
        "evidence query excerptLineLimit must be non-negative"
      )
    }
  }

  static func documents(
    in snapshots: [ASKEvidenceSnapshot],
    filter: ASKEvidenceFilter
  ) -> [ASKEvidenceMetadata] {
    snapshots
      .filter { matches($0, filter: filter) }
      .map(\.metadata)
      .sorted { lhs, rhs in
        (lhs.sourcePath ?? lhs.documentTitle) < (rhs.sourcePath ?? rhs.documentTitle)
      }
  }

  static func search(
    _ query: ASKEvidenceQuery,
    in snapshots: [ASKEvidenceSnapshot]
  ) -> [ASKEvidenceHit] {
    Array(rankedHits(query, in: snapshots).prefix(query.limit))
  }

  /// Precomputed scoring input for one catalog entry. The haystack is folded
  /// once per artifact revision instead of once per query per entry; scoring
  /// then runs plain occurrence counting over the already-lowercased text.
  struct SearchRow {
    let snapshotIndex: Int
    let entry: SourceCatalogEntry
    /// Title/path/summary/metadata portion of the haystack (excerpt excluded).
    let foldedHeader: String
    /// Per-line folded excerpt contents for `entry.range`; display truncation
    /// stays query-dependent, so lines are stored individually.
    let foldedExcerptLines: [String]

    init(
      snapshotIndex: Int,
      entry: SourceCatalogEntry,
      artifact: SourceIndexArtifact,
      metadata: ASKEvidenceMetadata,
      excerptsByIndex: [Int: SourceExcerpt]
    ) {
      self.snapshotIndex = snapshotIndex
      self.entry = entry
      self.foldedHeader = [
        artifact.document.title,
        entry.title,
        entry.sectionPath.joined(separator: " / "),
        entry.summary ?? "",
        entry.snippet ?? "",
        metadata.topic ?? "",
        metadata.stage ?? "",
        metadata.tags.joined(separator: " "),
      ].joined(separator: "\n").lowercased().precomposedStringWithCanonicalMapping
      self.foldedExcerptLines = (entry.range.start...entry.range.end).compactMap { lineIndex in
        guard let excerpt = excerptsByIndex[lineIndex] else { return nil }
        return excerpt.content.lowercased().precomposedStringWithCanonicalMapping
      }
    }
  }

  static func rankedHits(
    _ query: ASKEvidenceQuery,
    in snapshots: [ASKEvidenceSnapshot],
    rows: [SearchRow],
    excerptLookups: [[Int: SourceExcerpt]]
  ) -> [ASKEvidenceHit] {
    let terms = normalizedTerms(query.text)
    var hits: [ASKEvidenceHit] = []

    for row in rows {
      let snapshot = snapshots[row.snapshotIndex]
      guard retrievalEligible(snapshot.artifact) else { continue }
      if !matches(snapshot, filter: query.filter) { continue }
      let artifact = snapshot.artifact
      let excerptsByIndex = excerptLookups[row.snapshotIndex]

      var haystackText = row.foldedHeader
      // Display size must never decide whether a value is searchable.
      if !row.foldedExcerptLines.isEmpty {
        let joined = row.foldedExcerptLines.joined(separator: "\n")
        if !joined.isEmpty { haystackText += "\n" + joined }
      }
      let score = scoreNeedleGroups(terms, in: haystackText)
      if !terms.isEmpty && score <= 0 { continue }
      let excerpt = excerptText(
        excerpts: (row.entry.range.start...row.entry.range.end).compactMap { excerptsByIndex[$0] },
        queryText: query.text,
        maxLines: query.excerptLineLimit
      )
      hits.append(
        ASKEvidenceHit(
          sourceID: artifact.document.sourceID,
          nodeID: row.entry.nodeID,
          title: row.entry.title,
          sectionPath: row.entry.sectionPath,
          range: row.entry.range,
          excerpt: excerpt,
          score: score,
          metadata: snapshot.metadata,
          freshness: snapshot.freshness.status,
          sourceVersionChecksum: artifact.version.checksum
        )
      )
    }

    return sortedHits(hits)
  }

  static func rankedHits(
    _ query: ASKEvidenceQuery,
    in snapshots: [ASKEvidenceSnapshot]
  ) -> [ASKEvidenceHit] {
    var rows: [SearchRow] = []
    rows.reserveCapacity(snapshots.count)
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
        rows.append(SearchRow(
          snapshotIndex: snapshotIndex,
          entry: entry,
          artifact: snapshot.artifact,
          metadata: snapshot.metadata,
          excerptsByIndex: lookups[snapshotIndex]
        ))
      }
    }
    return rankedHits(query, in: snapshots, rows: rows, excerptLookups: lookups)
  }

  static func status(for snapshot: ASKEvidenceSnapshot) -> ASKEvidenceDocumentStatus {
    ASKEvidenceDocumentStatus(
      sourceID: snapshot.artifact.document.sourceID,
      sourcePath: snapshot.artifact.sourcePath,
      freshness: snapshot.freshness.status,
      storedChecksum: snapshot.artifact.version.checksum,
      currentChecksum: snapshot.freshness.currentChecksum
    )
  }

  static func statuses(
    in snapshots: [ASKEvidenceSnapshot],
    filter: ASKEvidenceFilter
  ) -> [ASKEvidenceDocumentStatus] {
    snapshots
      .filter { matches($0, filter: filter) }
      .map(status)
  }

  private static func matches(
    _ snapshot: ASKEvidenceSnapshot,
    filter: ASKEvidenceFilter
  ) -> Bool {
    let metadata = snapshot.metadata
    let freshness = snapshot.freshness.status
    if !filter.scopes.isEmpty && !filter.scopes.contains(metadata.scope) { return false }
    if !filter.kinds.isEmpty && !filter.kinds.contains(metadata.kind) { return false }
    if !filter.sourceIDs.isEmpty && !filter.sourceIDs.contains(metadata.sourceID) { return false }
    if !filter.freshness.isEmpty && !filter.freshness.contains(freshness) { return false }
    if !filter.topics.isEmpty && !filter.topics.contains(metadata.topic ?? "") { return false }
    if !filter.stages.isEmpty && !filter.stages.contains(metadata.stage ?? "") { return false }
    if !filter.statuses.isEmpty && !filter.statuses.contains(metadata.status ?? "") { return false }
    return true
  }

  private static func retrievalEligible(_ artifact: SourceIndexArtifact) -> Bool {
    switch artifact.extractionQuality {
    case .ocrRequired, .unsupported:
      return false
    case .digitalText, .ocrApplied, .layoutUncertain:
      return true
    }
  }

  static func sortedHits(_ hits: [ASKEvidenceHit]) -> [ASKEvidenceHit] {
    hits.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.freshness != rhs.freshness {
        return freshnessRank(lhs.freshness) < freshnessRank(rhs.freshness)
      }
      let lhsPath = lhs.metadata.sourcePath ?? ""
      let rhsPath = rhs.metadata.sourcePath ?? ""
      if lhsPath != rhsPath { return lhsPath < rhsPath }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      if lhs.sourceID.rawValue != rhs.sourceID.rawValue {
        return lhs.sourceID.rawValue < rhs.sourceID.rawValue
      }
      if lhs.nodeID != rhs.nodeID { return lhs.nodeID < rhs.nodeID }
      if lhs.range.space != rhs.range.space {
        return lhs.range.space.rawValue < rhs.range.space.rawValue
      }
      if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
      if lhs.range.end != rhs.range.end { return lhs.range.end < rhs.range.end }
      if lhs.sectionPath != rhs.sectionPath {
        return lexicographicallyPrecedes(lhs.sectionPath, rhs.sectionPath)
      }
      return lhs.excerpt < rhs.excerpt
    }
  }

  private static func lexicographicallyPrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
    for (left, right) in zip(lhs, rhs) where left != right {
      return left < right
    }
    return lhs.count < rhs.count
  }

  private static func freshnessRank(_ freshness: ASKEvidenceFreshnessStatus) -> Int {
    switch freshness {
    case .ok: return 0
    case .unknown: return 1
    case .stale: return 2
    case .missing: return 3
    }
  }

  private static func normalizedTerms(_ text: String) -> [String] {
    let characters = Array(text.lowercased().precomposedStringWithCanonicalMapping)
    var terms: [String] = []
    var term = ""
    for index in characters.indices {
      let character = characters[index]
      // Keep numeric punctuation, so 17,000 / 17.5 are not reduced to 17.
      // This preserves spelling, not locale-dependent numeric conversion.
      let numericSeparator = (character == "," || character == ".")
        && index > 0 && index + 1 < characters.count
        && characters[index - 1].isNumber && characters[index + 1].isNumber
      if character.isLetter || character.isNumber || numericSeparator {
        term.append(character)
      } else if !term.isEmpty {
        terms.append(term)
        term = ""
      }
    }
    if !term.isEmpty { terms.append(term) }
    return terms
  }

  /// Occurrence counting over the pre-lowered, canonically composed haystack.
  /// `.literal` matching is equivalent to the previous locale-aware
  /// `range(of:)` loop because both sides share one canonical normalization,
  /// while skipping the canonical-comparison slow path.
  private static func scoreNeedleGroups(
    _ needles: [String],
    in haystack: String
  ) -> Double {
    if needles.isEmpty { return 1 }
    var score = 0.0
    for needle in needles {
      guard !needle.isEmpty else { continue }
      var count = 0
      var searchStart = haystack.startIndex
      while let range = haystack.range(
        of: needle,
        options: [.literal],
        range: searchStart..<haystack.endIndex
      ) {
        // A numeric value is not a match inside a different number (17 != 170).
        // Korean unit suffixes remain valid, e.g. 17원, as do dates/identifiers.
        let previous = range.lowerBound > haystack.startIndex ? haystack.index(before: range.lowerBound) : nil
        let next = range.upperBound < haystack.endIndex ? range.upperBound : nil
        let precededByNumber = previous.map { index in
          if haystack[index].isNumber { return true }
          guard haystack[index] == "," || haystack[index] == ".", index > haystack.startIndex else { return false }
          return haystack[haystack.index(before: index)].isNumber
        } ?? false
        let followedByNumber = next.map { index in
          if haystack[index].isNumber { return true }
          guard haystack[index] == "," || haystack[index] == "." else { return false }
          let following = haystack.index(after: index)
          return following < haystack.endIndex && haystack[following].isNumber
        } ?? false
        let startsInsideNumber = needle.first?.isNumber == true && precededByNumber
        let endsInsideNumber = needle.last?.isNumber == true && followedByNumber
        if !startsInsideNumber && !endsInsideNumber { count += 1 }
        if range.upperBound == haystack.endIndex { break }
        searchStart = range.upperBound
      }
      if count == 0 { return 0 }
      score += Double(count)
    }
    return score
  }

  /// Return an unchanged contiguous source window around the strongest matching
  /// line, including nearby qualifiers/units. The reference still addresses the
  /// full node; a presentation window never invents a narrower source identity.
  static func excerptText(
    excerpts: [SourceExcerpt],
    queryText: String,
    maxLines: Int
  ) -> String {
    let limit = max(0, maxLines)
    guard limit > 0 else { return "" }
    let lines = excerpts.sorted { $0.index < $1.index }.map(\.content)
    guard lines.count > limit else { return lines.joined(separator: "\n") }
    let terms = Array(Set(normalizedTerms(queryText))).sorted()
    var focus = 0
    var bestCoverage = 0
    for (index, line) in lines.enumerated() {
      let folded = line.lowercased().precomposedStringWithCanonicalMapping
      let coverage = terms.filter { scoreNeedleGroups([$0], in: folded) > 0 }.count
      if coverage > bestCoverage {
        bestCoverage = coverage
        focus = index
      }
    }
    let start = bestCoverage == 0 ? 0 : min(max(0, focus - min(2, limit / 2)), lines.count - limit)
    return lines[start..<min(lines.count, start + limit)].joined(separator: "\n")
  }
}
