import Foundation
import KnowledgeCore
import KnowledgeRuntime

extension ASKIOSFMFKernel {
    @discardableResult
    public func ensureVault() throws -> URL {
        try runtime.ensureVault()
    }

    public func stateSummary() throws -> ASKStateSummary {
        try runtime.ensureVault()
        return ASKStateSummary(snapshot: try runtime.snapshot())
    }

    public func projectionDocument(slug: String) throws -> ProjectionDocument? {
        try runtime.projectionDocument(slug: slug)
    }

    public func search(_ query: String, limit: Int = 8) throws -> SearchResult {
        try runtime.search(query, limit: limit)
    }

    public func query(_ question: String, requestedAt: String, fileBackSlug: String? = nil) throws -> QueryResult {
        try runtime.query(question, requestedAt: requestedAt, fileBackSlug: fileBackSlug)
    }

    public func reviewQueue() throws -> ReviewQueueResult {
        try runtime.reviewQueue()
    }

    public func lint() throws -> LintResult {
        try runtime.lint()
    }
}
