import Foundation

public let decisionMemoryRecordVersion = "ask-decision-memory-record.v2"
public let decisionMemoryTransitionVersion = "ask-decision-memory-transition.v2"

/// Storage lifetime. This is deliberately independent from the reasoning and
/// control loop: a tier says where a fact is retained, never what an agent may
/// do with it.
public enum MemoryTier: String, Codable, CaseIterable, Sendable {
    case stim
    case mtem
    case ltsm
}

public enum MemoryRecordKind: String, Codable, CaseIterable, Sendable {
    case observation
    case hypothesis
    case commitment
    case constraint
    case procedure
    case preference
}

public enum MemoryEvidenceKind: String, Codable, CaseIterable, Sendable {
    case vaultEvidence
    case pageIndexAnchor
    case capturedToolOutput
    case humanApproval
}

public enum MemoryEvidenceFreshness: String, Codable, CaseIterable, Sendable {
    case fresh
    case stale
    case unknown
}

/// Exact source coordinates without importing an indexing or I/O package.
/// The root adapter resolves these values; they are not a freshness certificate.
public struct MemoryExactSourceAnchor: Codable, Sendable, Equatable, ASKValidatable {
    public var sourceVersionChecksum: String
    public var coordinateSpace: String
    public var rangeStart: Int
    public var rangeEnd: Int
    public var contentSHA256: String

    // CanonicalJSON normalizes snake-case words, preserving only its established
    // acronym vocabulary. Use an unambiguous wire name for this new value.
    private enum CodingKeys: String, CodingKey {
        case sourceVersionChecksum, coordinateSpace, rangeStart, rangeEnd
        case contentSHA256 = "contentDigest"
    }

    public init(sourceVersionChecksum: String, coordinateSpace: String,
                rangeStart: Int, rangeEnd: Int, contentSHA256: String) {
        self.sourceVersionChecksum = sourceVersionChecksum
        self.coordinateSpace = coordinateSpace
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.contentSHA256 = contentSHA256
    }

    public func validate() throws {
        try requireNonEmpty("source_version_checksum", sourceVersionChecksum)
        guard ["line", "page"].contains(coordinateSpace),
              rangeStart > 0, rangeEnd >= rangeStart, rangeEnd < Int.max,
              contentSHA256.utf8.count == 64,
              contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ASKError.validation("invalid exact memory source anchor")
        }
    }
}

/// A provenance locator that does not import PageIndex or the runtime package.
/// The owning adapter verifies that the referenced source/node still exists
/// before supplying a `fresh` reference to a verification transition.
public struct MemoryEvidenceRef: Codable, Sendable, Equatable, ASKValidatable {
    public var evidenceID: String
    public var kind: MemoryEvidenceKind
    public var freshness: MemoryEvidenceFreshness
    public var sourceID: String?
    public var fragmentID: String?
    public var nodeID: String?
    public var captureReceiptID: String?
    public var exactAnchor: MemoryExactSourceAnchor?

    public init(
        evidenceID: String,
        kind: MemoryEvidenceKind,
        freshness: MemoryEvidenceFreshness,
        sourceID: String? = nil,
        fragmentID: String? = nil,
        nodeID: String? = nil,
        captureReceiptID: String? = nil,
        exactAnchor: MemoryExactSourceAnchor? = nil
    ) {
        self.evidenceID = evidenceID
        self.kind = kind
        self.freshness = freshness
        self.sourceID = sourceID
        self.fragmentID = fragmentID
        self.nodeID = nodeID
        self.captureReceiptID = captureReceiptID
        self.exactAnchor = exactAnchor
    }

