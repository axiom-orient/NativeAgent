import Foundation

public enum ASKEvidenceScope: String, Codable, CaseIterable, Sendable {
    case research
    case work
    case general
    case unknown
}

public enum ASKEvidenceKind: String, Codable, CaseIterable, Sendable {
    case source
    case log
    case worklog
    case decision
    case reference
    case report
    case docs
    case stage
    case unknown
}

public struct ASKEvidenceMetadata: Codable, Hashable, Sendable {
    public var sourceID: SourceID
    public var sourcePath: String?
    public var documentTitle: String
    public var scope: ASKEvidenceScope
    public var kind: ASKEvidenceKind
    public var topic: String?
    public var stage: String?
    public var status: String?
    public var updatedAt: String?
    public var tags: [String]
    public var sourceRefs: [String]

    public init(
        sourceID: SourceID,
        sourcePath: String?,
        documentTitle: String,
        scope: ASKEvidenceScope = .unknown,
        kind: ASKEvidenceKind = .unknown,
        topic: String? = nil,
        stage: String? = nil,
        status: String? = nil,
        updatedAt: String? = nil,
        tags: [String] = [],
        sourceRefs: [String] = []
    ) {
        self.sourceID = sourceID
        self.sourcePath = sourcePath
        self.documentTitle = documentTitle
        self.scope = scope
        self.kind = kind
        self.topic = topic
        self.stage = stage
        self.status = status
        self.updatedAt = updatedAt
        self.tags = tags
        self.sourceRefs = sourceRefs
    }
}
