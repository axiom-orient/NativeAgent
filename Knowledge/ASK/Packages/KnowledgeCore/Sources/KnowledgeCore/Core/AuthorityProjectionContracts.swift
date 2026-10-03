import Foundation

public struct AuthorityRecord: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var recordID: String
    public var recordType: String
    public var subjectKind: String
    public var subjectID: String
    public var factScopeKey: String
    public var approvalState: AuthorityState
    public var valueFields: ASKFields
    public var effectiveFrom: String
    public var effectiveTo: String?
    public var approvedBy: String?
    public var supersedesID: String?

    public init(
        version: String,
        recordID: String,
        recordType: String,
        subjectKind: String,
        subjectID: String,
        factScopeKey: String,
        approvalState: AuthorityState,
        valueFields: ASKFields,
        effectiveFrom: String,
        effectiveTo: String?,
        approvedBy: String?,
        supersedesID: String?
    ) {
        self.version = version
        self.recordID = recordID
        self.recordType = recordType
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.factScopeKey = factScopeKey
        self.approvalState = approvalState
        self.valueFields = valueFields
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.approvedBy = approvedBy
        self.supersedesID = supersedesID
    }

    public func validate() throws {
        try requireVersion(version, expected: authorityRecordVersion)
        try requirePathSafeID("record_id", recordID)
        try requirePathSafeID("record_type", recordType)
        try requirePathSafeID("subject_kind", subjectKind)
        try requirePathSafeID("subject_id", subjectID)
        try requireNonEmpty("fact_scope_key", factScopeKey)
        try requireTimestamp("effective_from", effectiveFrom)
        if let effectiveTo {
            try requireTimestamp("effective_to", effectiveTo)
            if ASKTimestamp.isAtOrBefore(effectiveTo, effectiveFrom) {
                throw ASKError.validation("field `effective_to` must be later than `effective_from`")
            }
        }
        if approvalState == .approved && isBlank(approvedBy) {
            throw ASKError.validation("approved authority requires `approved_by`")
        }
        if valueFields.isEmpty {
            throw ASKError.validation("authority `value_fields` must not be empty")
        }
    }

    public func factScopeTuple() -> [String] {
        [subjectKind, subjectID, recordType, factScopeKey]
    }
}

public struct ProjectionMetadata: Codable, Sendable, Equatable, ASKValidatable {
    public var projectionKind: ProjectionKind
    public var projectionSpace: ProjectionSpace
    public var subjectKind: String
    public var subjectID: String
    public var authorityIDs: [String]
    public var sourceIDs: [String]
    /// Exact source revisions used to derive this projection, keyed by source ID.
    public var sourceVersionChecksums: [String: String]
    public var claimIDs: [String]
    public var historical: Bool
    public var approvalRequired: Bool

    public init(
        projectionKind: ProjectionKind,
        projectionSpace: ProjectionSpace,
        subjectKind: String,
        subjectID: String,
        authorityIDs: [String],
        sourceIDs: [String],
        sourceVersionChecksums: [String: String] = [:],
        claimIDs: [String],
        historical: Bool,
        approvalRequired: Bool
    ) {
        self.projectionKind = projectionKind
        self.projectionSpace = projectionSpace
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.authorityIDs = authorityIDs
        self.sourceIDs = sourceIDs
        self.sourceVersionChecksums = sourceVersionChecksums
        self.claimIDs = claimIDs
        self.historical = historical
        self.approvalRequired = approvalRequired
    }

    public func validate() throws {
        try requireNonEmpty("subject_kind", subjectKind)
        try requireNonEmpty("subject_id", subjectID)
        try requireUniqueNonEmpty("authority_ids", authorityIDs)
        try requireUniqueNonEmpty("source_ids", sourceIDs)
        let sourceSet = Set(sourceIDs)
        guard Set(sourceVersionChecksums.keys).isSubset(of: sourceSet) else {
            throw ASKError.validation("source_version_checksums keys must be present in source_ids")
        }
        for (sourceID, checksum) in sourceVersionChecksums {
            try requireNonEmpty("source_version_checksums[\(sourceID)]", checksum)
        }
        try requireUniqueNonEmpty("claim_ids", claimIDs)
        if projectionKind == .currentSnapshot && authorityIDs.isEmpty {
            throw ASKError.validation("current snapshot requires non-empty authority_ids")
        }
        if projectionSpace == .playbook && historical {
            throw ASKError.validation("playbook projection cannot be historical")
        }
        if projectionKind == .playbookEntry && projectionSpace != .playbook {
            throw ASKError.validation("playbook entry must live in playbook space")
        }
        if projectionKind == .casebookEntry && projectionSpace != .casebook {
            throw ASKError.validation("casebook entry must live in casebook space")
        }
    }
}