    public func validate() throws {
        try requirePathSafeID("evidence_id", evidenceID)
        if let exactAnchor {
            guard kind == .pageIndexAnchor else {
                throw ASKError.validation("exact source anchor requires page-index evidence")
            }
            try exactAnchor.validate()
        }
        switch kind {
        case .vaultEvidence:
            try requireOptionalPathSafeID("source_id", sourceID)
            try requireOptionalPathSafeID("fragment_id", fragmentID)
            guard sourceID != nil || fragmentID != nil else {
                throw ASKError.validation("vault evidence requires source_id or fragment_id")
            }
            try requireAbsent("node_id", nodeID)
            try requireAbsent("capture_receipt_id", captureReceiptID)
        case .pageIndexAnchor:
            try requireOptionalPathSafeID("source_id", sourceID)
            try requireOptionalPathSafeID("node_id", nodeID)
            guard sourceID != nil, nodeID != nil, exactAnchor != nil else {
                throw ASKError.validation("page-index anchor requires source_id, node_id and exact_anchor")
            }
            try requireAbsent("fragment_id", fragmentID)
            try requireAbsent("capture_receipt_id", captureReceiptID)
        case .capturedToolOutput, .humanApproval:
            try requireOptionalPathSafeID("capture_receipt_id", captureReceiptID)
            guard captureReceiptID != nil else {
                throw ASKError.validation("\(kind.rawValue) requires capture_receipt_id")
            }
            try requireAbsent("source_id", sourceID)
            try requireAbsent("fragment_id", fragmentID)
            try requireAbsent("node_id", nodeID)
        }
    }
}

public struct MemorySubject: Codable, Sendable, Equatable, ASKValidatable {
    public var kind: String
    public var subjectID: String

    public init(kind: String, subjectID: String) {
        self.kind = kind
        self.subjectID = subjectID
    }

    public func validate() throws {
        try requirePathSafeID("subject_kind", kind)
        try requirePathSafeID("subject_id", subjectID)
    }
}

/// Explicit routing facts supplied by a workflow. Scope does not use fuzzy
/// semantic matching, which keeps memory selection deterministic and auditable.
public struct MemoryScope: Codable, Sendable, Equatable, ASKValidatable {
    public var workspaceID: String
    public var projectIDs: [String]
    public var pathPrefixes: [String]
    public var capabilityTags: [String]
    public var riskTags: [String]
    public var consequenceTags: [String]

    public init(
        workspaceID: String,
        projectIDs: [String] = [],
        pathPrefixes: [String] = [],
        capabilityTags: [String] = [],
        riskTags: [String] = [],
        consequenceTags: [String] = []
    ) {
        self.workspaceID = workspaceID
        self.projectIDs = projectIDs
        self.pathPrefixes = pathPrefixes
        self.capabilityTags = capabilityTags
        self.riskTags = riskTags
        self.consequenceTags = consequenceTags
    }

    public func validate() throws {
        try requirePathSafeID("workspace_id", workspaceID)
        try requireOrderedUniquePathSafeIDs("project_ids", projectIDs)
        try requireOrderedUniqueRelativePaths("path_prefixes", pathPrefixes)
        try requireOrderedUniquePathSafeIDs("capability_tags", capabilityTags)
        try requireOrderedUniquePathSafeIDs("risk_tags", riskTags)
        try requireOrderedUniquePathSafeIDs("consequence_tags", consequenceTags)
    }
}

/// Immutable observation/hypothesis/statement. Its lifecycle state is derived
/// solely from appended transitions; it is never rewritten in place.
public struct MemoryRecord: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var recordID: String
    public var initialTier: MemoryTier
    public var kind: MemoryRecordKind
    public var subject: MemorySubject
    public var scope: MemoryScope
    public var taskID: String?
    public var statement: String
    public var priority: Int
    public var blocking: Bool
    public var createdAt: String
    public var expiresAt: String?
    public var authorityID: String?
    public var evidenceRefs: [MemoryEvidenceRef]

    public init(
        version: String = decisionMemoryRecordVersion,
        recordID: String,
        initialTier: MemoryTier = .stim,
        kind: MemoryRecordKind,
        subject: MemorySubject,
        scope: MemoryScope,
        taskID: String? = nil,
        statement: String,
        priority: Int = 50,
        blocking: Bool = false,
        createdAt: String,
        expiresAt: String? = nil,
        authorityID: String? = nil,
        evidenceRefs: [MemoryEvidenceRef] = []
    ) {
        self.version = version
        self.recordID = recordID
        self.initialTier = initialTier
        self.kind = kind
        self.subject = subject
        self.scope = scope
        self.taskID = taskID
        self.statement = statement
        self.priority = priority
        self.blocking = blocking
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.authorityID = authorityID
        self.evidenceRefs = evidenceRefs
    }

    public func validate() throws {
        guard version == decisionMemoryRecordVersion else {
            throw ASKError.validation("unsupported decision-memory record version: \(version)")
        }
        try requirePathSafeID("record_id", recordID)
        try subject.validate()
        try scope.validate()
        if let taskID {
            try requirePathSafeID("task_id", taskID)
        }
        try requireNonEmpty("statement", statement)
        guard (0 ... 100).contains(priority) else {
            throw ASKError.validation("priority must be between 0 and 100")
        }
        try requireTimestamp("created_at", createdAt)
        if let expiresAt {
            try requireTimestamp("expires_at", expiresAt)
            guard ASKTimestamp.isBefore(createdAt, expiresAt) else {
                throw ASKError.validation("expires_at must be later than created_at")
            }
        }
        if let authorityID {
            try requirePathSafeID("authority_id", authorityID)
        }
        if initialTier != .stim {
            throw ASKError.validation("records must enter decision memory through stim")
        }
        if blocking && kind != .constraint {
            throw ASKError.validation("only constraint records may be blocking")
        }
        try requireUniqueEvidenceRefs(evidenceRefs)
    }
}

