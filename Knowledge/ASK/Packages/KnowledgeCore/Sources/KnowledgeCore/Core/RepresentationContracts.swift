import Foundation

public let representationRecordVersion = "ask-representation-record.v1"
public let representationTrailRequestVersion = "ask-representation-trail-request.v1"

public enum RepresentationKind: String, Codable, CaseIterable, Sendable {
    case ocrText = "ocr_text"
    case visionNotes = "vision_notes"
    case pageNotes = "page_notes"
    case metadataProfile = "metadata_profile"
}

public struct RepresentationRecord: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var sourceID: String
    public var kind: RepresentationKind
    public var sourceContentHash: String
    public var generatedAt: String
    public var generator: String
    public var bodyMD: String
    public var metadata: ASKFields

    public init(
        version: String = representationRecordVersion,
        sourceID: String,
        kind: RepresentationKind,
        sourceContentHash: String,
        generatedAt: String,
        generator: String,
        bodyMD: String,
        metadata: ASKFields = [:]
    ) {
        self.version = version
        self.sourceID = sourceID
        self.kind = kind
        self.sourceContentHash = sourceContentHash
        self.generatedAt = generatedAt
        self.generator = generator
        self.bodyMD = bodyMD
        self.metadata = metadata
    }

    public func validate() throws {
        try requireVersion(version, expected: representationRecordVersion)
        try requirePathSafeID("source_id", sourceID)
        try requireNonEmpty("source_content_hash", sourceContentHash)
        try requireTimestamp("generated_at", generatedAt)
        try requireNonEmpty("generator", generator)
        try requireNonEmpty("body_md", bodyMD)
    }
}

public struct RepresentationTrailRequest: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var sourceID: String
    public var sourceContentHash: String
    public var requiredKinds: [RepresentationKind]

    public init(
        version: String = representationTrailRequestVersion,
        sourceID: String,
        sourceContentHash: String,
        requiredKinds: [RepresentationKind]
    ) {
        self.version = version
        self.sourceID = sourceID
        self.sourceContentHash = sourceContentHash
        self.requiredKinds = requiredKinds
    }

    public func validate() throws {
        try requireVersion(version, expected: representationTrailRequestVersion)
        try requirePathSafeID("source_id", sourceID)
        try requireNonEmpty("source_content_hash", sourceContentHash)
        let rawKinds = requiredKinds.map(\.rawValue)
        try requireUniqueNonEmpty("required_kinds", rawKinds)
    }
}

public struct RepresentationLintFinding: Codable, Sendable, Equatable {
    public var kind: String
    public var severity: String
    public var item: String
    public var summary: String

    public init(kind: String, severity: String, item: String, summary: String) {
        self.kind = kind
        self.severity = severity
        self.item = item
        self.summary = summary
    }
}

public struct RepresentationLintReport: Codable, Sendable, Equatable {
    public var sourceID: String
    public var availableKinds: [RepresentationKind]
    public var findings: [RepresentationLintFinding]
    public var findingCount: Int { findings.count }

    public init(sourceID: String, availableKinds: [RepresentationKind], findings: [RepresentationLintFinding]) {
        self.sourceID = sourceID
        self.availableKinds = availableKinds
        self.findings = findings
    }
}
