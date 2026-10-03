import Foundation

public struct ReviewOption: Codable, Sendable, Equatable, ASKValidatable {
    public var optionID: String
    public var label: String
    public var summary: String
    public var effect: String
    public var details: ASKFields

    public init(optionID: String, label: String, summary: String, effect: String, details: ASKFields = [:]) {
        self.optionID = optionID
        self.label = label
        self.summary = summary
        self.effect = effect
        self.details = details
    }

    public func validate() throws {
        try requireChoiceID("option_id", optionID)
        try requireNonEmpty("label", label)
        try requireNonEmpty("summary", summary)
        try requireNonEmpty("effect", effect)
    }
}

public struct ReviewItem: Codable, Sendable, Equatable, ASKValidatable {
    public var reviewID: String
    public var reviewKind: ReviewKind
    public var status: ReviewStatus
    public var severity: Severity
    public var subjectKind: String
    public var subjectID: String
    public var summary: String
    public var createdAt: String
    public var details: ASKFields
    public var requiresChoice: Bool
    public var options: [ReviewOption]

    public init(
        reviewID: String,
        reviewKind: ReviewKind,
        status: ReviewStatus,
        severity: Severity,
        subjectKind: String,
        subjectID: String,
        summary: String,
        createdAt: String,
        details: ASKFields = [:],
        requiresChoice: Bool = false,
        options: [ReviewOption] = []
    ) {
        self.reviewID = reviewID
        self.reviewKind = reviewKind
        self.status = status
        self.severity = severity
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.summary = summary
        self.createdAt = createdAt
        self.details = details
        self.requiresChoice = requiresChoice
        self.options = options
    }

    public func validate() throws {
        try requirePathSafeID("review_id", reviewID)
        try requireNonEmpty("subject_kind", subjectKind)
        try requireNonEmpty("subject_id", subjectID)
        try requireNonEmpty("summary", summary)
        try requireTimestamp("created_at", createdAt)
        try options.forEach { try $0.validate() }
        if requiresChoice {
            if options.count != 2 {
                throw ASKError.validation("choice review requires exactly two options")
            }
            if options.map(\.optionID) != [PatchChoiceID.approve.rawValue, PatchChoiceID.reject.rawValue] {
                throw ASKError.validation("choice review options must be ordered as A then B")
            }
        } else if !options.isEmpty {
            throw ASKError.validation("non-choice review must not carry options")
        }
    }
}

public struct VerificationReport: Codable, Sendable, Equatable, ASKValidatable {
    public var patchID: String
    public var riskLevel: RiskLevel
    public var disposition: PublishDisposition
    public var reasons: [String]
    public var requiresHumanApproval: Bool
    public var requiresHumanChoice: Bool

    public init(
        patchID: String,
        riskLevel: RiskLevel,
        disposition: PublishDisposition,
        reasons: [String],
        requiresHumanApproval: Bool,
        requiresHumanChoice: Bool = false
    ) {
        self.patchID = patchID
        self.riskLevel = riskLevel
        self.disposition = disposition
        self.reasons = reasons
        self.requiresHumanApproval = requiresHumanApproval
        self.requiresHumanChoice = requiresHumanChoice
    }

    public func validate() throws {
        try requirePathSafeID("patch_id", patchID)
        try requireUniqueNonEmpty("reasons", reasons)
    }
}

public struct OperationLogEntry: Codable, Sendable, Equatable, ASKValidatable {
    public var logID: String
    public var occurredAt: String
    public var opKind: String
    public var summary: String

    public init(logID: String, occurredAt: String, opKind: String, summary: String) {
        self.logID = logID
        self.occurredAt = occurredAt
        self.opKind = opKind
        self.summary = summary
    }

    public func validate() throws {
        try requirePathSafeID("log_id", logID)
        try requireTimestamp("occurred_at", occurredAt)
        try requireNonEmpty("op_kind", opKind)
        try requireNonEmpty("summary", summary)
    }

    /// Canonical log order: when it happened, then log ID as a stable tie-break.
    public static func canonicallyOrdered(_ entries: some Sequence<OperationLogEntry>) -> [OperationLogEntry] {
        entries
            .map { (ASKTimestamp.OrderKey($0.occurredAt), $0) }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.logID < rhs.1.logID
            }
            .map(\.1)
    }
}