public enum MemoryTransitionKind: String, Codable, CaseIterable, Sendable {
    case verify
    case promote
    case supersede
    case retract
    case expire
}

/// Immutable state transition. `promote` never creates a new fact: it only
/// changes the retention tier of a record that a separate verify transition has
/// already established.
public struct MemoryTransition: Codable, Sendable, Equatable, ASKValidatable {
    public var version: String
    public var transitionID: String
    public var recordID: String
    public var kind: MemoryTransitionKind
    public var occurredAt: String
    public var actorID: String
    public var reason: String
    public var targetTier: MemoryTier?
    public var replacementRecordID: String?
    public var evidenceRefs: [MemoryEvidenceRef]

    public init(
        version: String = decisionMemoryTransitionVersion,
        transitionID: String,
        recordID: String,
        kind: MemoryTransitionKind,
        occurredAt: String,
        actorID: String,
        reason: String,
        targetTier: MemoryTier? = nil,
        replacementRecordID: String? = nil,
        evidenceRefs: [MemoryEvidenceRef] = []
    ) {
        self.version = version
        self.transitionID = transitionID
        self.recordID = recordID
        self.kind = kind
        self.occurredAt = occurredAt
        self.actorID = actorID
        self.reason = reason
        self.targetTier = targetTier
        self.replacementRecordID = replacementRecordID
        self.evidenceRefs = evidenceRefs
    }

    public func validate() throws {
        guard version == decisionMemoryTransitionVersion else {
            throw ASKError.validation("unsupported decision-memory transition version: \(version)")
        }
        try requirePathSafeID("transition_id", transitionID)
        try requirePathSafeID("record_id", recordID)
        try requireTimestamp("occurred_at", occurredAt)
        try requirePathSafeID("actor_id", actorID)
        try requireNonEmpty("reason", reason)
        try requireUniqueEvidenceRefs(evidenceRefs)

        switch kind {
        case .verify:
            guard targetTier == nil, replacementRecordID == nil else {
                throw ASKError.validation("verify transition cannot carry a target tier or replacement")
            }
            guard evidenceRefs.contains(where: { $0.freshness == .fresh }) else {
                throw ASKError.validation("verification requires at least one fresh evidence reference")
            }
        case .promote:
            guard let targetTier, targetTier != .stim else {
                throw ASKError.validation("promotion requires mtem or ltsm target tier")
            }
            guard replacementRecordID == nil, evidenceRefs.isEmpty else {
                throw ASKError.validation("promotion carries no replacement or evidence payload")
            }
        case .supersede:
            guard targetTier == nil, evidenceRefs.isEmpty else {
                throw ASKError.validation("supersession carries no target tier or evidence payload")
            }
            guard let replacementRecordID else {
                throw ASKError.validation("supersession requires replacement_record_id")
            }
            try requirePathSafeID("replacement_record_id", replacementRecordID)
        case .retract, .expire:
            guard targetTier == nil, replacementRecordID == nil, evidenceRefs.isEmpty else {
                throw ASKError.validation("\(kind.rawValue) transition cannot carry target, replacement, or evidence")
            }
        }
    }
}

