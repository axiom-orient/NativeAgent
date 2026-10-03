import Foundation

public enum ScriptedError: Error, Equatable {
    case missingRound(actor: String, round: Int)
}

public struct ScriptedConstructor: Constructor, Sendable {
    public let rounds: [ProposalArtifact]
    public let delayNanoseconds: UInt64

    public init(rounds: [ProposalArtifact], delayNanoseconds: UInt64 = 0) {
        self.rounds = rounds
        self.delayNanoseconds = delayNanoseconds
    }

    public func propose(input: RoundInput) async throws -> ProposalArtifact {
        try await ScriptedRoundResolver.sleepIfNeeded(delayNanoseconds)
        return try ScriptedRoundResolver.value(round: input.round, from: rounds, actor: "constructor")
    }
}

public struct ScriptedVerifier: Verifier, Sendable {
    public let rounds: [ReviewArtifact]
    public let delayNanoseconds: UInt64

    public init(rounds: [ReviewArtifact], delayNanoseconds: UInt64 = 0) {
        self.rounds = rounds
        self.delayNanoseconds = delayNanoseconds
    }

    public func review(input: RoundInput) async throws -> ReviewArtifact {
        try await ScriptedRoundResolver.sleepIfNeeded(delayNanoseconds)
        return try ScriptedRoundResolver.value(round: input.round, from: rounds, actor: "verifier")
    }
}

public struct ScriptedChallenger: Challenger, Sendable {
    public let rounds: [ChallengeArtifact]
    public let delayNanoseconds: UInt64

    public init(rounds: [ChallengeArtifact], delayNanoseconds: UInt64 = 0) {
        self.rounds = rounds
        self.delayNanoseconds = delayNanoseconds
    }

    public func challenge(input: RoundInput) async throws -> ChallengeArtifact {
        try await ScriptedRoundResolver.sleepIfNeeded(delayNanoseconds)
        return try ScriptedRoundResolver.value(round: input.round, from: rounds, actor: "challenger")
    }
}
