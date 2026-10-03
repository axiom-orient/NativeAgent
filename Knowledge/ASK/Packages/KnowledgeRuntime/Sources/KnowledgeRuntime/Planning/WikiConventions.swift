import Foundation
import KnowledgeCore

package struct PageLinkRow: Sendable, Equatable {
    package var fromSlug: String
    package var toSlug: String
    package var linkKind: String
    package var anchorText: String?
    package var createdAt: String

    package init(fromSlug: String, toSlug: String, linkKind: String = "wikilink", anchorText: String? = nil, createdAt: String) {
        self.fromSlug = fromSlug
        self.toSlug = toSlug
        self.linkKind = linkKind
        self.anchorText = anchorText
        self.createdAt = createdAt
    }
}

package func projectionFamily(for metadata: ProjectionMetadata, slug: String) -> ProjectionFamily {
    switch metadata.projectionSpace {
    case .playbook: return .playbook
    case .casebook: return .casebook
    case .wiki:
        switch metadata.projectionKind {
        case .sourceSummary: return .source
        case .entityOverview: return .entity
        case .topicOverview: return .topic
        case .currentSnapshot: return .current
        case .queryArtifact: return .query
        default:
            let normalized = normalizeProjectionSlugPath(slug)
            if normalized.hasPrefix("sources/") { return .source }
            if normalized.hasPrefix("entities/") { return .entity }
            if normalized.hasPrefix("topics/") { return .topic }
            if normalized.hasPrefix("current/") { return .current }
            if normalized.hasPrefix("queries/") { return .query }
            return .other
        }
    }
}

package func isCanonicalProjectionFamily(_ family: ProjectionFamily) -> Bool {
    switch family {
    case .source, .entity, .topic, .current, .playbook, .casebook:
        return true
    case .query, .other:
        return false
    }
}

package func canonicalWikiSubdirectory(for metadata: ProjectionMetadata, slug: String) -> String {
    switch projectionFamily(for: metadata, slug: slug) {
    case .source: return "wiki/sources"
    case .entity: return "wiki/entities"
    case .topic: return "wiki/topics"
    case .current: return "wiki/current"
    case .playbook: return "wiki/playbook"
    case .casebook: return "wiki/casebook"
    case .query: return "wiki/queries"
    case .other: return "wiki/wiki"
    }
}

package func canonicalProjectionSlug(slug: String, metadata: ProjectionMetadata) -> String {
    let leaf = canonicalProjectionLeaf(slug: slug, metadata: metadata)
    switch projectionFamily(for: metadata, slug: slug) {
    case .source: return "sources/" + leaf
    case .entity: return "entities/" + leaf
    case .topic: return "topics/" + leaf
    case .current: return "current/" + leaf
    case .playbook: return "playbook/" + leaf
    case .casebook: return "casebook/" + leaf
    case .query: return "queries/" + leaf
    case .other: return normalizeProjectionSlugPath(slug)
    }
}

package func projectionRelativePath(slug: String, metadata: ProjectionMetadata) -> String {
    let relativeLeaf = canonicalProjectionLeaf(slug: slug, metadata: metadata)
    return canonicalWikiSubdirectory(for: metadata, slug: slug) + "/" + relativeLeaf + ".md"
}

package func canonicalProjectionLeaf(slug: String, metadata: ProjectionMetadata) -> String {
    let normalized = normalizeProjectionSlugPath(slug)
    let prefixes: [String]
    switch projectionFamily(for: metadata, slug: slug) {
    case .source:
        prefixes = ["wiki/", "sources/"]
    case .entity:
        prefixes = ["wiki/", "entities/"]
    case .topic:
        prefixes = ["wiki/", "topics/"]
    case .current:
        prefixes = ["wiki/", "current/"]
    case .playbook:
        prefixes = ["playbook/"]
    case .casebook:
        prefixes = ["casebook/"]
    case .query:
        prefixes = ["query/", "queries/"]
    case .other:
        prefixes = ["wiki/"]
    }
    return trimKnownPrefixes(normalized, prefixes: prefixes)
}

package func normalizeProjectionSlugPath(_ slug: String) -> String {
    let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return slug }
    let parts = trimmed.split(separator: "/").filter { !$0.isEmpty }
    guard !parts.isEmpty else { return slug }
    return parts.joined(separator: "/")
}

private func trimKnownPrefixes(_ slug: String, prefixes: [String]) -> String {
    var current = slug
    var changed = true
    while changed {
        changed = false
        for prefix in prefixes where current.hasPrefix(prefix) {
            current.removeFirst(prefix.count)
            changed = true
        }
    }
    return current.isEmpty ? slug : current
}

package func wikiLink(_ slug: String, title: String? = nil) -> String {
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "[[\(slug)|\(title)]]"
    }
    return "[[\(slug)]]"
}

package func extractWikiLinkRows(from body: String, fromSlug: String, createdAt: String) -> [PageLinkRow] {
    var rows: [PageLinkRow] = []
    var seen = Set<String>()
    var searchStart = body.startIndex

    while searchStart < body.endIndex,
          let opening = body.range(of: "[[", range: searchStart..<body.endIndex),
          let closing = body.range(of: "]]", range: opening.upperBound..<body.endIndex) {
        let content = body[opening.upperBound..<closing.lowerBound]
        if let parsed = parseWikiLinkContent(content) {
            let normalized = normalizeProjectionSlugPath(parsed.slug)
            if !normalized.isEmpty {
                let key = normalized + "::wikilink"
                if seen.insert(key).inserted {
                    rows.append(
                        PageLinkRow(
                            fromSlug: fromSlug,
                            toSlug: normalized,
                            anchorText: parsed.title,
                            createdAt: createdAt
                        )
                    )
                }
            }
        }
        searchStart = closing.upperBound
    }

    return rows.sorted { $0.toSlug < $1.toSlug }
}

private func parseWikiLinkContent(_ content: Substring) -> (slug: String, title: String?)? {
    guard !content.isEmpty else { return nil }

    let pipeIndex = content.firstIndex(of: "|")
    let targetWithFragment = pipeIndex.map { content[..<$0] } ?? content[...]
    let title: String?
    if let pipeIndex {
        let rawTitle = content[content.index(after: pipeIndex)...]
        guard !rawTitle.isEmpty, !rawTitle.contains("]") else { return nil }
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? nil : trimmed
    } else {
        title = nil
    }

    let hashIndex = targetWithFragment.firstIndex(of: "#")
    if let hashIndex {
        let fragment = targetWithFragment[targetWithFragment.index(after: hashIndex)...]
        guard !fragment.isEmpty else { return nil }
    }
    let rawSlug = hashIndex.map { targetWithFragment[..<$0] } ?? targetWithFragment[...]
    guard !rawSlug.isEmpty,
          !rawSlug.contains("]"),
          !rawSlug.contains("|") else {
        return nil
    }
    return (String(rawSlug), title)
}

package func slugTitle(_ slug: String) -> String {
    let leaf = normalizeProjectionSlugPath(slug).split(separator: "/").last.map(String.init) ?? slug
    guard !leaf.isEmpty else { return slug }
    return leaf
        .split(separator: "-")
        .map { part in
            guard let first = part.first else { return "" }
            return String(first).uppercased() + part.dropFirst().lowercased()
        }
        .joined(separator: " ")
}
