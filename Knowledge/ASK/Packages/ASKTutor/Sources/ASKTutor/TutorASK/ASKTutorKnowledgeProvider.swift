import ASK
import Foundation
import KnowledgeRuntime

/// ASK-backed knowledge adapter used by ASKTutor. It does not own model or learner state.
struct ASKTutorKnowledgeProvider: TutorKnowledgeProvider {
    private let reader: any ASKKnowledgeReader

    init(configuration: ASKConfiguration) {
        self.reader = ASKRuntimeKnowledgeReader(root: configuration.resolvedVaultURL)
    }

    init(root: URL) {
        self.reader = ASKRuntimeKnowledgeReader(root: root)
    }

    init(rootPath: String) {
        self.reader = ASKRuntimeKnowledgeReader(rootPath: rootPath)
    }

    init(reader: any ASKKnowledgeReader) {
        self.reader = reader
    }

    func ensureKnowledgeBase() async throws {
        try reader.ensureKnowledgeBase()
    }

    func stateSummary() async throws -> TutorKnowledgeStateSummary {
        try ASKTutorASKMapper.stateSummary(reader.snapshot())
    }

    func projection(slug: String) async throws -> TutorProjectionSnapshot? {
        guard let document = try reader.projectionDocument(slug: slug) else {
            return nil
        }
        return ASKTutorASKMapper.projection(document)
    }

    func search(_ query: String, limit: Int) async throws -> [TutorEvidenceHit] {
        ASKTutorASKMapper.evidenceHits(try reader.search(query, limit: limit).hits)
    }

    func ground(question: String, requestedAt: String, fileBackSlug: String?) async throws -> TutorGrounding {
        ASKTutorASKMapper.grounding(
            try reader.query(question, requestedAt: requestedAt, fileBackSlug: fileBackSlug)
        )
    }

    func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot {
        ASKTutorASKMapper.knowledgeHealth(reviewQueue: try reader.reviewQueue(), lint: try reader.lint())
    }
}
