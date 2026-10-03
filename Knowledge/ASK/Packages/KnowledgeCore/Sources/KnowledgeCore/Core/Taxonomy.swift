public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case file
    case url
    case text
    case note
    case conversation
    case other
}

public enum PatchKind: String, Codable, CaseIterable, Sendable {
    case evidenceIngest = "evidence_ingest"
    case authorityRegister = "authority_register"
    case projectionRefresh = "projection_refresh"
}

public enum AuthorityState: String, Codable, CaseIterable, Sendable {
    case draft
    case approved
    case superseded
    case rejected
}

public enum ProjectionKind: String, Codable, CaseIterable, Sendable {
    case currentSnapshot = "current_snapshot"
    case historicalNarrative = "historical_narrative"
    case sourceSummary = "source_summary"
    case entityOverview = "entity_overview"
    case topicOverview = "topic_overview"
    case playbookEntry = "playbook_entry"
    case casebookEntry = "casebook_entry"
    case queryArtifact = "query_artifact"
}

public enum ProjectionSpace: String, Codable, CaseIterable, Sendable {
    case wiki
    case playbook
    case casebook
}

public enum ProjectionState: String, Codable, CaseIterable, Sendable {
    case draft
    case review
    case accepted
    case stale
    case superseded
}

public enum ClaimKind: String, Codable, CaseIterable, Sendable {
    case extracted
    case authorityDerived = "authority_derived"
    case projectionSynthesis = "projection_synthesis"
    case openQuestion = "open_question"
}

public enum ClaimMode: String, Codable, CaseIterable, Sendable {
    case deterministic
    case nondeterministic
}

public enum ClaimStatus: String, Codable, CaseIterable, Sendable {
    case supported
    case provisional
    case contested
    case superseded
}

public enum Confidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public enum SupportKind: String, Codable, CaseIterable, Sendable {
    case supports
    case contradicts
    case context
}

public enum Severity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public enum ReviewKind: String, Codable, CaseIterable, Sendable {
    case lowConfidence = "low_confidence"
    case contradiction
    case missingEvidence = "missing_evidence"
    case invalidAuthorityInterval = "invalid_authority_interval"
    case historicalRewriteBlocked = "historical_rewrite_blocked"
    case verificationBlocked = "verification_blocked"
    case playbookPromotionBlocked = "playbook_promotion_blocked"
    case ambiguousAuthorityChange = "ambiguous_authority_change"
    case ambiguousVersionUpdate = "ambiguous_version_update"
    case ambiguousCompatibilityUpdate = "ambiguous_compatibility_update"
    case ambiguousGuidanceUpdate = "ambiguous_guidance_update"
}

public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case approved
    case rejected
    case deferred
}

public enum PatchDecision: String, Codable, CaseIterable, Sendable {
    case approved
    case rejected
}

public enum PatchChoiceID: String, Codable, CaseIterable, Sendable, Equatable {
    case approve = "A"
    case reject = "B"

    public init(validating value: String, field: String) throws {
        guard let choice = PatchChoiceID(rawValue: value.uppercased()) else {
            throw ASKError.validation("field `\(field)` must be one of A or B")
        }
        self = choice
    }

    public var decision: PatchDecision {
        switch self {
        case .approve: return .approved
        case .reject: return .rejected
        }
    }
}

public enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public enum PublishDisposition: String, Codable, CaseIterable, Sendable {
    case autoPublish = "auto_publish"
    case needsReview = "needs_review"
    case draftOnly = "draft_only"
}
