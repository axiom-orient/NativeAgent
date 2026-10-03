import Foundation

protocol TutorKnowledgeProvider: Sendable {
    func ensureKnowledgeBase() async throws
    func stateSummary() async throws -> TutorKnowledgeStateSummary
    func projection(slug: String) async throws -> TutorProjectionSnapshot?
    func search(_ query: String, limit: Int) async throws -> [TutorEvidenceHit]
    func ground(question: String, requestedAt: String, fileBackSlug: String?) async throws -> TutorGrounding
    func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot
}
