import Foundation
import KnowledgeCore

private let queryStopwords: Set<String> = [
    "a", "an", "and", "are", "be", "built", "current", "for", "how", "i", "in",
    "is", "of", "on", "or", "project", "projects", "should", "team", "the", "to",
    "what", "which", "with", "version", "versions", "optimize",
]

private struct SearchHit {
    let doc: SearchDocRow
    let score: Double
    let snippet: String
    let sortTitle: String
    let lexicalScore: Int
    let ftsScore: Double
}

private func tokenize(_ value: String) -> [String] {
    SearchText.tokenize(value)
}

private func normalizedMetadataText(_ metadata: [String: String]) -> String {
    metadata.map { "\($0.key) \($0.value)" }.joined(separator: " ").lowercased()
}

private func lexicalScore(for row: SearchDocRow, tokens: [String]) -> Int {
    guard !tokens.isEmpty else { return 0 }
    let hayTitle = row.title.lowercased()
    let hayBody = row.body.lowercased()
    let hayMeta = normalizedMetadataText(row.metadata)
    var score = 0
    for token in tokens {
        score += SearchText.countOccurrences(of: token, in: hayTitle) * 4
        score += SearchText.countOccurrences(of: token, in: hayBody) * 2
        score += SearchText.countOccurrences(of: token, in: hayMeta)
    }
    return score
}

private func lexicalQuality(lexicalScore: Int, tokenCount: Int) -> Double {
    min(1.0, Double(lexicalScore) / Double(max(1, tokenCount) * 8))
}

private func titleExactMatchScore(row: SearchDocRow, query: String) -> Double {
    let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return 0 }
    let title = row.title.lowercased()
    if title == normalizedQuery { return 1.0 }
    let queryTokens = Set(tokenize(query))
    guard !queryTokens.isEmpty else { return 0 }
    let titleTokens = Set(tokenize(row.title))
    if !queryTokens.isSubset(of: titleTokens) { return 0 }
    if title.hasPrefix(normalizedQuery) { return 0.95 }
    return 0.8
}

private func authorityScore(metadata: [String: String]) -> Double {
    switch metadata["authority_state"] {
    case AuthorityState.approved.rawValue?: return 1.0
    case AuthorityState.draft.rawValue?: return 0.65
    case AuthorityState.superseded.rawValue?: return 0.2
    case AuthorityState.rejected.rawValue?: return 0.1
    default: return 0.5
    }
}

private func linkSupportScore(metadata: [String: String]) -> Double {
    let count = max(0, Int(metadata["link_count"] ?? "") ?? 0)
    guard count > 0 else { return 0 }
    return min(1.0, Double(count) / 4.0)
}

private func canonicalScore(for row: SearchDocRow) -> Double {
    if row.docKind == "source" { return 1.0 }
    if row.metadata["is_canonical"] == "1" { return 1.0 }
    return 0.0
}

private let rankingTimestampKeys = ["last_confirmed_at", "observed_at", "generated_at"]

private func rankingTimestamp(metadata: [String: String]) -> Date? {
    rankingTimestampKeys
        .compactMap { metadata[$0] }
        .compactMap(ASKTimestamp.parse)
        .max()
}

private func rankingReferenceDate(rows: [SearchDocRow]) -> Date {
    rows.compactMap { rankingTimestamp(metadata: $0.metadata) }.max() ?? Date(timeIntervalSince1970: 0)
}

private func freshnessScore(metadata: [String: String], referenceDate: Date) -> Double {
    guard let date = rankingTimestamp(metadata: metadata) else {
        return 0.35
    }
    let age = referenceDate.timeIntervalSince(date)
    if age <= 0 { return 1.0 }
    let day = 86_400.0
    switch age {
    case ..<(7 * day): return 1.0
    case ..<(30 * day): return 0.85
    case ..<(90 * day): return 0.65
    case ..<(365 * day): return 0.4
    default: return 0.2
    }
}

