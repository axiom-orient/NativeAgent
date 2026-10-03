import Foundation
import KnowledgeCore

private let guidanceKeywords = ["should", "optimize", "guidance", "practice", "design", "structure", "structured", "build", "built"]
private let currentKeywords = ["current", "version", "versions", "latest", "release"]
private let sourceKeywords = ["mention", "mentions", "permission", "example", "examples", "document", "documentation", "source", "page"]

package func queryItemOverlap(question: String, item: SearchHitSummary) -> Int {
    let questionTokens = queryTokens(question)
    guard !questionTokens.isEmpty else { return 0 }
    let parts = [
        item.title,
        item.projectionSlug ?? "",
        item.subjectKind,
        item.subjectID,
        item.metadata["projection_kind"] ?? "",
        item.metadata["projection_space"] ?? "",
        item.snippet,
    ]
    let itemTokens = queryTokens(parts.joined(separator: " "))
    return questionTokens.intersection(itemTokens).count
}

package func isCurrentProjection(_ item: SearchHitSummary) -> Bool {
    guard item.docKind == "projection" else { return false }
    let projectionKind = item.metadata["projection_kind"] ?? ""
    let slug = item.projectionSlug ?? ""
    return ["entity_overview", "current_snapshot"].contains(projectionKind) || slug.hasPrefix("current/")
}

package func isPlaybookProjection(_ item: SearchHitSummary) -> Bool {
    guard item.docKind == "projection" else { return false }
    return item.metadata["projection_kind"] == "playbook_entry"
}

package func isSourceDoc(_ item: SearchHitSummary) -> Bool {
    item.docKind == "source"
}

package func hasQueryPreference(question: String, item: SearchHitSummary) -> Bool {
    let lower = question.lowercased()
    if guidanceKeywords.contains(where: { lower.contains($0) }) && isPlaybookProjection(item) { return true }
    if currentKeywords.contains(where: { lower.contains($0) }) && isCurrentProjection(item) { return true }
    if sourceKeywords.contains(where: { lower.contains($0) }) && isSourceDoc(item) { return true }
    return false
}

private let sourceGroundingKeywords = sourceKeywords + ["crawl", "website", "web"]

package func wantsSourceGrounding(_ question: String) -> Bool {
    let lower = question.lowercased()
    return sourceGroundingKeywords.contains { lower.contains($0) }
}

package func queryPreferenceKey(question: String, item: SearchHitSummary) -> (Int, Int, Int, Int, Int, Double) {
    let projectionPriority = [
        "playbook_entry": 3,
        "entity_overview": 2,
        "current_snapshot": 2,
        "topic_overview": 2,
        "source_summary": 1,
    ][item.metadata["projection_kind"] ?? ""] ?? 0
    let overlap = queryItemOverlap(question: question, item: item)
    let currentMatch = isCurrentProjection(item) ? 1 : 0
    let playbookMatch = isPlaybookProjection(item) ? 1 : 0
    let sourceMatch = isSourceDoc(item) ? 1 : 0
    return (overlap, currentMatch, playbookMatch, projectionPriority, sourceMatch, item.score)
}

package func sameRelevanceBand(question: String, anchor: SearchHitSummary, candidate: SearchHitSummary) -> Bool {
    let anchorOverlap = queryItemOverlap(question: question, item: anchor)
    let candidateOverlap = queryItemOverlap(question: question, item: candidate)
    if candidateOverlap <= 0 || candidateOverlap < anchorOverlap { return false }
    let anchorScore = anchor.score
    if anchorScore <= 0 { return true }
    return candidate.score >= max(1.0, anchorScore * 0.7)
}

package func selectAnswerHits(question: String, preferredHits: [SearchHitSummary]) -> [SearchHitSummary] {
    let lower = question.lowercased()
    let wantsCurrent = currentKeywords.contains(where: { lower.contains($0) })
    let wantsGuidance = guidanceKeywords.contains(where: { lower.contains($0) })
    let wantsSource = wantsSourceGrounding(question)

    var selected: [SearchHitSummary] = []
    var seen = Set<String>()
    var seenSourceSubjects = Set<String>()

    func addFirst(_ predicate: (SearchHitSummary) -> Bool) {
        for item in preferredHits {
            let slug = item.projectionSlug ?? item.docID
            if seen.contains(slug) { continue }
            if predicate(item) {
                selected.append(item)
                seen.insert(slug)
                return
            }
        }
    }

    if wantsGuidance { addFirst(isPlaybookProjection) }
    if wantsCurrent { addFirst(isCurrentProjection) }
    if wantsSource { addFirst(isSourceDoc) }

    for item in preferredHits {
        let slug = item.projectionSlug ?? item.docID
        if seen.contains(slug) { continue }
        let sourceSubject = item.subjectKind == "source" ? item.subjectID : nil
        if item.docKind == "claim", seenSourceSubjects.contains(item.subjectID) {
            continue
        }
        if let anchor = selected.first, !hasQueryPreference(question: question, item: item),
           !sameRelevanceBand(question: question, anchor: anchor, candidate: item) {
            continue
        }
        selected.append(item)
        seen.insert(slug)
        if let sourceSubject {
            seenSourceSubjects.insert(sourceSubject)
        }
        if selected.count >= 3 { break }
    }

    return Array(selected.prefix(3))
}

