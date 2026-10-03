import EvidenceIndex
import PageIndex
import Foundation

/// Why an evidence pack came back empty.
///
/// `buildPack` collapses three independent failures into one empty pack: the
/// query matched nothing, every match was filtered out as stale or missing, or
/// the byte budget was too small to render even the first hit. Reporting all
/// three as "no fresh evidence" tells the caller the wrong thing to fix, so the
/// failure path re-inspects the index and names the actual cause.
enum ASKWorkWikiEvidenceDiagnosis {
  /// Builds the error for an empty pack produced by `query`.
  ///
  /// Only runs on the failure path, so the extra index read costs nothing in the
  /// success case.
  static func emptyPackError(
    operation: String,
    query: ASKEvidenceQuery,
    request: (maxEvidenceBytes: Int, includeStale: Bool),
    evidenceIndex: ASKEvidenceIndex
  ) async -> ASKWorkWikiError {
    let matched: [ASKEvidenceHit]
    do {
      matched = try await evidenceIndex.search(query)
    } catch {
      return ASKWorkWikiError(
        .noFreshEvidence,
        "work-wiki \(operation) requires at least one fresh evidence hit",
        context: ["query": query.text, "diagnosis_failed": String(describing: error)]
      )
    }

    var context = [
      "query": query.text,
      "matched_hits": String(matched.count),
      "max_evidence_bytes": String(request.maxEvidenceBytes),
      "include_stale_evidence": String(request.includeStale),
    ]

    guard !matched.isEmpty else {
      return ASKWorkWikiError(
        .noFreshEvidence,
        "work-wiki \(operation) found no indexed evidence matching the query; index the sources or widen the query",
        context: context
      )
    }

    let usable = request.includeStale
      ? matched
      : matched.filter { $0.freshness == .ok || $0.freshness == .unknown }
    context["usable_hits"] = String(usable.count)

    guard !usable.isEmpty else {
      let breakdown = Dictionary(grouping: matched, by: { $0.freshness.rawValue })
        .map { "\($0.key)=\($0.value.count)" }
        .sorted()
        .joined(separator: ",")
      context["freshness"] = breakdown
      return ASKWorkWikiError(
        .staleIndexedEvidence,
        "work-wiki \(operation) matched \(matched.count) evidence hit(s) but every source is stale or missing; re-index the sources or set includeStaleEvidence",
        context: context
      )
    }

    return ASKWorkWikiError(
      .evidenceBudgetTooSmall,
      "work-wiki \(operation) matched \(usable.count) fresh evidence hit(s) but maxEvidenceBytes=\(request.maxEvidenceBytes) is too small to include any of them",
      context: context
    )
  }
}
