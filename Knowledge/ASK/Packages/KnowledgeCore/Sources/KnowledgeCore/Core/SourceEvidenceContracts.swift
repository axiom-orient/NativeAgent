import Foundation

public struct SourceReceipt: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var sourceID: String
    public var connector: String
    public var sourceKind: SourceKind
    public var title: String
    public var observedAt: String
    public var capturedAt: String?
    public var canonicalURI: String
    public var contentHash: String
    public var rawRelpath: String
    public var mimeType: String?
    public var language: String?
    public var tags: [String]
    public var metadata: ASKFields

    public init(
        version: String,
        sourceID: String,
        connector: String,
        sourceKind: SourceKind,
        title: String,
        observedAt: String,
        capturedAt: String?,
        canonicalURI: String,
        contentHash: String,
        rawRelpath: String,
        mimeType: String?,
        language: String?,
        tags: [String],
        metadata: ASKFields = [:]
    ) {
        self.version = version
        self.sourceID = sourceID
        self.connector = connector
        self.sourceKind = sourceKind
        self.title = title
        self.observedAt = observedAt
        self.capturedAt = capturedAt
        self.canonicalURI = canonicalURI
        self.contentHash = contentHash
        self.rawRelpath = rawRelpath
        self.mimeType = mimeType
        self.language = language
        self.tags = tags
        self.metadata = metadata
    }

    public func validate() throws {
        try requireVersion(version, expected: sourceReceiptVersion)
        try requirePathSafeID("source_id", sourceID)
        try requireNonEmpty("connector", connector)
        try requireNonEmpty("title", title)
        try requireTimestamp("observed_at", observedAt)
        if let capturedAt { try requireTimestamp("captured_at", capturedAt) }
        try requireNonEmpty("canonical_uri", canonicalURI)
        try requireNonEmpty("content_hash", contentHash)
        try requireRelpath("raw_relpath", rawRelpath)
        try requireUniqueNonEmpty("tags", tags)
    }
}

public struct SourceFragment: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var fragmentID: String
    public var sourceID: String
    public var ordinal: Int
    public var locator: ASKFields
    public var text: String
    public var fingerprint: String?
    public var metadata: ASKFields

    public init(
        version: String,
        fragmentID: String,
        sourceID: String,
        ordinal: Int,
        locator: ASKFields,
        text: String,
        fingerprint: String?,
        metadata: ASKFields = [:]
    ) {
        self.version = version
        self.fragmentID = fragmentID
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.locator = locator
        self.text = text
        self.fingerprint = fingerprint
        self.metadata = metadata
    }

    public func validate() throws {
        try requireVersion(version, expected: sourceFragmentVersion)
        try requirePathSafeID("fragment_id", fragmentID)
        try requirePathSafeID("source_id", sourceID)
        if ordinal < 0 {
            throw ASKError.validation("field `ordinal` must be >= 0")
        }
        try requireNonEmpty("text", text)
    }
}

public struct ClaimRecord: Codable, Sendable, Equatable, ASKValidatable {
    public var claimID: String
    public var claimKind: ClaimKind
    public var claimMode: ClaimMode
    public var status: ClaimStatus
    public var subjectKind: String
    public var subjectID: String
    public var text: String
    public var authorityRecordID: String?
    public var sourceFragmentIDs: [String]
    public var confidence: Confidence

    public init(
        claimID: String,
        claimKind: ClaimKind,
        claimMode: ClaimMode,
        status: ClaimStatus,
        subjectKind: String,
        subjectID: String,
        text: String,
        authorityRecordID: String?,
        sourceFragmentIDs: [String],
        confidence: Confidence
    ) {
        self.claimID = claimID
        self.claimKind = claimKind
        self.claimMode = claimMode
        self.status = status
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.text = text
        self.authorityRecordID = authorityRecordID
        self.sourceFragmentIDs = sourceFragmentIDs
        self.confidence = confidence
    }

    public func validate() throws {
        try requirePathSafeID("claim_id", claimID)
        try requirePathSafeID("subject_kind", subjectKind)
        try requirePathSafeID("subject_id", subjectID)
        try requireNonEmpty("text", text)
        try requireUniqueNonEmpty("source_fragment_ids", sourceFragmentIDs)
        if claimKind == .projectionSynthesis && claimMode == .deterministic {
            throw ASKError.validation("projection synthesis cannot be deterministic")
        }
        if claimMode == .deterministic
            && isBlank(authorityRecordID)
            && sourceFragmentIDs.isEmpty {
            throw ASKError.validation("deterministic claim needs authority_record_id or source_fragment_ids")
        }
    }
}

public struct EvidenceRecord: Codable, Sendable, Equatable, ASKValidatable {
    public var evidenceID: String
    public var sourceID: String
    public var fragmentID: String
    public var excerpt: String

    public init(evidenceID: String, sourceID: String, fragmentID: String, excerpt: String) {
        self.evidenceID = evidenceID
        self.sourceID = sourceID
        self.fragmentID = fragmentID
        self.excerpt = excerpt
    }

    public func validate() throws {
        try requirePathSafeID("evidence_id", evidenceID)
        try requirePathSafeID("source_id", sourceID)
        try requirePathSafeID("fragment_id", fragmentID)
        try requireNonEmpty("excerpt", excerpt)
    }
}

public struct ClaimEvidence: Codable, Sendable, Equatable, ASKValidatable {
    public var claimID: String
    public var evidenceID: String
    public var supportKind: SupportKind

    public init(claimID: String, evidenceID: String, supportKind: SupportKind) {
        self.claimID = claimID
        self.evidenceID = evidenceID
        self.supportKind = supportKind
    }

    public func validate() throws {
        try requirePathSafeID("claim_id", claimID)
        try requirePathSafeID("evidence_id", evidenceID)
    }
}

public struct SearchDocRow: Codable, Sendable, Equatable, ASKValidatable {
    public var docID: String
    public var docKind: String
    public var subjectKind: String
    public var subjectID: String
    public var projectionSlug: String?
    public var title: String
    public var body: String
    public var metadata: ASKFields

    public init(docID: String, docKind: String, subjectKind: String, subjectID: String, projectionSlug: String?, title: String, body: String, metadata: ASKFields = [:]) {
        self.docID = docID
        self.docKind = docKind
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.projectionSlug = projectionSlug
        self.title = title
        self.body = body
        self.metadata = metadata
    }

    public func validate() throws {
        try requireNonEmpty("doc_id", docID)
        try requireNonEmpty("doc_kind", docKind)
        try requireNonEmpty("subject_kind", subjectKind)
        try requireNonEmpty("subject_id", subjectID)
        try requireNonEmpty("title", title)
        try requireNonEmpty("body", body)
    }
}