public struct KnowledgePatchPlan: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var patchID: String
    public var patchKind: PatchKind
    public var generatedAt: String
    public var sourceReceipts: [SourceReceipt]
    public var sourceFragments: [SourceFragment]
    public var authorityRecords: [AuthorityRecord]
    public var projectionInvalidations: [ProjectionInvalidation]
    public var projectionWrites: [ProjectionWrite]
    public var claims: [ClaimRecord]
    public var evidence: [EvidenceRecord]
    public var claimEvidence: [ClaimEvidence]
    public var reviewItems: [ReviewItem]
    public var warnings: [String]
    public var verification: VerificationReport
    public var operations: [OperationLogEntry]

    public init(
        version: String,
        patchID: String,
        patchKind: PatchKind,
        generatedAt: String,
        sourceReceipts: [SourceReceipt],
        sourceFragments: [SourceFragment],
        authorityRecords: [AuthorityRecord],
        projectionInvalidations: [ProjectionInvalidation],
        projectionWrites: [ProjectionWrite],
        claims: [ClaimRecord],
        evidence: [EvidenceRecord],
        claimEvidence: [ClaimEvidence],
        reviewItems: [ReviewItem],
        warnings: [String],
        verification: VerificationReport,
        operations: [OperationLogEntry]
    ) {
        self.version = version
        self.patchID = patchID
        self.patchKind = patchKind
        self.generatedAt = generatedAt
        self.sourceReceipts = sourceReceipts
        self.sourceFragments = sourceFragments
        self.authorityRecords = authorityRecords
        self.projectionInvalidations = projectionInvalidations
        self.projectionWrites = projectionWrites
        self.claims = claims
        self.evidence = evidence
        self.claimEvidence = claimEvidence
        self.reviewItems = reviewItems
        self.warnings = warnings
        self.verification = verification
        self.operations = operations
    }

    public func validate() throws {
        try requireVersion(version, expected: knowledgePatchPlanVersion)
        try requirePathSafeID("patch_id", patchID)
        try requireTimestamp("generated_at", generatedAt)
        try verification.validate()
        if verification.patchID != patchID {
            throw ASKError.validation("verification patch_id must match plan patch_id")
        }
        try requireUniqueNonEmpty("warnings", warnings)

        var seen = Set<String>()
        for source in sourceReceipts {
            try source.validate()
            if !seen.insert(source.sourceID).inserted {
                throw ASKError.validation("duplicate source_id in patch")
            }
        }

        try requireSortedUniqueOrdinals(sourceFragments.map(\.ordinal))
        seen.removeAll(keepingCapacity: true)
        for fragment in sourceFragments {
            try fragment.validate()
            if !seen.insert(fragment.fragmentID).inserted {
                throw ASKError.validation("duplicate fragment_id in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for record in authorityRecords {
            try record.validate()
            if !seen.insert(record.recordID).inserted {
                throw ASKError.validation("duplicate authority record_id in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for invalidation in projectionInvalidations {
            try invalidation.validate()
            if !seen.insert(invalidation.invalidationID).inserted {
                throw ASKError.validation("duplicate invalidation_id in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for write in projectionWrites {
            try write.validate()
            if !seen.insert(write.slug).inserted {
                throw ASKError.validation("duplicate projection slug in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for claim in claims {
            try claim.validate()
            if !seen.insert(claim.claimID).inserted {
                throw ASKError.validation("duplicate claim_id in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for evidenceRecord in evidence {
            try evidenceRecord.validate()
            if !seen.insert(evidenceRecord.evidenceID).inserted {
                throw ASKError.validation("duplicate evidence_id in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for review in reviewItems {
            try review.validate()
            if !seen.insert(review.reviewID).inserted {
                throw ASKError.validation("duplicate review_id in patch")
            }
        }

        seen.removeAll(keepingCapacity: true)
        for operation in operations {
            try operation.validate()
            if !seen.insert(operation.logID).inserted {
                throw ASKError.validation("duplicate log_id in patch")
            }
        }

        let sourceIDs = Set(sourceReceipts.map(\.sourceID))
        let fragmentIDs = Set(sourceFragments.map(\.fragmentID))
        let authorityIDs = Set(authorityRecords.map(\.recordID))
        let claimIDs = Set(claims.map(\.claimID))
        let evidenceIDs = Set(evidence.map(\.evidenceID))

        for fragment in sourceFragments where !sourceIDs.contains(fragment.sourceID) {
            throw ASKError.validation("source fragment references unknown source_id in patch")
        }
        for evidenceRecord in evidence {
            if !sourceIDs.contains(evidenceRecord.sourceID) {
                throw ASKError.validation("evidence references unknown source_id in patch")
            }
            if !fragmentIDs.contains(evidenceRecord.fragmentID) {
                throw ASKError.validation("evidence references unknown fragment_id in patch")
            }
        }
        for claim in claims {
            if let authorityRecordID = claim.authorityRecordID, !authorityIDs.contains(authorityRecordID) {
                throw ASKError.validation("claim references unknown authority_record_id in patch")
            }
            for fragmentID in claim.sourceFragmentIDs where !fragmentIDs.contains(fragmentID) {
                throw ASKError.validation("claim references unknown source_fragment_id in patch")
            }
        }
        for relation in claimEvidence {
            try relation.validate()
            if !claimIDs.contains(relation.claimID) {
                throw ASKError.validation("claim_evidence references unknown claim_id in patch")
            }
            if !evidenceIDs.contains(relation.evidenceID) {
                throw ASKError.validation("claim_evidence references unknown evidence_id in patch")
            }
        }
        if patchKind == .evidenceIngest && !projectionWrites.isEmpty {
            throw ASKError.validation("evidence ingest patch must not contain projection writes")
        }
    }
}