public struct ProjectionDocument: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var slug: String
    public var title: String
    public var bodyMD: String
    public var metadata: ProjectionMetadata
    public var generatedFromHash: String
    public var generatedAt: String

    public init(
        version: String,
        slug: String,
        title: String,
        bodyMD: String,
        metadata: ProjectionMetadata,
        generatedFromHash: String,
        generatedAt: String
    ) {
        self.version = version
        self.slug = slug
        self.title = title
        self.bodyMD = bodyMD
        self.metadata = metadata
        self.generatedFromHash = generatedFromHash
        self.generatedAt = generatedAt
    }

    public func validate() throws {
        try requireVersion(version, expected: projectionDocumentVersion)
        try requireSlug("slug", slug)
        try requireNonEmpty("title", title)
        try requireNonEmpty("body_md", bodyMD)
        try metadata.validate()
        try requireNonEmpty("generated_from_hash", generatedFromHash)
        try requireTimestamp("generated_at", generatedAt)
        if generatedFromHash != projectionDocumentHash(self) {
            throw ASKError.validation("generated_from_hash does not match projection content")
        }
    }
}

public func projectionDocumentHash(_ document: ProjectionDocument) -> String {
    var components = [
        document.slug,
        document.title,
        document.bodyMD,
        document.metadata.projectionKind.rawValue,
        document.metadata.projectionSpace.rawValue,
        document.metadata.subjectKind,
        document.metadata.subjectID,
        document.metadata.authorityIDs.joined(separator: ","),
        document.metadata.sourceIDs.joined(separator: ","),
    ]
    let versions = document.metadata.sourceVersionChecksums
    let encoded = versions.keys.sorted().map { key in
        "\(key)=\(versions[key] ?? "")"
    }.joined(separator: ",")
    components.append("source_versions:\(encoded)")
    components.append(contentsOf: [
        document.metadata.claimIDs.joined(separator: ","),
        document.metadata.historical ? "1" : "0",
        document.metadata.approvalRequired ? "1" : "0",
    ])
    return stableHash(components)
}

public struct ProjectionWritePrecondition: Codable, Sendable, Equatable, ASKValidatable {
    /// `nil` means the projection must not exist when the write is applied.
    /// A non-nil value is the expected `generatedFromHash` of the current projection.
    public var expectedBaseRevision: String?

    public init(expectedBaseRevision: String?) {
        self.expectedBaseRevision = expectedBaseRevision
    }

    public func validate() throws {
        if let expectedBaseRevision {
            try requireNonEmpty("expected_base_revision", expectedBaseRevision)
        }
    }
}

public struct ProjectionWrite: Codable, Sendable, Equatable, ASKValidatable {
    public var slug: String
    public var state: ProjectionState
    public var document: ProjectionDocument
    /// An absent precondition requests an unconditional write; workflows that
    /// require optimistic concurrency must supply their expected base.
    public var precondition: ProjectionWritePrecondition?

    public init(
        slug: String,
        state: ProjectionState,
        document: ProjectionDocument,
        precondition: ProjectionWritePrecondition? = nil
    ) {
        self.slug = slug
        self.state = state
        self.document = document
        self.precondition = precondition
    }

    public func validate() throws {
        try requireSlug("slug", slug)
        try document.validate()
        try precondition?.validate()
        if slug != document.slug {
            throw ASKError.validation("projection write slug must match document slug")
        }
    }
}

public struct ProjectionInvalidation: Codable, Sendable, Equatable, ASKValidatable {
    public var invalidationID: String
    public var slug: String
    public var reason: String
    public var triggeredByPatchID: String
    public var createdAt: String

    public init(invalidationID: String, slug: String, reason: String, triggeredByPatchID: String, createdAt: String) {
        self.invalidationID = invalidationID
        self.slug = slug
        self.reason = reason
        self.triggeredByPatchID = triggeredByPatchID
        self.createdAt = createdAt
    }

    public func validate() throws {
        try requirePathSafeID("invalidation_id", invalidationID)
        try requireSlug("slug", slug)
        try requireNonEmpty("reason", reason)
        try requireNonEmpty("triggered_by_patch_id", triggeredByPatchID)
        try requireTimestamp("created_at", createdAt)
    }
}
