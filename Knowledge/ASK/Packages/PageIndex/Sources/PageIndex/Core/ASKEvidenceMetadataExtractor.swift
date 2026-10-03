import Foundation

public enum ASKEvidenceMetadataExtractor {
    public static func metadata(for artifact: SourceIndexArtifact) throws -> ASKEvidenceMetadata {
        if let metadata = artifact.evidenceMetadata {
            return metadata
        }
        let frontmatter = try artifact.frontmatter ?? readFrontmatter(from: artifact.sourcePath)
        return metadata(
            sourceID: artifact.document.sourceID,
            sourcePath: artifact.sourcePath,
            documentTitle: artifact.document.title,
            frontmatter: frontmatter
        )
    }

    public static func metadata(
        sourceID: SourceID,
        sourcePath: String?,
        documentTitle: String,
        frontmatter: ASKEvidenceFrontmatter = ASKEvidenceFrontmatter()
    ) -> ASKEvidenceMetadata {
        let stage = frontmatter.scalar("stage")
        let type = frontmatter.scalar("type") ?? frontmatter.scalar("kind")
        let scope = ASKEvidenceScope(rawValue: frontmatter.scalar("scope") ?? "") ?? inferScope(from: sourcePath)
        let kind = inferKind(type: type, stage: stage, sourcePath: sourcePath)
        return ASKEvidenceMetadata(
            sourceID: sourceID,
            sourcePath: sourcePath,
            documentTitle: documentTitle,
            scope: scope,
            kind: kind,
            topic: frontmatter.scalar("topic"),
            stage: stage,
            status: frontmatter.scalar("status"),
            updatedAt: frontmatter.scalar("updated_at") ?? frontmatter.scalar("updatedAt"),
            tags: frontmatter.list("tags"),
            sourceRefs: frontmatter.list("source_refs") + frontmatter.list("sourceRefs")
        )
    }

    public static func parseFrontmatter(markdown: String) -> ASKEvidenceFrontmatter {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ASKEvidenceFrontmatter() }
        let lines = normalized.components(separatedBy: "\n")
        var body: [String] = []
        for index in 1 ..< lines.count {
            if lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                break
            }
            body.append(lines[index])
        }
        return ASKEvidenceFrontmatter.parse(lines: body)
    }

    private static func readFrontmatter(from sourcePath: String?) throws -> ASKEvidenceFrontmatter {
        guard let sourcePath else { return ASKEvidenceFrontmatter() }
        let markdown = try String(contentsOfFile: sourcePath, encoding: .utf8)
        return parseFrontmatter(markdown: markdown)
    }

    private static func inferScope(from sourcePath: String?) -> ASKEvidenceScope {
        guard let sourcePath = sourcePath?.lowercased() else { return .unknown }
        if sourcePath.contains("/work") || sourcePath.contains("work-wiki") || sourcePath.contains("workwiki") { return .work }
        if sourcePath.contains("/research") || sourcePath.contains("research-wiki") { return .research }
        if sourcePath.contains("/days/") || sourcePath.contains("/logs/") || sourcePath.contains("/journal/") { return .general }
        return .unknown
    }

    private static func inferKind(type: String?, stage: String?, sourcePath: String?) -> ASKEvidenceKind {
        if let type, let kind = ASKEvidenceKind(rawValue: type) { return kind }
        if let stage {
            if stage == "docs" { return .docs }
            return .stage
        }
        guard let lower = sourcePath?.lowercased() else { return .unknown }
        if lower.contains("/decisions/") { return .decision }
        if lower.contains("/reports/") { return .report }
        if lower.contains("/references/") || lower.contains("/wiki/docs/") { return .reference }
        if lower.contains("/days/") || lower.contains("/daily/") { return .worklog }
        if lower.contains("/raw/") || lower.contains("/evidence/") { return .source }
        return .unknown
    }
}

public struct ASKEvidenceFrontmatter: Codable, Hashable, Sendable {
    private var scalars: [String: String]
    private var lists: [String: [String]]

    public init(scalars: [String: String] = [:], lists: [String: [String]] = [:]) {
        self.scalars = scalars
        self.lists = lists
    }

    public func scalar(_ key: String) -> String? {
        scalars[key]
    }

    public func list(_ key: String) -> [String] {
        lists[key] ?? scalars[key].map { splitInlineList($0) } ?? []
    }

    static func parse(lines: [String]) -> ASKEvidenceFrontmatter {
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var currentListKey: String?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("-") {
                if let key = currentListKey {
                    let value = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).trimmedYAMLQuotes()
                    if !value.isEmpty { lists[key, default: []].append(value) }
                }
                continue
            }
            currentListKey = nil
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                lists[key] = []
                currentListKey = key
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                lists[key] = splitInlineList(value)
            } else {
                scalars[key] = value.trimmedYAMLQuotes()
            }
        }

        return ASKEvidenceFrontmatter(scalars: scalars, lists: lists)
    }
}

private func splitInlineList(_ value: String) -> [String] {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") { trimmed.removeFirst() }
    if trimmed.hasSuffix("]") { trimmed.removeLast() }
    return trimmed
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmedYAMLQuotes() }
        .filter { !$0.isEmpty }
}

private extension String {
    func trimmedYAMLQuotes() -> String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           ((value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'")) {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
}
