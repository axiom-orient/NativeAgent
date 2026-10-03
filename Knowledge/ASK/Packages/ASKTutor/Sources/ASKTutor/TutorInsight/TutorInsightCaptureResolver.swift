import Foundation
import KnowledgeCore
import KnowledgeRuntime

struct TutorInsightCaptureResolver: Sendable {
    let knowledgeReader: (any ASKKnowledgeReader)?

    func validateTimestamp(_ value: String) throws {
        if ASKTimestamp.parse(value) == nil {
            throw ASKProductIntegrationError.invalidTutorInsightTimestamp(value)
        }
    }

    func projectionSlugs(from evidence: [TutorInsightEvidence], fallback: String?) -> [String] {
        Self.uniqueStrings(evidence.compactMap(\.projectionSlug) + [fallback].compactMap { $0 })
    }

    func resolveSourceIDs(for projectionSlug: String?, evidence: [TutorInsightEvidence]) throws -> [String] {
        let evidenceIDs = Self.uniqueStrings(evidence.flatMap(\.askSourceIDs))
        guard let projectionSlug, let projection = try knowledgeReader?.projectionDocument(slug: projectionSlug) else {
            return evidenceIDs
        }
        return Self.uniqueStrings(projection.metadata.sourceIDs + evidenceIDs)
    }

    func uniqueEvidence(_ values: [TutorInsightEvidence]) -> [TutorInsightEvidence] {
        var seen = Set<TutorInsightEvidence>()
        var result: [TutorInsightEvidence] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    static func makeEvidence(_ citation: TutorCitation) -> TutorInsightEvidence {
        TutorInsightEvidence(
            kind: .citation,
            docID: citation.docID,
            title: citation.title,
            projectionSlug: normalizedProjectionSlug(citation.projectionSlug),
            askSourceIDs: [],
            snippet: nil,
            subjectKind: nil,
            subjectID: nil,
            metadata: [:]
        )
    }

    static func makeEvidence(_ hit: TutorEvidenceHit) -> TutorInsightEvidence {
        TutorInsightEvidence(
            kind: .searchHit,
            docID: hit.docID,
            title: hit.title,
            projectionSlug: normalizedProjectionSlug(hit.projectionSlug),
            askSourceIDs: parseASKSourceIDs(hit.metadata["source_ids"]),
            snippet: hit.snippet,
            subjectKind: hit.subjectKind,
            subjectID: hit.subjectID,
            metadata: hit.metadata
        )
    }

    static func makeEvidence(practiceSet: TutorPracticeSet) -> [TutorInsightEvidence] {
        let searchEvidence = practiceSet.evidence.map(Self.makeEvidence)
        let citationEvidence = practiceSet.questions.flatMap { question in
            question.citations.map(Self.makeEvidence)
        }
        return searchEvidence + citationEvidence
    }

    private static func normalizedProjectionSlug(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func parseASKSourceIDs(_ rawValue: String?) -> [String] {
        guard let rawValue else { return [] }
        return uniqueStrings(rawValue.split(separator: ",").map(String.init))
    }
}