private func queryArtifactPenalty(for row: SearchDocRow) -> Double {
    let family = row.metadata["projection_family"] ?? ""
    let kind = row.metadata["projection_kind"] ?? ""
    let slug = row.projectionSlug ?? ""
    if family == ProjectionFamily.query.rawValue || kind == ProjectionKind.queryArtifact.rawValue || slug.hasPrefix("query/") || slug.hasPrefix("queries/") {
        return 1.0
    }
    return 0.0
}

private func stalenessPenalty(for row: SearchDocRow) -> Double {
    if row.metadata["authority_state"] == AuthorityState.superseded.rawValue { return 1.0 }
    if row.metadata["historical"] == "1" { return 0.35 }
    return 0.0
}

private func ftsQuality(from rank: Double?) -> Double {
    guard let rank else { return 0 }
    if rank < 0 {
        return 1.0 - (1.0 / (1.0 + abs(rank)))
    }
    return 1.0 / (1.0 + rank)
}

private func compositeScore(row: SearchDocRow, query: String, tokenCount: Int, lexicalScore: Int, ftsRank: Double?, referenceDate: Date) -> Double {
    let lexical = lexicalQuality(lexicalScore: lexicalScore, tokenCount: tokenCount)
    let title = titleExactMatchScore(row: row, query: query)
    let link = linkSupportScore(metadata: row.metadata)
    let freshness = freshnessScore(metadata: row.metadata, referenceDate: referenceDate)
    let authority = authorityScore(metadata: row.metadata)
    let canonical = canonicalScore(for: row)
    let fts = ftsQuality(from: ftsRank)
    let queryPenalty = queryArtifactPenalty(for: row)
    let stalePenalty = stalenessPenalty(for: row)

    return (0.45 * fts)
        + (0.18 * title)
        + (0.12 * link)
        + (0.10 * freshness)
        + (0.10 * authority)
        + (0.10 * lexical)
        + (0.10 * canonical)
        - (0.25 * queryPenalty)
        - (0.20 * stalePenalty)
}

private func snippetText(for row: SearchDocRow, override: String?) -> String {
    firstLine(override ?? row.body, maxLen: 180)
}

private func rankSearchRows(
    _ rows: [SearchDocRow],
    query: String,
    limit: Int = 8,
    snippetOverrides: [String: String] = [:],
    ftsRanks: [String: Double] = [:]
) -> [SearchHit] {
    let tokens = tokenize(query)
    guard !tokens.isEmpty, limit >= 0 else { return [] }
    let referenceDate = rankingReferenceDate(rows: rows)

    var hits: [SearchHit] = []
    for row in rows {
        let lexical = lexicalScore(for: row, tokens: tokens)
        let ftsRank = ftsRanks[row.docID]
        if lexical <= 0 && ftsRank == nil { continue }
        let ftsScore = ftsQuality(from: ftsRank)
        let score = compositeScore(row: row, query: query, tokenCount: tokens.count, lexicalScore: lexical, ftsRank: ftsRank, referenceDate: referenceDate)
        if score <= 0 { continue }
        hits.append(
            SearchHit(
                doc: row,
                score: score,
                snippet: snippetText(for: row, override: snippetOverrides[row.docID]),
                sortTitle: row.title.lowercased(),
                lexicalScore: lexical,
                ftsScore: ftsScore
            )
        )
    }

    hits.sort {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.ftsScore != $1.ftsScore { return $0.ftsScore > $1.ftsScore }
        if $0.lexicalScore != $1.lexicalScore { return $0.lexicalScore > $1.lexicalScore }
        if $0.sortTitle != $1.sortTitle { return $0.sortTitle < $1.sortTitle }
        return $0.doc.docID < $1.doc.docID
    }
    return Array(hits.prefix(limit))
}

private func toSummary(_ hit: SearchHit) -> SearchHitSummary {
    SearchHitSummary(
        docID: hit.doc.docID,
        docKind: hit.doc.docKind,
        title: hit.doc.title,
        subjectKind: hit.doc.subjectKind,
        subjectID: hit.doc.subjectID,
        projectionSlug: hit.doc.projectionSlug,
        score: hit.score,
        snippet: hit.snippet,
        metadata: hit.doc.metadata
    )
}

