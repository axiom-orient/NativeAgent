import Foundation

public let collectedCaptureManifestVersion = "ask-web-capture.v1"

public struct CollectedCaptureFragment: Codable, Sendable, Equatable, ASKValidatable {
    public var fragmentID: String
    public var ordinal: Int
    public var text: String
    public var locator: ASKFields
    public var fingerprint: String?
    public var metadata: ASKFields

    public init(fragmentID: String, ordinal: Int, text: String, locator: ASKFields = [:], fingerprint: String? = nil, metadata: ASKFields = [:]) {
        self.fragmentID = fragmentID
        self.ordinal = ordinal
        self.text = text
        self.locator = locator
        self.fingerprint = fingerprint
        self.metadata = metadata
    }

    public func validate() throws {
        try requireNonEmpty("fragment_id", fragmentID)
        if ordinal < 0 { throw ASKError.validation("field `ordinal` must be >= 0") }
        try requireNonEmpty("text", text)
    }
}

public struct CollectedCaptureManifest: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var sourceID: String
    public var connector: String
    public var transport: String
    public var originalURL: String
    public var finalURL: String
    public var title: String
    public var observedAt: String
    public var capturedAt: String
    public var rawRelpath: String
    public var noteRelpath: String
    public var contentHash: String
    public var mimeType: String?
    public var language: String?
    public var tags: [String]
    public var metadata: ASKFields
    public var fragments: [CollectedCaptureFragment]

    public init(version: String = collectedCaptureManifestVersion, sourceID: String, connector: String, transport: String, originalURL: String, finalURL: String, title: String, observedAt: String, capturedAt: String, rawRelpath: String, noteRelpath: String, contentHash: String, mimeType: String?, language: String?, tags: [String], metadata: ASKFields = [:], fragments: [CollectedCaptureFragment] = []) {
        self.version = version
        self.sourceID = sourceID
        self.connector = connector
        self.transport = transport
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.title = title
        self.observedAt = observedAt
        self.capturedAt = capturedAt
        self.rawRelpath = rawRelpath
        self.noteRelpath = noteRelpath
        self.contentHash = contentHash
        self.mimeType = mimeType
        self.language = language
        self.tags = tags
        self.metadata = metadata
        self.fragments = fragments
    }

    public func validate() throws {
        try requireVersion(version, expected: collectedCaptureManifestVersion)
        try requirePathSafeID("source_id", sourceID)
        try requireNonEmpty("connector", connector)
        try requireNonEmpty("transport", transport)
        try requireNonEmpty("original_url", originalURL)
        try requireNonEmpty("final_url", finalURL)
        try requireNonEmpty("title", title)
        try requireTimestamp("observed_at", observedAt)
        try requireTimestamp("captured_at", capturedAt)
        try requireRelpath("raw_relpath", rawRelpath)
        // A capture is evidence, never a transport for journal/configuration
        // writes. Preserve custom layouts inside raw/, not arbitrary vault paths.
        guard rawRelpath.hasPrefix("raw/") else {
            throw ASKError.validation("capture raw_relpath must be inside raw/")
        }
        try requireRelpath("note_relpath", noteRelpath)
        try requireNonEmpty("content_hash", contentHash)
        try requireUniqueNonEmpty("tags", tags)
        try requireSortedUniqueOrdinals(fragments.map(\.ordinal))
        try fragments.forEach { try $0.validate() }
    }
}
