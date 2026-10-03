import Foundation

public struct KeywordOverlapEvolutionScorer: Sendable {
    public init() {}

    public func score(output: String, expected: String) -> Double {
        let required = Set(tokens(expected).filter { $0.count >= 3 })
        if required.isEmpty { return output.trimmedForNativeAgentEvolution.isEmpty ? 0 : 0.5 }
        let observed = Set(tokens(output))
        let hits = required.filter { observed.contains($0) }.count
        return Double(hits) / Double(required.count)
    }

    private func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmedForNativeAgentEvolution }
            .filter { !$0.isEmpty && !Self.stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "until", "without", "when", "what", "should", "must", "have", "true"
    ]
}

public struct ClosureEvolutionCandidateRunner: EvolutionCandidateRunner {
    private let runClosure: @Sendable (EvolutionCandidate, EvolutionExample) async throws -> EvolutionRunOutput

    public init(
        _ runClosure: @escaping @Sendable (EvolutionCandidate, EvolutionExample) async throws -> EvolutionRunOutput
    ) {
        self.runClosure = runClosure
    }

    public func run(candidate: EvolutionCandidate, example: EvolutionExample) async throws -> EvolutionRunOutput {
        try await runClosure(candidate, example)
    }
}

public struct RunnerBackedEvolutionCandidateEvaluator: EvolutionCandidateEvaluator {
    private let runner: any EvolutionCandidateRunner
    private let scorer: KeywordOverlapEvolutionScorer

    public init(
        runner: any EvolutionCandidateRunner,
        scorer: KeywordOverlapEvolutionScorer = KeywordOverlapEvolutionScorer()
    ) {
        self.runner = runner
        self.scorer = scorer
    }

    public func evaluate(
        candidate: EvolutionCandidate,
        dataset: EvolutionDataset
    ) async throws -> EvolutionCandidateEvaluation {
        guard !dataset.examples.isEmpty else { throw EvolutionError.emptyDataset }

        var scores: [EvolutionExampleScore] = []
        for example in dataset.examples {
            let output = try await runner.run(candidate: candidate, example: example)
            let score = output.errorMessage == nil ? scorer.score(output: output.output, expected: example.expectedOutput) : 0
            let reason = output.errorMessage ?? String(format: "keyword overlap %.3f", score)
            scores.append(
                EvolutionExampleScore(
                    exampleID: example.id,
                    score: score,
                    reason: reason,
                    output: output.output
                )
            )
        }

        let validation = average(scores, for: dataset.validationExamples)
        let holdout = dataset.holdoutExamples.isEmpty ? nil : average(scores, for: dataset.holdoutExamples)
        return EvolutionCandidateEvaluation(
            candidateID: candidate.id,
            validationScore: validation,
            holdoutScore: holdout,
            exampleScores: scores,
            passed: true,
            reason: "evaluated with runner-backed keyword overlap scorer"
        )
    }

    private func average(_ scores: [EvolutionExampleScore], for examples: [EvolutionExample]) -> Double {
        let ids = Set(examples.map(\.id))
        let selected = scores.filter { ids.contains($0.exampleID) }
        guard !selected.isEmpty else { return 0 }
        return selected.map(\.score).reduce(0, +) / Double(selected.count)
    }
}
