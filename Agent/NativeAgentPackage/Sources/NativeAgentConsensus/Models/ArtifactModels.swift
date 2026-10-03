import Foundation

public struct Action: Codable, Sendable, Equatable, Hashable {
    public let label: String
    public let reason: String?
    public let owner: String?
    public let ref: String?
    public let precise: Bool

    public init(label: String, reason: String? = nil, owner: String? = nil, ref: String? = nil, precise: Bool = false) {
        self.label = label
        self.reason = reason
        self.owner = owner
        self.ref = ref
        self.precise = precise
    }
}

public struct Blocker: Codable, Sendable, Equatable, Hashable {
    public let label: String
    public let severity: String?
    public let reason: String?
    public let ref: String?

    public init(label: String, severity: String? = nil, reason: String? = nil, ref: String? = nil) {
        self.label = label
        self.severity = severity
        self.reason = reason
        self.ref = ref
    }
}

public struct Check: Codable, Sendable, Equatable, Hashable {
    public let label: String
    public let how: String?
    public let ref: String?

    public init(label: String, how: String? = nil, ref: String? = nil) {
        self.label = label
        self.how = how
        self.ref = ref
    }
}

public struct ProposalArtifact: Codable, Sendable, Equatable {
    public let summary: String
    public let plan: [Action]
    public let assumptions: [String]
    public let evidenceRefs: [String]

    public init(summary: String, plan: [Action] = [], assumptions: [String] = [], evidenceRefs: [String] = []) {
        self.summary = summary
        self.plan = plan
        self.assumptions = assumptions
        self.evidenceRefs = evidenceRefs
    }
}

public struct ReviewArtifact: Codable, Sendable, Equatable {
    public let summary: String
    public let verdict: ReviewVerdict
    public let requiredActions: [Action]
    public let blockers: [Blocker]
    public let checks: [Check]
    public let evidenceRefs: [String]

    public init(
        summary: String,
        verdict: ReviewVerdict,
        requiredActions: [Action] = [],
        blockers: [Blocker] = [],
        checks: [Check] = [],
        evidenceRefs: [String] = []
    ) {
        self.summary = summary
        self.verdict = verdict
        self.requiredActions = requiredActions
        self.blockers = blockers
        self.checks = checks
        self.evidenceRefs = evidenceRefs
    }
}

public struct ChallengeArtifact: Codable, Sendable, Equatable {
    public let summary: String
    public let verdict: ChallengeVerdict
    public let concerns: [Blocker]
    public let requiredActions: [Action]
    public let saferOption: String
    public let evidenceRefs: [String]

    public init(
        summary: String,
        verdict: ChallengeVerdict,
        concerns: [Blocker] = [],
        requiredActions: [Action] = [],
        saferOption: String = "",
        evidenceRefs: [String] = []
    ) {
        self.summary = summary
        self.verdict = verdict
        self.concerns = concerns
        self.requiredActions = requiredActions
        self.saferOption = saferOption
        self.evidenceRefs = evidenceRefs
    }
}

public struct RoundArtifacts: Codable, Sendable, Equatable {
    public let proposal: ProposalArtifact
    public let review: ReviewArtifact
    public let challenge: ChallengeArtifact

    public init(proposal: ProposalArtifact, review: ReviewArtifact, challenge: ChallengeArtifact) {
        self.proposal = proposal
        self.review = review
        self.challenge = challenge
    }
}

public struct DeltaPacket: Codable, Sendable, Equatable {
    public let previousDecision: Decision?
    public let candidateSummary: String?
    public let requiredActions: [Action]
    public let blockers: [Blocker]
    public let checks: [Check]

    public init(
        previousDecision: Decision? = nil,
        candidateSummary: String? = nil,
        requiredActions: [Action] = [],
        blockers: [Blocker] = [],
        checks: [Check] = []
    ) {
        self.previousDecision = previousDecision
        self.candidateSummary = candidateSummary
        self.requiredActions = requiredActions
        self.blockers = blockers
        self.checks = checks
    }
}
