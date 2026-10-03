import Foundation

public struct CollectedFragment: Codable, Sendable, Equatable, ASKValidatable {
    public var fragmentID: String
    public var ordinal: Int
    public var locator: ASKFields
    public var text: String
    public var fingerprint: String?
    public var metadata: ASKFields

    public init(fragmentID: String, ordinal: Int, locator: ASKFields, text: String, fingerprint: String?, metadata: ASKFields = [:]) {
        self.fragmentID = fragmentID
        self.ordinal = ordinal
        self.locator = locator
        self.text = text
        self.fingerprint = fingerprint
        self.metadata = metadata
    }

    public func validate() throws {
        try requireNonEmpty("fragment_id", fragmentID)
        if ordinal < 0 {
            throw ASKError.validation("field `ordinal` must be >= 0")
        }
        try requireNonEmpty("text", text)
    }
}

public struct CollectedSource: Codable, Sendable, Equatable, ASKValidatable {
    public var sourceID: String
    public var connector: String
    public var sourceKind: SourceKind
    public var title: String
    public var observedAt: String
    public var capturedAt: String?
    public var rawRelpath: String
    public var contentHash: String
    public var mimeType: String?
    public var language: String?
    public var tags: [String]
    public var metadata: ASKFields
    public var fragments: [CollectedFragment]

    public init(
        sourceID: String,
        connector: String,
        sourceKind: SourceKind,
        title: String,
        observedAt: String,
        capturedAt: String?,
        rawRelpath: String,
        contentHash: String,
        mimeType: String?,
        language: String?,
        tags: [String],
        metadata: ASKFields = [:],
        fragments: [CollectedFragment] = []
    ) {
        self.sourceID = sourceID
        self.connector = connector
        self.sourceKind = sourceKind
        self.title = title
        self.observedAt = observedAt
        self.capturedAt = capturedAt
        self.rawRelpath = rawRelpath
        self.contentHash = contentHash
        self.mimeType = mimeType
        self.language = language
        self.tags = tags
        self.metadata = metadata
        self.fragments = fragments
    }

    public func validate() throws {
        try requirePathSafeID("source_id", sourceID)
        try requireNonEmpty("connector", connector)
        try requireNonEmpty("title", title)
        try requireNonEmpty("observed_at", observedAt)
        try requireRelpath("raw_relpath", rawRelpath)
        try requireNonEmpty("content_hash", contentHash)
        try requireUniqueNonEmpty("tags", tags)
        var ordinals = Set<Int>()
        for fragment in fragments {
            try fragment.validate()
            if !ordinals.insert(fragment.ordinal).inserted {
                throw ASKError.validation("fragment ordinals must be unique")
            }
        }
    }
}

extension Array where Element == CollectedFragment {
    func sortedByOrdinal() -> [CollectedFragment] {
        sorted { ($0.ordinal, $0.fragmentID) < ($1.ordinal, $1.fragmentID) }
    }
}
