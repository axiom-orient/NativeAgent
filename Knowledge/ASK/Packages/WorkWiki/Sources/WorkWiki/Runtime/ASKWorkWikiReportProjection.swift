import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public enum ASKWorkWikiReportProjection {
    public static func validate(_ request: ASKWorkWikiReportRequest) throws {
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKError.validation("work-wiki report title must not be empty")
        }
        guard !request.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKError.validation("work-wiki report query must not be empty")
        }
        guard ASKTimestamp.isValidRFC3339(request.requestedAt) else {
            throw ASKError.validation("work-wiki report requested_at must be valid RFC3339")
        }
        guard request.maxEvidenceBytes > 0 else {
            throw ASKError.validation("work-wiki report maxEvidenceBytes must be positive")
        }
        if let slug = request.slug, !isValidProjectionSlug(slug) {
            throw ASKError.validation("work-wiki report slug must contain only [a-z0-9-/]")
        }
        if let subjectID = request.subjectID,
           subjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ASKError.validation("work-wiki report subjectID must not be empty when provided")
        }
    }

    static func projectionSlug(for request: ASKWorkWikiReportRequest) -> String {
        request.slug ?? "work/reports/\(slugify(request.title))"
    }

    public static func makeProjectionWrite(
        request: ASKWorkWikiReportRequest,
        evidencePack: ASKEvidencePack,
        expectedBaseRevision: String?
    ) throws -> ProjectionWrite {
        let slug = projectionSlug(for: request)
        return try makeEvidenceProjectionWrite(
            slug: slug, title: request.title, subjectID: request.subjectID,
            requestedAt: request.requestedAt, evidencePack: evidencePack,
            expectedBaseRevision: expectedBaseRevision
        ) { sourceIDs in
            renderBody(request: request, evidencePack: evidencePack, sourceIDs: sourceIDs)
        }
    }

    // Both producers must supply the exact revisions consumed by approval.
    // Rendering is different; evidence identity and write preconditions are not.
    static func makeEvidenceProjectionWrite(
        slug: String,
        title: String,
        subjectID: String?,
        requestedAt: String,
        evidencePack: ASKEvidencePack,
        expectedBaseRevision: String?,
        renderBody: ([String]) -> String
    ) throws -> ProjectionWrite {
        let sourceIDs = Array(Set(evidencePack.hits.map { $0.sourceID.rawValue })).sorted()
        var sourceVersionChecksums: [String: String] = [:]
        for hit in evidencePack.hits {
            guard let checksum = hit.sourceVersionChecksum else {
                throw ASKError.validation("work-wiki report evidence is missing exact source revisions")
            }
            let sourceID = hit.sourceID.rawValue
            if let existing = sourceVersionChecksums[sourceID], existing != checksum {
                throw ASKError.validation("work-wiki report evidence contains conflicting source revisions for `\(sourceID)`")
            }
            sourceVersionChecksums[sourceID] = checksum
        }
        guard sourceVersionChecksums.count == sourceIDs.count else {
            throw ASKError.validation("work-wiki report evidence is missing exact source revisions")
        }
        let metadata = ProjectionMetadata(
            projectionKind: .queryArtifact,
            projectionSpace: .wiki,
            subjectKind: ASKWorkWikiProjectionSubjectKind.workReport,
            subjectID: subjectID ?? slug,
            authorityIDs: [],
            sourceIDs: sourceIDs,
            sourceVersionChecksums: sourceVersionChecksums,
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        let body = renderBody(sourceIDs)
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: slug,
            title: title,
            bodyMD: body,
            metadata: metadata,
            generatedFromHash: "pending",
            generatedAt: requestedAt
        )
        document.generatedFromHash = projectionDocumentHash(document)
        let write = ProjectionWrite(
            slug: slug,
            state: .draft,
            document: document,
            precondition: ProjectionWritePrecondition(expectedBaseRevision: expectedBaseRevision)
        )
        try write.validate()
        return write
    }

    private static func renderBody(request: ASKWorkWikiReportRequest, evidencePack: ASKEvidencePack, sourceIDs: [String]) -> String {
        let freshnessSummary = evidencePack.hits.reduce(into: [String: Int]()) { counts, hit in
            counts[hit.freshness.rawValue, default: 0] += 1
        }
        let freshnessLine = freshnessSummary.keys.sorted().map { key in
            "\(key)=\(freshnessSummary[key] ?? 0)"
        }.joined(separator: ", ")
        let sources = sourceIDs.map { "- \($0)" }.joined(separator: "\n")
        return """
        # \(request.title)

        ## Query
        \(request.queryText)

        ## Evidence Summary
        - hit_count: \(evidencePack.hits.count)
        - source_count: \(sourceIDs.count)
        - freshness: \(freshnessLine)
        - truncated: \(evidencePack.truncated)

        ## Source IDs
        \(sources)

        ## Evidence Pack
        \(evidencePack.renderedMarkdown)
        """
    }
}

private func slugify(_ value: String) -> String {
    let normalized = value.precomposedStringWithCanonicalMapping.lowercased()
    let chars = normalized.unicodeScalars.map { scalar -> Character in
        let ch = Character(scalar)
        if scalar.isASCII && (ch.isLowercase || ch.isNumber) { return ch }
        return "-"
    }
    let readable = String(chars)
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
    let digest = StableDigest.sha256Hex(Data(normalized.utf8))
    if readable.isEmpty { return "report-\(digest.prefix(12))" }
    let asciiOnly = normalized.unicodeScalars.allSatisfy(\.isASCII)
    return asciiOnly ? readable : "\(readable)-\(digest.prefix(12))"
}

private func isValidProjectionSlug(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        let ch = Character(scalar)
        return scalar.isASCII && (ch.isLowercase || ch.isNumber || ch == "-" || ch == "/")
    }
}
