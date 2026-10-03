import Foundation
import KnowledgeCore
import KnowledgeRuntime

public actor ASKJSONToolExecutor {
    private let runtime: ASKRuntime

    public static var contract: ASKJSONBridgeContract {
        ASKJSONBridgeSchema.current
    }

    public init(runtime: ASKRuntime) {
        self.runtime = runtime
    }

    public init(root: URL) {
        self.runtime = ASKRuntime(root: root)
    }

    public init(root: String) {
        self.runtime = ASKRuntime(root: URL(fileURLWithPath: root, isDirectory: true))
    }

    public nonisolated func contract() -> ASKJSONBridgeContract {
        Self.contract
    }

    public func stateSummary() throws -> ASKStateSummary {
        try ASKStateSummary(snapshot: runtime.snapshot())
    }

    public func search(_ query: String, limit: Int = 8) throws -> SearchResult {
        try runtime.search(query, limit: limit)
    }

    public func readProjection(_ slug: String) throws -> ProjectionDocument? {
        try runtime.projectionDocument(slug: slug)
    }

    public func query(_ question: String, requestedAt: String, fileBackSlug: String? = nil) throws -> QueryResult {
        try runtime.query(question, requestedAt: requestedAt, fileBackSlug: fileBackSlug)
    }

    public func reviewQueue() throws -> ReviewQueueResult {
        try runtime.reviewQueue()
    }

    public func pendingPatches() throws -> [KnowledgePatchPlan] {
        try runtime.pendingPatchPlans()
    }

    public func readPatch(_ patchID: String) throws -> KnowledgePatchPlan? {
        try runtime.patchPlan(patchID: patchID)
    }

    public func lint() throws -> LintResult {
        try runtime.lint()
    }

    public func importCollected(_ manifestPath: URL) throws -> ASKImportedCapture {
        try runtime.importCollected(manifestPath)
    }

    public func planEvidenceIngest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome {
        try runtime.planEvidenceIngest(request)
    }

    public func verify(_ plan: KnowledgePatchPlan) throws -> VerificationReport {
        try runtime.verify(plan)
    }

    public func execute(tool: String, argsJSON: Data = Data("{}".utf8)) throws -> Data {
        try dispatch(tool: tool, argsJSON: argsJSON)
    }

    public func execute(tool: String, argumentsJSON: String = "{}") async throws -> String {
        let data = try execute(tool: tool, argsJSON: Data(argumentsJSON.utf8))
        return String(decoding: data, as: UTF8.self)
    }
}