public enum MemoryVerificationState: String, Codable, Sendable {
    case proposed
    case verified
}

public enum MemoryDisposition: String, Codable, Sendable {
    case active
    case superseded
    case retracted
    case expired
}

public struct MemoryRecordState: Codable, Sendable, Equatable {
    public var record: MemoryRecord
    public var tier: MemoryTier
    public var verification: MemoryVerificationState
    public var disposition: MemoryDisposition
    public var effectiveFrom: String
    public var effectiveTo: String?
    public var verifiedAt: String?
    public var evidenceRefs: [MemoryEvidenceRef]

    public var isActive: Bool { disposition == .active }
}

public struct MemoryLifecycleSnapshot: Codable, Sendable, Equatable {
    public var states: [MemoryRecordState]

    public init(states: [MemoryRecordState]) {
        self.states = states
    }

    public func state(recordID: String) -> MemoryRecordState? {
        states.first { $0.record.recordID == recordID }
    }
}

/// Explicit input to deterministic memory routing. It is supplied by the host
/// workflow and never inferred from an embedding or an LLM completion.
public struct TaskFrame: Codable, Sendable, Equatable, ASKValidatable {
    public var taskID: String
    public var workspaceID: String
    public var projectIDs: [String]
    public var paths: [String]
    public var capabilityTags: [String]
    public var riskTags: [String]
    public var consequenceTags: [String]
    public var requestedAt: String

    public init(
        taskID: String,
        workspaceID: String,
        projectIDs: [String] = [],
        paths: [String] = [],
        capabilityTags: [String] = [],
        riskTags: [String] = [],
        consequenceTags: [String] = [],
        requestedAt: String
    ) {
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.projectIDs = projectIDs
        self.paths = paths
        self.capabilityTags = capabilityTags
        self.riskTags = riskTags
        self.consequenceTags = consequenceTags
        self.requestedAt = requestedAt
    }

    public func validate() throws {
        try requirePathSafeID("task_id", taskID)
        try requirePathSafeID("workspace_id", workspaceID)
        try requireOrderedUniquePathSafeIDs("project_ids", projectIDs)
        try requireOrderedUniqueRelativePaths("paths", paths)
        try requireOrderedUniquePathSafeIDs("capability_tags", capabilityTags)
        try requireOrderedUniquePathSafeIDs("risk_tags", riskTags)
        try requireOrderedUniquePathSafeIDs("consequence_tags", consequenceTags)
        try requireTimestamp("requested_at", requestedAt)
    }
}

public struct ContextBudget: Codable, Sendable, Equatable, ASKValidatable {
    public var blockingLTSMTokens: Int
    public var ltsmTokens: Int
    public var mtemTokens: Int
    public var stimTokens: Int
    public var uncertaintyTokens: Int
    public var totalTokens: Int

    public init(
        blockingLTSMTokens: Int = 300,
        ltsmTokens: Int = 300,
        mtemTokens: Int = 500,
        stimTokens: Int = 300,
        uncertaintyTokens: Int = 100,
        totalTokens: Int = 1_200
    ) {
        self.blockingLTSMTokens = blockingLTSMTokens
        self.ltsmTokens = ltsmTokens
        self.mtemTokens = mtemTokens
        self.stimTokens = stimTokens
        self.uncertaintyTokens = uncertaintyTokens
        self.totalTokens = totalTokens
    }

    public func validate() throws {
        let values = [blockingLTSMTokens, ltsmTokens, mtemTokens, stimTokens, uncertaintyTokens, totalTokens]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ASKError.validation("context token budgets must be non-negative")
        }
        guard blockingLTSMTokens <= ltsmTokens else {
            throw ASKError.validation("blocking_ltsm_tokens must not exceed ltsm_tokens")
        }
        guard totalTokens >= ltsmTokens + mtemTokens + stimTokens + uncertaintyTokens else {
            throw ASKError.validation("total_tokens must cover all context segments")
        }
    }
}

