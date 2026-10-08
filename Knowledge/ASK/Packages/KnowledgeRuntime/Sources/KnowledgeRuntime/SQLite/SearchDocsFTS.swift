import Foundation
import KnowledgeCore

private func ftsTokens(_ value: String) -> [String] {
    SearchText.tokenize(value)
}

private func ftsMatchQuery(_ raw: String) -> String? {
    let tokens = Array(Set(ftsTokens(raw))).sorted()
    guard !tokens.isEmpty else { return nil }
    return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
}

private func decodeSearchRow(from statement: SQLiteStatement) throws -> SQLiteSearchCandidate {
    let metadataJSON = statement.string(at: 7) ?? "{}"
    let metadataData = Data(metadataJSON.utf8)
    let metadata = try CanonicalJSON.decoder().decode([String: String].self, from: metadataData)
    let row = SearchDocRow(
        docID: statement.string(at: 0) ?? "",
        docKind: statement.string(at: 1) ?? "",
        subjectKind: statement.string(at: 2) ?? "",
        subjectID: statement.string(at: 3) ?? "",
        projectionSlug: statement.string(at: 4),
        title: statement.string(at: 5) ?? "",
        body: statement.string(at: 6) ?? "",
        metadata: metadata
    )
    try row.validate()
    return SQLiteSearchCandidate(
        row: row,
        snippet: statement.string(at: 8) ?? "",
        ftsRank: statement.double(at: 9)
    )
}

package func searchMirrorCandidates(at path: URL, query: String, limit: Int = 24) throws -> [SQLiteSearchCandidate] {
    guard limit >= 0 else {
        throw ASKError.validation("search limit must be non-negative")
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard let matchQuery = ftsMatchQuery(trimmed) else { return [] }

    let sql = """
    SELECT sd.doc_id, sd.doc_kind, sd.subject_kind, sd.subject_id, sd.projection_slug,
           sd.title, sd.body, sd.metadata_json,
           snippet(search_docs_fts, 2, '', '', ' … ', 18) AS snippet,
           bm25(search_docs_fts) AS rank
    FROM search_docs_fts
    JOIN search_docs AS sd ON sd.doc_id = search_docs_fts.doc_id
    WHERE search_docs_fts MATCH ?
    ORDER BY rank
    LIMIT ?;
    """
    let db: SQLiteDatabase
    do {
        db = try SQLiteDatabase(path: path, readOnly: true)
    } catch is SQLiteDatabaseMissing {
        // No mirror yet means no candidates, not a failure.
        return []
    }
    let statement = try db.prepare(sql)
    defer { statement.finalize() }
    try statement.bind(matchQuery, at: 1)
    try statement.bind(limit, at: 2)

    var output: [SQLiteSearchCandidate] = []
    while try statement.step() {
        output.append(try decodeSearchRow(from: statement))
    }
    return output
}
