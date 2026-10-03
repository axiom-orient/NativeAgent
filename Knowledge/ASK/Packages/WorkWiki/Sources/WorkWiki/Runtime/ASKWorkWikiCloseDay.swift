import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public enum ASKWorkWikiCloseDay {
    public static func validate(_ request: ASKWorkWikiCloseDayRequest) throws {
        guard isValidDay(request.date) else {
            throw ASKError.validation("work-wiki close-day date must use YYYY-MM-DD")
        }
        guard ASKTimestamp.isValidRFC3339(request.requestedAt) else {
            throw ASKError.validation("work-wiki close-day requested_at must be valid RFC3339")
        }
        guard request.maxEvidenceBytes > 0 else {
            throw ASKError.validation("work-wiki close-day maxEvidenceBytes must be positive")
        }
        if let slug = request.slug, !isValidProjectionSlug(slug) {
            throw ASKError.validation("work-wiki close-day slug must contain only [a-z0-9-/]")
        }
        if let subjectID = request.subjectID,
           subjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ASKError.validation("work-wiki close-day subjectID must not be empty when provided")
        }
    }

    public static func dayDocuments(
        from documents: [ASKEvidenceMetadata],
        matching request: ASKWorkWikiCloseDayRequest
    ) -> [ASKEvidenceMetadata] {
        documents
            .filter { metadataMatchesDay($0, date: request.date) }
            .sorted { lhs, rhs in
                (lhs.sourcePath ?? lhs.documentTitle) < (rhs.sourcePath ?? rhs.documentTitle)
            }
    }

    public static func evidenceQuery(
        for request: ASKWorkWikiCloseDayRequest,
        documents: [ASKEvidenceMetadata]
    ) -> ASKEvidenceQuery {
        var filter = request.filter
        filter.sourceIDs = Set(documents.map(\.sourceID))
        return ASKEvidenceQuery(
            text: request.queryText,
            filter: filter,
            limit: 40,
            excerptLineLimit: 20
        )
    }

    static func projectionSlug(for request: ASKWorkWikiCloseDayRequest) -> String {
        request.slug ?? "work/reports/daily/\(request.date)"
    }

    public static func makeProjectionWrite(
        request: ASKWorkWikiCloseDayRequest,
        evidencePack: ASKEvidencePack,
        documents: [ASKEvidenceMetadata],
        summary: ASKWorkWikiCloseDaySummary,
        expectedBaseRevision: String?
    ) throws -> ProjectionWrite {
        try ASKWorkWikiReportProjection.makeEvidenceProjectionWrite(
            slug: projectionSlug(for: request), title: "Close Day: \(request.date)",
            subjectID: request.subjectID, requestedAt: request.requestedAt,
            evidencePack: evidencePack, expectedBaseRevision: expectedBaseRevision
        ) { sourceIDs in
            renderBody(request: request, evidencePack: evidencePack,
                       documents: documents, summary: summary, sourceIDs: sourceIDs)
        }
    }

    public static func summarize(_ pack: ASKEvidencePack) -> ASKWorkWikiCloseDaySummary {
        var builder = CloseDaySummaryBuilder()
        for hit in pack.hits {
            builder.consume(hit)
        }
        return builder.summary()
    }

    private static func renderBody(
        request: ASKWorkWikiCloseDayRequest,
        evidencePack: ASKEvidencePack,
        documents: [ASKEvidenceMetadata],
        summary: ASKWorkWikiCloseDaySummary,
        sourceIDs: [String]
    ) -> String {
        let sources = sourceIDs.map { "- \($0)" }.joined(separator: "\n")
        let documentLines = documents.map { document in
            let path = document.sourcePath ?? document.sourceID.rawValue
            return "- \(document.sourceID.rawValue) :: \(path)"
        }.joined(separator: "\n")
        let queryLine = request.queryText.isEmpty ? "(all matching day documents)" : request.queryText
        return """
        # Close Day: \(request.date)

        ## Query
        \(queryLine)

        ## Evidence Summary
        - document_count: \(documents.count)
        - hit_count: \(evidencePack.hits.count)
        - source_count: \(sourceIDs.count)
        - truncated: \(evidencePack.truncated)

        ## Deterministic Candidates

        ### Done
        \(renderItems(summary.done))

        ### Blockers
        \(renderItems(summary.blockers))

        ### Decisions
        \(renderItems(summary.decisions))

        ### Next
        \(renderItems(summary.next))

        ## Source IDs
        \(sources)

        ## Matched Documents
        \(documentLines)

        ## Evidence Pack
        \(evidencePack.renderedMarkdown)
        """
    }

    private static func renderItems(_ items: [String]) -> String {
        if items.isEmpty { return "- None found from explicit labels or headings." }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func metadataMatchesDay(_ metadata: ASKEvidenceMetadata, date: String) -> Bool {
        if metadata.updatedAt?.contains(date) == true { return true }
        if metadata.sourcePath?.contains(date) == true { return true }
        if metadata.documentTitle.contains(date) { return true }
        return false
    }
}