package func debugSearchRankingScores(rows: [SearchDocRow], query: String, limit: Int = 8) -> [SearchHitSummary] {
    rankSearchRows(rows, query: query, limit: limit).map(toSummary)
}

package func searchMirrorFirst(root: String, query: String, limit: Int) throws -> [SearchHitSummary] {
    guard limit >= 0 else {
        throw ASKError.validation("search limit must be non-negative")
    }
    let vault = Vault(rootPath: root)
    let (scaledLimit, overflow) = limit.multipliedReportingOverflow(by: 4)
    let candidateLimit = max(overflow ? Int.max : scaledLimit, 24)
    if try mirrorIsFresh(vault: vault) {
        let mirrorHits = try searchMirrorCandidates(at: vault.mirrorURL(), query: query, limit: candidateLimit)
        return rankMirrorCandidates(mirrorHits, query: query, limit: candidateLimit).map(toSummary)
    }

    return try searchJournalRows(vault: vault, query: query, limit: candidateLimit)
}

private func mirrorIsFresh(vault: Vault) throws -> Bool {
    let mirrorURL = vault.mirrorURL()
    guard FileManager.default.fileExists(atPath: mirrorURL.path) else { return false }
    guard
        let marker = try vault.readGenerationMarker(),
        let expectedSearchDocCount = marker.searchDocCount
    else {
        return false
    }
    let identity = try vault.journalIdentity()
    let generation = ASKStorageGenerationHasher.value(for: Data(identity.fingerprint.utf8))
    guard marker.canonicalGeneration.value == generation else { return false }
    let counts = try mirrorCounts(at: mirrorURL)
    let mirrorSearchDocCount = counts["search_docs"] ?? counts["search_docs_fts"]
    return mirrorSearchDocCount == expectedSearchDocCount
}

private func rankMirrorCandidates(_ mirrorHits: [SQLiteSearchCandidate], query: String, limit: Int) -> [SearchHit] {
    var ftsRanks: [String: Double] = [:]
    for hit in mirrorHits {
        ftsRanks[hit.row.docID] = hit.ftsRank
    }
    return rankSearchRows(
        mirrorHits.map(\.row),
        query: query,
        limit: limit,
        ftsRanks: ftsRanks
    )
}

private func searchJournalRows(vault: Vault, query: String, limit: Int) throws -> [SearchHitSummary] {
    let (store, _) = try vault.loadStoreFromJournal()
    let storeRows = store.iterSearchDocs()
    let ranked = rankSearchRows(storeRows, query: query, limit: limit)
    return ranked.map(toSummary)
}

package func buildDebugSourceSearchDoc(root: String, sourceID: String) throws -> SearchDocRow? {
    let (store, _) = try Vault(rootPath: root).loadStoreFromJournal()
    let docID = stableID(prefix: "search", parts: ["source", sourceID])
    return store.searchDoc(docID)
}

package func buildDebugMirrorSearch(root: String, query: String, limit: Int) throws -> [DebugMirrorCandidate] {
    let vault = Vault(rootPath: root)
    var candidates = try searchMirrorCandidates(at: vault.mirrorURL(), query: query, limit: limit)
    if candidates.isEmpty {
        let (store, _) = try vault.loadStoreFromJournal()
        try rebuildMirror(at: vault.mirrorURL(), store: store)
        candidates = try searchMirrorCandidates(at: vault.mirrorURL(), query: query, limit: limit)
    }
    return candidates.map { candidate in
        DebugMirrorCandidate(
            docID: candidate.row.docID,
            docKind: candidate.row.docKind,
            title: candidate.row.title,
            subjectID: candidate.row.subjectID,
            snippet: firstLine(candidate.snippet, maxLen: 180),
            rank: candidate.ftsRank,
            metadata: candidate.row.metadata
        )
    }
}

package func queryTokens(_ text: String) -> Set<String> {
    Set(tokenize(text)).subtracting(queryStopwords)
}

package func firstLine(_ value: String, maxLen: Int = 160) -> String {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    if text.count > maxLen { return String(text.prefix(maxLen)) + "…" }
    return text
}
