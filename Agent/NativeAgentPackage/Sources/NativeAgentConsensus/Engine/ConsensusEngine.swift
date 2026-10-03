import Foundation

public enum BACEngineError: Error, Equatable {
    case missingTriadRole
    case noRoundsExecuted
}

public struct BACEngine: RunnerProtocol, Sendable {
    public static let engineName = "bounded-artifact-consensus"
    public static let engineShortName = "BAC"
    public static let hardMaxRounds = 3

    public let config: BACConfig
    public let triad: Triad
    private let gate: any Gate
    private let synthesizer: any Synthesizer

    public init(config: BACConfig = .init(), triad: Triad) throws {
        self.triad = triad

        let now = config.now
        let maxRounds = min(max(1, config.maxRounds), Self.hardMaxRounds)
        let maxRequiredSteps = max(1, config.maxRequiredSteps)
        let registryQueryLimit = max(1, config.registryQueryLimit)
        let gate = config.gate ?? DefaultGate(maxRequiredSteps: maxRequiredSteps)
        let synthesizer = config.synthesizer ?? DefaultSynthesizer()
        let runID = config.runID

        self.gate = gate
        self.synthesizer = synthesizer
        self.config = BACConfig(
            maxRounds: maxRounds,
            maxRequiredSteps: maxRequiredSteps,
            registryQueryLimit: registryQueryLimit,
            registry: config.registry,
            gate: gate,
            synthesizer: synthesizer,
            observers: config.observers,
            now: now,
            runID: runID
        )
    }

    public func run(problem: ProblemPacket) async throws -> BACResult {
        try Task.checkCancellation()
        let normalizedProblem = ArtifactNormalization.normalize(problem: problem)
        let startedAt = config.now()
        let placeholderFinal = Consensus(decision: .abort, summary: "", sourceRound: 0)
        let runID = config.runID()
        let similarCases = try await searchSimilarCases(problem: normalizedProblem)
        try Task.checkCancellation()
        let startedResult = BACResult(
            runID: runID,
            engine: Self.engineName,
            startedAt: startedAt,
            finishedAt: startedAt,
            problem: normalizedProblem,
            similarCases: similarCases,
            rounds: [],
            final: placeholderFinal
        )
        try await notifyObservers { try await $0.onRunStart(result: startedResult) }

        var previous: Consensus?
        var rounds: [BACRoundResult] = []
        rounds.reserveCapacity(config.maxRounds)

        for roundNumber in 1...config.maxRounds {
            try Task.checkCancellation()
            let input = RoundInput(
                problem: normalizedProblem,
                round: roundNumber,
                similarCases: similarCases,
                delta: buildDelta(previous: previous)
            )

            let artifacts = ArtifactNormalization.normalize(try await runRound(input: input))
            try Task.checkCancellation()
            let provisionalConsensus = gate.decide(
                input: GateInput(
                    round: roundNumber,
                    maxRounds: config.maxRounds,
                    previous: previous,
                    artifacts: artifacts
                )
            )
            let consensus = finalizedConsensus(
                provisionalConsensus,
                summary: synthesizer.summarize(input: SynthesisInput(artifacts: artifacts, consensus: provisionalConsensus)),
                finalizedAt: config.now()
            )
            try Task.checkCancellation()

            let round = BACRoundResult(number: roundNumber, input: input, artifacts: artifacts, consensus: consensus)
            rounds.append(round)
            previous = consensus

            let roundResult = BACResult(
                runID: runID,
                engine: Self.engineName,
                startedAt: startedAt,
                finishedAt: startedAt,
                problem: normalizedProblem,
                similarCases: similarCases,
                rounds: rounds,
                final: placeholderFinal
            )
            try await notifyObservers { try await $0.onRoundComplete(result: roundResult, round: round) }
            try Task.checkCancellation()

            if consensus.decision == .accept || consensus.decision == .abort {
                break
            }
        }

        guard let final = rounds.last?.consensus else {
            throw BACEngineError.noRoundsExecuted
        }
        try Task.checkCancellation()

        let result = BACResult(
            runID: runID,
            engine: Self.engineName,
            startedAt: startedAt,
            finishedAt: config.now(),
            problem: normalizedProblem,
            similarCases: similarCases,
            rounds: rounds,
            final: final
        )
        try await notifyObservers { try await $0.onRunComplete(result: result) }
        return result
    }

    private func runRound(input: RoundInput) async throws -> RoundArtifacts {
        async let proposal = triad.constructor.propose(input: input)
        async let review = triad.verifier.review(input: input)
        async let challenge = triad.challenger.challenge(input: input)

        return try await RoundArtifacts(
            proposal: proposal,
            review: review,
            challenge: challenge
        )
    }

    private func searchSimilarCases(problem: ProblemPacket) async throws -> [CaseCard] {
        guard let registry = config.registry else { return [] }
        let query = CaseQuery(
            text: TextUtil.normalizeText(problem.objective, problem.observedIssue, problem.candidate),
            fingerprint: TextUtil.problemFingerprint(problem),
            primaryClass: TextUtil.primaryClass(problem),
            tags: problem.tags,
            facets: problem.facets,
            limit: config.registryQueryLimit
        )
        return try await registry.search(query: query)
    }

    private func buildDelta(previous: Consensus?) -> DeltaPacket? {
        guard let previous else { return nil }
        return DeltaPacket(
            previousDecision: previous.decision,
            candidateSummary: previous.summary,
            requiredActions: previous.requiredActions,
            blockers: previous.blockers,
            checks: previous.checks
        )
    }

    private func finalizedConsensus(
        _ consensus: Consensus,
        summary: String,
        finalizedAt: Date
    ) -> Consensus {
        Consensus(
            decision: consensus.decision,
            summary: summary,
            reasons: consensus.reasons,
            requiredActions: consensus.requiredActions,
            blockers: consensus.blockers,
            checks: consensus.checks,
            selectedPlan: consensus.selectedPlan,
            saferOption: consensus.saferOption,
            sourceRound: consensus.sourceRound,
            finalizedAt: finalizedAt
        )
    }

    private func notifyObservers(_ action: (any ConsensusObserver) async throws -> Void) async throws {
        for observer in config.observers {
            try await action(observer)
        }
    }
}