private struct CloseDaySummaryBuilder {
    private var done: [String] = []
    private var blockers: [String] = []
    private var decisions: [String] = []
    private var next: [String] = []
    private var seen: Set<String> = []

    mutating func consume(_ hit: ASKEvidenceHit) {
        let path = hit.metadata.sourcePath ?? hit.sourceID.rawValue
        var activeSection: CloseDaySection?
        for rawLine in hit.excerpt.components(separatedBy: .newlines) {
            let parsed = parseEvidenceLine(rawLine, fallbackRange: hit.range)
            let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("```") else { continue }

            if let section = sectionHeading(text) {
                activeSection = section
                continue
            }

            if let labelled = labelledCandidate(text) {
                append(labelled.item, to: labelled.section, path: path, locator: parsed.locator)
                continue
            }

            if let activeSection, isCandidateLine(text) {
                append(cleanCandidate(text), to: activeSection, path: path, locator: parsed.locator)
            }
        }
    }

    func summary() -> ASKWorkWikiCloseDaySummary {
        ASKWorkWikiCloseDaySummary(done: done, blockers: blockers, decisions: decisions, next: next)
    }

    private mutating func append(_ item: String, to section: CloseDaySection, path: String, locator: String) {
        let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let rendered = "\(cleaned) — \(path)#\(locator)"
        guard seen.insert("\(section.rawValue)::\(rendered)").inserted else { return }
        switch section {
        case .done: done.append(rendered)
        case .blockers: blockers.append(rendered)
        case .decisions: decisions.append(rendered)
        case .next: next.append(rendered)
        }
    }
}

private enum CloseDaySection: String {
    case done
    case blockers
    case decisions
    case next
}

private func parseEvidenceLine(_ rawLine: String, fallbackRange: SourceRange) -> (text: String, locator: String) {
    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackLocator: String
    switch fallbackRange.space {
    case .line:
        fallbackLocator = "L\(fallbackRange.start)-L\(fallbackRange.end)"
    case .page:
        fallbackLocator = "P\(fallbackRange.start)-P\(fallbackRange.end)"
    }

    guard let colonIndex = trimmed.firstIndex(of: ":") else {
        return (trimmed, fallbackLocator)
    }
    let prefix = String(trimmed[..<colonIndex])
    let bodyStart = trimmed.index(after: colonIndex)
    let body = String(trimmed[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    if isLineOrPageLocator(prefix) {
        return (body, prefix)
    }
    return (trimmed, fallbackLocator)
}

private func isLineOrPageLocator(_ value: String) -> Bool {
    guard let first = value.first, first == "L" || first == "P" else { return false }
    let digits = value.dropFirst()
    return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
}

private func sectionHeading(_ text: String) -> CloseDaySection? {
    guard text.hasPrefix("#") else { return nil }
    let heading = text.drop { $0 == "#" || $0 == " " || $0 == "\t" }
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    switch heading {
    case "done", "completed", "complete", "results", "result": return .done
    case "blockers", "blocker", "blocked": return .blockers
    case "decisions", "decision", "decided": return .decisions
    case "next", "next actions", "next action", "todo", "todos": return .next
    default: return nil
    }
}

private func labelledCandidate(_ text: String) -> (section: CloseDaySection, item: String)? {
    let cleaned = cleanCandidate(text)
    let lower = cleaned.lowercased()
    let labels: [(String, CloseDaySection)] = [
        ("done:", .done),
        ("completed:", .done),
        ("complete:", .done),
        ("result:", .done),
        ("blocker:", .blockers),
        ("blockers:", .blockers),
        ("blocked:", .blockers),
        ("decision:", .decisions),
        ("decisions:", .decisions),
        ("decided:", .decisions),
        ("next:", .next),
        ("next action:", .next),
        ("todo:", .next)
    ]
    for (label, section) in labels where lower.hasPrefix(label) {
        let item = String(cleaned.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (section, item)
    }
    if lower.hasPrefix("[x]") {
        return (.done, String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.hasPrefix("[ ]") {
        return (.next, String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

private func isCandidateLine(_ text: String) -> Bool {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.hasPrefix("-") || cleaned.hasPrefix("*") || cleaned.hasPrefix("[x]") || cleaned.hasPrefix("[ ]")
}

private func cleanCandidate(_ text: String) -> String {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["- [x]", "* [x]", "- [X]", "* [X]", "- [ ]", "* [ ]", "-", "*"] {
        if cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }
    return cleaned
}

private func isValidDay(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    guard parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
    return parts.allSatisfy { part in part.allSatisfy { $0.isNumber } }
}

private func isValidProjectionSlug(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        let ch = Character(scalar)
        return scalar.isASCII && (ch.isLowercase || ch.isNumber || ch == "-" || ch == "/")
    }
}
