import Foundation

public protocol Constructor: Sendable {
    func propose(input: RoundInput) async throws -> ProposalArtifact
}

public protocol Verifier: Sendable {
    func review(input: RoundInput) async throws -> ReviewArtifact
}

public protocol Challenger: Sendable {
    func challenge(input: RoundInput) async throws -> ChallengeArtifact
}

public struct Triad: Sendable {
    public let constructor: any Constructor
    public let verifier: any Verifier
    public let challenger: any Challenger

    public init(constructor: any Constructor, verifier: any Verifier, challenger: any Challenger) {
        self.constructor = constructor
        self.verifier = verifier
        self.challenger = challenger
    }
}

public protocol Gate: Sendable {
    func decide(input: GateInput) -> Consensus
}

public protocol Synthesizer: Sendable {
    func summarize(input: SynthesisInput) -> String
}

public protocol ConsensusObserver: Sendable {
    func onRunStart(result: BACResult) async throws
    func onRoundComplete(result: BACResult, round: BACRoundResult) async throws
    func onRunComplete(result: BACResult) async throws
}

public protocol CaseRegistry: Sendable {
    func search(query: CaseQuery) async throws -> [CaseCard]
}

public struct GateInput: Sendable {
    public let round: Int
    public let maxRounds: Int
    public let previous: Consensus?
    public let artifacts: RoundArtifacts

    public init(round: Int, maxRounds: Int, previous: Consensus?, artifacts: RoundArtifacts) {
        self.round = round
        self.maxRounds = maxRounds
        self.previous = previous
        self.artifacts = artifacts
    }
}

public struct SynthesisInput: Sendable {
    public let artifacts: RoundArtifacts
    public let consensus: Consensus

    public init(artifacts: RoundArtifacts, consensus: Consensus) {
        self.artifacts = artifacts
        self.consensus = consensus
    }
}

public struct BACConfig: Sendable {
    public let maxRounds: Int
    public let maxRequiredSteps: Int
    public let registryQueryLimit: Int
    public let registry: (any CaseRegistry)?
    public let gate: (any Gate)?
    public let synthesizer: (any Synthesizer)?
    public let observers: [any ConsensusObserver]
    public let now: @Sendable () -> Date
    public let runID: @Sendable () -> String

    public init(
        maxRounds: Int = 2,
        maxRequiredSteps: Int = 3,
        registryQueryLimit: Int = 3,
        registry: (any CaseRegistry)? = nil,
        gate: (any Gate)? = nil,
        synthesizer: (any Synthesizer)? = nil,
        observers: [any ConsensusObserver] = [],
        now: @escaping @Sendable () -> Date = { Date() },
        runID: @escaping @Sendable () -> String = { "run-\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))" }
    ) {
        self.maxRounds = maxRounds
        self.maxRequiredSteps = maxRequiredSteps
        self.registryQueryLimit = registryQueryLimit
        self.registry = registry
        self.gate = gate
        self.synthesizer = synthesizer
        self.observers = observers
        self.now = now
        self.runID = runID
    }
}
