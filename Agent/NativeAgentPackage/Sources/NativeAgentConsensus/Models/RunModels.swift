import Foundation

public struct RoundInput: Codable, Sendable, Equatable {
    public let problem: ProblemPacket
    public let round: Int
    public let similarCases: [CaseCard]
    public let delta: DeltaPacket?

    public init(problem: ProblemPacket, round: Int, similarCases: [CaseCard] = [], delta: DeltaPacket? = nil) {
        self.problem = problem
        self.round = round
        self.similarCases = similarCases
        self.delta = delta
    }
}

public struct Consensus: Codable, Sendable, Equatable {
    public let decision: Decision
    public let summary: String
    public let reasons: [String]
    public let requiredActions: [Action]
    public let blockers: [Blocker]
    public let checks: [Check]
    public let selectedPlan: [Action]
    public let saferOption: String
    public let sourceRound: Int
    public let finalizedAt: Date?

    public init(
        decision: Decision,
        summary: String = "",
        reasons: [String] = [],
        requiredActions: [Action] = [],
        blockers: [Blocker] = [],
        checks: [Check] = [],
        selectedPlan: [Action] = [],
        saferOption: String = "",
        sourceRound: Int,
        finalizedAt: Date? = nil
    ) {
        self.decision = decision
        self.summary = summary
        self.reasons = reasons
        self.requiredActions = requiredActions
        self.blockers = blockers
        self.checks = checks
        self.selectedPlan = selectedPlan
        self.saferOption = saferOption
        self.sourceRound = sourceRound
        self.finalizedAt = finalizedAt
    }
}

public struct BACRoundResult: Codable, Sendable, Equatable {
    public let number: Int
    public let input: RoundInput
    public let artifacts: RoundArtifacts
    public let consensus: Consensus

    public init(number: Int, input: RoundInput, artifacts: RoundArtifacts, consensus: Consensus) {
        self.number = number
        self.input = input
        self.artifacts = artifacts
        self.consensus = consensus
    }
}

public struct BACResult: Codable, Sendable, Equatable {
    public let runID: String
    public let engine: String
    public let startedAt: Date
    public let finishedAt: Date
    public let problem: ProblemPacket
    public let similarCases: [CaseCard]
    public let rounds: [BACRoundResult]
    public let final: Consensus

    public init(
        runID: String,
        engine: String,
        startedAt: Date,
        finishedAt: Date,
        problem: ProblemPacket,
        similarCases: [CaseCard] = [],
        rounds: [BACRoundResult] = [],
        final: Consensus
    ) {
        self.runID = runID
        self.engine = engine
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.problem = problem
        self.similarCases = similarCases
        self.rounds = rounds
        self.final = final
    }
}