package func preferredHitsForQuery(_ hits: [SearchHitSummary]) -> [SearchHitSummary] {
    func notQueryArtifact(_ item: SearchHitSummary) -> Bool {
        item.metadata["projection_kind"] != "query_artifact"
            && !(item.projectionSlug?.hasPrefix("query/") ?? false)
    }
    var preferredHits = hits.filter { $0.docKind == "projection" && notQueryArtifact($0) }
    if preferredHits.isEmpty { preferredHits = hits.filter(notQueryArtifact) }
    if preferredHits.isEmpty { preferredHits = hits }
    return preferredHits
}

package func buildDebugQuerySelection(root: String, question: String) throws -> DebugQuerySelection {
    let hits = try searchMirrorFirst(root: root, query: question, limit: 12)
    let selectedHits = chooseQueryAnswerHits(question: question, hits: hits)

    let failureKind: String?
    if hits.isEmpty {
        failureKind = "no_search_hits"
    } else if selectedHits.selected.isEmpty {
        failureKind = "search_hits_but_no_selected_answer"
    } else {
        failureKind = nil
    }

    return DebugQuerySelection(
        searchHitCount: hits.count,
        preferredHitCount: selectedHits.preferred.count,
        selectedHitCount: selectedHits.selected.count,
        failureKind: failureKind,
        selectedHits: selectedHits.selected
    )
}

package struct QueryHitSelection: Sendable {
    package let preferred: [SearchHitSummary]
    package let selected: [SearchHitSummary]
}

package struct QuerySupportMaterial: Sendable {
    package let answer: String
    package let sourceIDs: [String]
    package let authorityIDs: [String]
    package let claimIDs: [String]
}

package func chooseQueryAnswerHits(question: String, hits: [SearchHitSummary]) -> QueryHitSelection {
    let preferredHits = preferredHitsForQuery(hits)
    guard !preferredHits.isEmpty else {
        return QueryHitSelection(preferred: [], selected: [])
    }
    let ranked = preferredHits.sorted { lhs, rhs in
        queryPreferenceKey(question: question, item: lhs) > queryPreferenceKey(question: question, item: rhs)
    }
    return QueryHitSelection(
        preferred: preferredHits,
        selected: selectAnswerHits(question: question, preferredHits: ranked)
    )
}

package func buildQuerySupportMaterial(question: String, selectedHits: [SearchHitSummary]) -> QuerySupportMaterial {
    let answer: String
    if selectedHits.isEmpty {
        answer = "No grounded result found in the local vault."
    } else {
        answer = selectedHits.map { item in
            if item.docKind == "source" {
                return "\(item.title): \(firstLine(item.snippet, maxLen: 220))"
            }
            return "\(item.title): \(firstLine(item.snippet))"
        }.joined(separator: "\n")
    }

    var sourceIDs: [String] = []
    var authorityIDs: [String] = []
    var claimIDs: [String] = []

    for item in selectedHits {
        sourceIDs.append(contentsOf: splitIDs(item.metadata["source_ids"]))
        authorityIDs.append(contentsOf: splitIDs(item.metadata["authority_ids"]))
        claimIDs.append(contentsOf: splitIDs(item.metadata["claim_ids"]))
        if let recordID = item.metadata["record_id"] { authorityIDs.append(recordID) }
        if let claimID = item.metadata["claim_id"] { claimIDs.append(claimID) }
    }

    return QuerySupportMaterial(
        answer: answer,
        sourceIDs: Array(Set(sourceIDs)).sorted(),
        authorityIDs: Array(Set(authorityIDs)).sorted(),
        claimIDs: Array(Set(claimIDs)).sorted()
    )
}

package func buildQueryArtifactPatch(
    question: String,
    requestedAt: String,
    fileBackSlug: String,
    support: QuerySupportMaterial
) throws -> KnowledgePatchPlan {
    let metadata = ProjectionMetadata(
        projectionKind: .queryArtifact,
        projectionSpace: .wiki,
        subjectKind: "query",
        subjectID: stableID(prefix: "query", parts: [question]),
        authorityIDs: support.authorityIDs,
        sourceIDs: support.sourceIDs,
        claimIDs: support.claimIDs,
        historical: false,
        approvalRequired: false
    )
    var document = ProjectionDocument(
        version: projectionDocumentVersion,
        slug: fileBackSlug,
        title: "Query artifact: " + String(question.prefix(72)),
        bodyMD: "# Query artifact\n\nQuestion: \(question)\n\nAnswer:\n\n\(support.answer)",
        metadata: metadata,
        generatedFromHash: "",
        generatedAt: requestedAt
    )
    document.generatedFromHash = projectionDocumentHash(document)
    let write = ProjectionWrite(slug: fileBackSlug, state: .draft, document: document)
    let request = RefreshProjectionRequest(
        version: refreshProjectionRequestVersion,
        requestedAt: requestedAt,
        trigger: "query_file_back:\(question)",
        proposedWrites: [write]
    )
    return try planProjectionRefreshRequest(request).patch
}

private func splitIDs(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    return raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
}