public enum ContextOmissionReason: String, Codable, Sendable {
    case budget
    case inactive
    case unverified
    case staleEvidence
    case outOfScope
}

public struct OmissionDiagnostic: Codable, Sendable, Equatable {
    public var recordID: String
    public var reason: ContextOmissionReason
    public var evidenceID: String?
    public var detail: String?

    public init(recordID: String, reason: ContextOmissionReason, evidenceID: String? = nil, detail: String? = nil) {
        self.recordID = recordID
        self.reason = reason
        self.evidenceID = evidenceID
        self.detail = detail
    }
}

public struct ContextRecord: Codable, Sendable, Equatable {
    public var recordID: String
    public var tier: MemoryTier
    public var kind: MemoryRecordKind
    public var verification: MemoryVerificationState
    public var statement: String
    public var priority: Int
    public var blocking: Bool
    public var evidenceRefs: [MemoryEvidenceRef]

    public init(
        recordID: String,
        tier: MemoryTier,
        kind: MemoryRecordKind,
        verification: MemoryVerificationState,
        statement: String,
        priority: Int,
        blocking: Bool,
        evidenceRefs: [MemoryEvidenceRef]
    ) {
        self.recordID = recordID
        self.tier = tier
        self.kind = kind
        self.verification = verification
        self.statement = statement
        self.priority = priority
        self.blocking = blocking
        self.evidenceRefs = evidenceRefs
    }
}

public struct ContextBundle: Codable, Sendable, Equatable {
    public var taskID: String
    public var records: [ContextRecord]
    public var markdown: String
    public var tokenCount: Int
    public var omitted: [OmissionDiagnostic]
    public var generation: String

    public init(
        taskID: String,
        records: [ContextRecord],
        markdown: String,
        tokenCount: Int,
        omitted: [OmissionDiagnostic],
        generation: String
    ) {
        self.taskID = taskID
        self.records = records
        self.markdown = markdown
        self.tokenCount = tokenCount
        self.omitted = omitted
        self.generation = generation
    }
}

public enum InterventionKind: String, Codable, Sendable {
    case silence
    case remind
    case requireVerification
    case block
}

/// A non-acting control output. The receiving workflow owns whether and how it
/// changes execution; this contract intentionally has no effect closure, tool,
/// command, or mutable state capability.
public struct InterventionDecision: Codable, Sendable, Equatable {
    public var kind: InterventionKind
    public var recordIDs: [String]
    public var reason: String

    public init(kind: InterventionKind, recordIDs: [String] = [], reason: String = "") {
        self.kind = kind
        self.recordIDs = recordIDs
        self.reason = reason
    }
}

