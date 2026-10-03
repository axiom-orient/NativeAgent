import Foundation
import KnowledgeCore

package enum ASKWorkWikiSearch {
    package static func search(
        query: String,
        documents: [ASKWorkWikiIndexedDocument],
        limit: Int
    ) throws -> [ASKWorkWikiKnowledgeSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ASKError.validation("work-wiki knowledge search query must not be empty")
        }
        guard limit > 0 else {
            throw ASKError.validation("work-wiki knowledge search limit must be positive")
        }

        let normalizedQuery = normalize(trimmed)
        let tokens = normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        return documents.compactMap { document in
            let score = score(document: document, normalizedQuery: normalizedQuery, tokens: tokens)
            guard score > 0 else { return nil }
            return ASKWorkWikiKnowledgeSearchHit(
                relativePath: document.relativePath,
                category: document.category,
                title: document.title,
                snippet: snippet(document: document, tokens: tokens),
                score: score
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.relativePath < rhs.relativePath
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func score(document: ASKWorkWikiIndexedDocument, normalizedQuery: String, tokens: [String]) -> Int {
        let normalizedPath = normalize(document.relativePath)
        let normalizedTitle = normalize(document.title)
        let normalizedBody = normalize(document.body)

        var value = 0
        if normalizedTitle.contains(normalizedQuery) { value += 20 }
        if normalizedPath.contains(normalizedQuery) { value += 12 }
        if normalizedBody.contains(normalizedQuery) { value += 8 }

        for token in tokens {
            if normalizedTitle.contains(token) { value += 6 }
            if normalizedPath.contains(token) { value += 4 }
            if normalizedBody.contains(token) { value += 1 }
        }
        return value
    }

    private static func snippet(document: ASKWorkWikiIndexedDocument, tokens: [String]) -> String {
        let lines = document.body.components(separatedBy: .newlines).compactMap { rawLine -> (line: String, normalized: String)? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return (line, normalize(line))
        }

        if let line = lines.first(where: { entry in
            tokens.allSatisfy { token in entry.normalized.contains(token) }
        }) {
            return line.line
        }
        if let line = lines.first(where: { entry in
            tokens.contains { token in entry.normalized.contains(token) }
        }) {
            return line.line
        }
        return document.title
    }

    private static func normalize(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
