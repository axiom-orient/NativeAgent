import Foundation
import PageIndex

public enum ASKEvidenceFreshnessStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case stale
    case missing
    case unknown
}

public struct ASKEvidenceFilter: Sendable, Equatable {
    public var scopes: Set<ASKEvidenceScope>
    public var kinds: Set<ASKEvidenceKind>
    public var topics: Set<String>
    public var stages: Set<String>
    public var statuses: Set<String>
    public var sourceIDs: Set<SourceID>
    public var freshness: Set<ASKEvidenceFreshnessStatus>

    public init(
        scopes: Set<ASKEvidenceScope> = [],
        kinds: Set<ASKEvidenceKind> = [],
        topics: Set<String> = [],
        stages: Set<String> = [],
        statuses: Set<String> = [],
        sourceIDs: Set<SourceID> = [],
        freshness: Set<ASKEvidenceFreshnessStatus> = []
    ) {
        self.scopes = scopes
        self.kinds = kinds
        self.topics = topics
        self.stages = stages
        self.statuses = statuses
        self.sourceIDs = sourceIDs
        self.freshness = freshness
    }

    public static let none = ASKEvidenceFilter()
}

public struct ASKEvidenceQuery: Sendable, Equatable {
    public var text: String
    public var filter: ASKEvidenceFilter
    public var limit: Int
    public var excerptLineLimit: Int

    public init(text: String, filter: ASKEvidenceFilter = .none, limit: Int = 100, excerptLineLimit: Int = 12) {
        self.text = text
        self.filter = filter
        self.limit = limit
        self.excerptLineLimit = excerptLineLimit
    }
}

public struct ASKEvidenceHit: Codable, Equatable, Sendable {
    public var sourceID: SourceID
    public var nodeID: String
    public var title: String
    public var sectionPath: [String]
    public var range: SourceRange
    public var excerpt: String
    public var score: Double
    public var metadata: ASKEvidenceMetadata
    public var freshness: ASKEvidenceFreshnessStatus
    /// Checksum of the exact indexed source revision that produced this hit.
    public var sourceVersionChecksum: String?

    public init(
        sourceID: SourceID,
        nodeID: String,
        title: String,
        sectionPath: [String],
        range: SourceRange,
        excerpt: String,
        score: Double,
        metadata: ASKEvidenceMetadata,
        freshness: ASKEvidenceFreshnessStatus,
        sourceVersionChecksum: String? = nil
    ) {
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.title = title
        self.sectionPath = sectionPath
        self.range = range
        self.excerpt = excerpt
        self.score = score
        self.metadata = metadata
        self.freshness = freshness
        self.sourceVersionChecksum = sourceVersionChecksum
    }
}

public struct ASKEvidencePackRequest: Sendable, Equatable {
    public var query: ASKEvidenceQuery
    public var maxBytes: Int
    public var includeStale: Bool

    public static let defaultMaxBytes = 262_144

    public init(query: ASKEvidenceQuery, maxBytes: Int = ASKEvidencePackRequest.defaultMaxBytes, includeStale: Bool = false) {
        self.query = query
        self.maxBytes = maxBytes
        self.includeStale = includeStale
    }
}

public struct ASKEvidencePack: Codable, Equatable, Sendable {
    public var queryText: String
    public var hits: [ASKEvidenceHit]
    public var renderedMarkdown: String
    public var maxBytes: Int
    public var truncated: Bool

    public init(queryText: String, hits: [ASKEvidenceHit], renderedMarkdown: String, maxBytes: Int, truncated: Bool) {
        self.queryText = queryText
        self.hits = hits
        self.renderedMarkdown = renderedMarkdown
        self.maxBytes = maxBytes
        self.truncated = truncated
    }
}

public struct ASKEvidenceDocumentStatus: Codable, Equatable, Sendable {
    public var sourceID: SourceID
    public var sourcePath: String?
    public var freshness: ASKEvidenceFreshnessStatus
    public var storedChecksum: String
    public var currentChecksum: String?

    public init(sourceID: SourceID, sourcePath: String?, freshness: ASKEvidenceFreshnessStatus, storedChecksum: String, currentChecksum: String?) {
        self.sourceID = sourceID
        self.sourcePath = sourcePath
        self.freshness = freshness
        self.storedChecksum = storedChecksum
        self.currentChecksum = currentChecksum
    }
}