/// Pure lifecycle reducer. It validates all temporal and tier-transition
/// invariants before returning a deterministic snapshot, so journal replay and
/// tests share exactly the same meaning.
public enum DecisionMemoryReducer {
    public static func replay(
        records: [MemoryRecord],
        transitions: [MemoryTransition],
        asOf: String
    ) throws -> MemoryLifecycleSnapshot {
        try requireTimestamp("as_of", asOf)
        var states: [String: MemoryRecordState] = [:]
        for record in records.sorted(by: { $0.recordID < $1.recordID }) {
            try record.validate()
            guard states[record.recordID] == nil else {
                throw ASKError.validation("duplicate decision-memory record_id: \(record.recordID)")
            }
            states[record.recordID] = MemoryRecordState(
                record: record,
                tier: record.initialTier,
                verification: .proposed,
                disposition: .active,
                effectiveFrom: record.createdAt,
                effectiveTo: nil,
                verifiedAt: nil,
                evidenceRefs: record.evidenceRefs
            )
        }

        var seenTransitionIDs = Set<String>()
        let orderedTransitions = transitions.sorted(by: canonicalOrder)
        for transition in orderedTransitions {
            try transition.validate()
            guard seenTransitionIDs.insert(transition.transitionID).inserted else {
                throw ASKError.validation("duplicate decision-memory transition_id: \(transition.transitionID)")
            }
            guard var state = states[transition.recordID] else {
                throw ASKError.validation("transition references unknown record_id: \(transition.recordID)")
            }
            guard ASKTimestamp.isAtOrBefore(state.record.createdAt, transition.occurredAt) else {
                throw ASKError.validation("transition occurs before record creation: \(transition.transitionID)")
            }
            guard state.disposition == .active else {
                throw ASKError.validation("transition targets inactive record: \(transition.recordID)")
            }

            switch transition.kind {
            case .verify:
                guard state.verification == .proposed else {
                    throw ASKError.validation("record may be verified only once: \(transition.recordID)")
                }
                state.verification = .verified
                state.verifiedAt = transition.occurredAt
                state.evidenceRefs += transition.evidenceRefs
            case .promote:
                guard state.verification == .verified else {
                    throw ASKError.validation("promotion requires a prior verification: \(transition.recordID)")
                }
                guard let targetTier = transition.targetTier else {
                    throw ASKError.validation("promotion target is missing: \(transition.transitionID)")
                }
                if targetTier == .ltsm {
                    guard state.tier == .mtem else {
                        throw ASKError.validation("ltsm promotion requires prior mtem membership: \(transition.recordID)")
                    }
                    guard state.record.authorityID != nil else {
                        throw ASKError.validation("ltsm promotion requires authority_id: \(transition.recordID)")
                    }
                }
                guard state.tier != targetTier else {
                    throw ASKError.validation("promotion target already active: \(transition.recordID)")
                }
                state.tier = targetTier
            case .supersede:
                guard let replacementRecordID = transition.replacementRecordID,
                      replacementRecordID != transition.recordID,
                      states[replacementRecordID] != nil
                else {
                    throw ASKError.validation("supersession requires a distinct existing replacement record")
                }
                state.disposition = .superseded
                state.effectiveTo = transition.occurredAt
            case .retract:
                state.disposition = .retracted
                state.effectiveTo = transition.occurredAt
            case .expire:
                state.disposition = .expired
                state.effectiveTo = transition.occurredAt
            }
            states[transition.recordID] = state
        }

        for (recordID, var state) in states {
            if state.disposition == .active,
               let expiresAt = state.record.expiresAt,
               ASKTimestamp.isAtOrBefore(expiresAt, asOf) {
                state.disposition = .expired
                state.effectiveTo = expiresAt
                states[recordID] = state
            }
        }

        return MemoryLifecycleSnapshot(
            states: states.values.sorted { $0.record.recordID < $1.record.recordID }
        )
    }

    private static func canonicalOrder(_ lhs: MemoryTransition, _ rhs: MemoryTransition) -> Bool {
        let left = ASKTimestamp.OrderKey(lhs.occurredAt)
        let right = ASKTimestamp.OrderKey(rhs.occurredAt)
        if left != right { return left < right }
        return lhs.transitionID < rhs.transitionID
    }
}

private func requireOptionalPathSafeID(_ field: String, _ value: String?) throws {
    if let value {
        try requirePathSafeID(field, value)
    }
}

private func requireAbsent(_ field: String, _ value: String?) throws {
    if value != nil {
        throw ASKError.validation("field `\(field)` is not valid for this evidence kind")
    }
}

private func requireOrderedUniquePathSafeIDs(_ field: String, _ values: [String]) throws {
    var previous: String?
    for value in values {
        try requirePathSafeID(field, value)
        if let previous, previous >= value {
            throw ASKError.validation("field `\(field)` must be sorted and unique")
        }
        previous = value
    }
}

private func requireOrderedUniqueRelativePaths(_ field: String, _ values: [String]) throws {
    var previous: String?
    for value in values {
        try requireRelpath(field, value)
        if let previous, previous >= value {
            throw ASKError.validation("field `\(field)` must be sorted and unique")
        }
        previous = value
    }
}

private func requireUniqueEvidenceRefs(_ evidenceRefs: [MemoryEvidenceRef]) throws {
    var seen = Set<String>()
    for evidenceRef in evidenceRefs {
        try evidenceRef.validate()
        guard seen.insert(evidenceRef.evidenceID).inserted else {
            throw ASKError.validation("duplicate decision-memory evidence_id: \(evidenceRef.evidenceID)")
        }
    }
}
