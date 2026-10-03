import Foundation

public struct IngestEvidenceRequest: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var source: SourceReceipt
    public var fragments: [SourceFragment]
    public var domain: String
    public var requestedAt: String
    public var focusPrompt: String?

    public init(version: String, source: SourceReceipt, fragments: [SourceFragment], domain: String, requestedAt: String, focusPrompt: String?) {
        self.version = version
        self.source = source
        self.fragments = fragments
        self.domain = domain
        self.requestedAt = requestedAt
        self.focusPrompt = focusPrompt
    }

    public func validate() throws {
        try requireVersion(version, expected: ingestEvidenceRequestVersion)
        try source.validate()
        try requireSortedUniqueOrdinals(fragments.map(\.ordinal))
        var ids = Set<String>()
        for fragment in fragments {
            try fragment.validate()
            if fragment.sourceID != source.sourceID {
                throw ASKError.validation("fragment source_id must match source.source_id")
            }
            if !ids.insert(fragment.fragmentID).inserted {
                throw ASKError.validation("duplicate fragment_id in ingest request")
            }
        }
        try requireNonEmpty("domain", domain)
        try requireTimestamp("requested_at", requestedAt)
    }
}

public struct IngestEvidenceOutcome: Codable, Sendable, Equatable {
    public var patch: KnowledgePatchPlan
    public init(patch: KnowledgePatchPlan) { self.patch = patch }
}

public struct RegisterAuthorityRequest: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var record: AuthorityRecord
    public var requestedAt: String

    public init(version: String, record: AuthorityRecord, requestedAt: String) {
        self.version = version
        self.record = record
        self.requestedAt = requestedAt
    }

    public func validate() throws {
        try requireVersion(version, expected: registerAuthorityRequestVersion)
        try record.validate()
        try requireTimestamp("requested_at", requestedAt)
    }
}

public struct RegisterAuthorityOutcome: Codable, Sendable, Equatable {
    public var patch: KnowledgePatchPlan
    public init(patch: KnowledgePatchPlan) { self.patch = patch }
}

public struct RefreshProjectionRequest: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var requestedAt: String
    public var trigger: String
    public var proposedWrites: [ProjectionWrite]

    public init(version: String, requestedAt: String, trigger: String, proposedWrites: [ProjectionWrite]) {
        self.version = version
        self.requestedAt = requestedAt
        self.trigger = trigger
        self.proposedWrites = proposedWrites
    }

    public func validate() throws {
        try requireVersion(version, expected: refreshProjectionRequestVersion)
        try requireTimestamp("requested_at", requestedAt)
        try requireNonEmpty("trigger", trigger)
        var slugs = Set<String>()
        for write in proposedWrites {
            try write.validate()
            if !slugs.insert(write.slug).inserted {
                throw ASKError.validation("duplicate projection slug in refresh request")
            }
        }
    }
}

public struct RefreshProjectionOutcome: Codable, Sendable, Equatable {
    public var patch: KnowledgePatchPlan
    public init(patch: KnowledgePatchPlan) { self.patch = patch }
}

public struct PatchDecisionReceipt: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var patchID: String
    public var decision: PatchDecision
    public var decidedBy: String
    public var decidedAt: String
    public var reason: String
    public var selectedOptionID: String?

    public init(version: String, patchID: String, decision: PatchDecision, decidedBy: String, decidedAt: String, reason: String, selectedOptionID: String? = nil) {
        self.version = version
        self.patchID = patchID
        self.decision = decision
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.reason = reason
        self.selectedOptionID = selectedOptionID
    }

    public func validate() throws {
        try requireVersion(version, expected: patchDecisionReceiptVersion)
        try requirePathSafeID("patch_id", patchID)
        try requireNonEmpty("decided_by", decidedBy)
        try requireTimestamp("decided_at", decidedAt)
        try requireNonEmpty("reason", reason)
        if let selectedOptionID {
            try requireChoiceID("selected_option_id", selectedOptionID)
        }
    }
}

public struct SearchKnowledgeRequest: Codable, Sendable, Equatable {
    public var query: String
    public init(query: String) { self.query = query }
}

public struct ASKKnowledgeRequest: Codable, Sendable, Equatable {
    public var query: String
    public init(query: String) { self.query = query }
}

public struct LintKnowledgeRequest: Codable, Sendable, Equatable {
    public var scope: String
    public init(scope: String) { self.scope = scope }
}
