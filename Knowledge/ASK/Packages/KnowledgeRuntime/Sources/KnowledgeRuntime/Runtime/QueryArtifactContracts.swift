import Foundation
import KnowledgeCore

public let queryArtifactRequestVersion = "query_artifact_request.v1"

public struct QueryArtifactRequest: Codable, Equatable, Sendable {
    public var version: String
    public var question: String
    public var answerMarkdown: String
    public var projectionSlugs: [String]
    public var fileBackSlug: String
    public var requestedAt: String

    public init(
        version: String = queryArtifactRequestVersion,
        question: String,
        answerMarkdown: String,
        projectionSlugs: [String],
        fileBackSlug: String,
        requestedAt: String
    ) {
        self.version = version
        self.question = question
        self.answerMarkdown = answerMarkdown
        self.projectionSlugs = projectionSlugs
        self.fileBackSlug = fileBackSlug
        self.requestedAt = requestedAt
    }
}

extension ASKRuntime {
    public func planQueryArtifact(_ request: QueryArtifactRequest) throws -> KnowledgePatchPlan {
        guard request.version == queryArtifactRequestVersion else {
            throw ASKError.validation("unsupported query artifact request version `\(request.version)`")
        }

        let slugs = Array(Set(request.projectionSlugs)).sorted()
        guard !slugs.isEmpty else {
            throw ASKError.validation("query artifact planning requires at least one projection slug")
        }

        let store = try Vault(root: root).loadStoreFromJournal().store
        var sourceIDs: [String] = []
        var authorityIDs: [String] = []
        var claimIDs: [String] = []

        for slug in slugs {
            guard let latest = store.projections[slug]?.last else {
                throw ASKError.notFound("unknown projection slug `\(slug)`")
            }
            if latest.state == .stale || latest.state == .superseded {
                throw ASKError.validation("projection `\(slug)` is not visible")
            }
            sourceIDs.append(contentsOf: latest.document.metadata.sourceIDs)
            authorityIDs.append(contentsOf: latest.document.metadata.authorityIDs)
            claimIDs.append(contentsOf: latest.document.metadata.claimIDs)
        }

        let support = QuerySupportMaterial(
            answer: request.answerMarkdown,
            sourceIDs: Array(Set(sourceIDs)).sorted(),
            authorityIDs: Array(Set(authorityIDs)).sorted(),
            claimIDs: Array(Set(claimIDs)).sorted()
        )
        return try buildQueryArtifactPatch(
            question: request.question,
            requestedAt: request.requestedAt,
            fileBackSlug: request.fileBackSlug,
            support: support
        )
    }
}
