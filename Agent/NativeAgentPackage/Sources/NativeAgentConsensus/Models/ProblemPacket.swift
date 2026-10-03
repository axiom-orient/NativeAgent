import Foundation

public struct ProblemPacket: Codable, Sendable, Equatable {
    public let id: String?
    public let objective: String
    public let observedIssue: String
    public let candidate: String?
    public let constraints: [String]
    public let evidence: [EvidenceRef]
    public let primaryClass: String?
    public let tags: [String]
    public let facets: [String: String]
    public let metadata: [String: String]

    public init(
        id: String? = nil,
        objective: String,
        observedIssue: String,
        candidate: String? = nil,
        constraints: [String] = [],
        evidence: [EvidenceRef] = [],
        primaryClass: String? = nil,
        tags: [String] = [],
        facets: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.objective = objective
        self.observedIssue = observedIssue
        self.candidate = candidate
        self.constraints = constraints
        self.evidence = evidence
        self.primaryClass = primaryClass
        self.tags = tags
        self.facets = facets
        self.metadata = metadata
    }
}

public struct EvidenceRef: Codable, Sendable, Equatable, Hashable {
    public let id: String?
    public let kind: String?
    public let ref: String
    public let note: String?
    public let check: String?

    public init(
        id: String? = nil,
        kind: String? = nil,
        ref: String,
        note: String? = nil,
        check: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ref = ref
        self.note = note
        self.check = check
    }
}

public struct CaseQuery: Codable, Sendable, Equatable {
    public let text: String
    public let fingerprint: String?
    public let primaryClass: String?
    public let tags: [String]
    public let facets: [String: String]
    public let limit: Int?

    public init(
        text: String = "",
        fingerprint: String? = nil,
        primaryClass: String? = nil,
        tags: [String] = [],
        facets: [String: String] = [:],
        limit: Int? = nil
    ) {
        self.text = text
        self.fingerprint = fingerprint
        self.primaryClass = primaryClass
        self.tags = tags
        self.facets = facets
        self.limit = limit
    }
}
