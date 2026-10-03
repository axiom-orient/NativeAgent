import Foundation

public protocol EvolutionCandidateGenerator: Sendable {
    func generateCandidates(
        source: EvolutionArtifact,
        dataset: EvolutionDataset,
        config: EvolutionConfig
    ) async throws -> [EvolutionCandidate]
}

public protocol EvolutionCandidateRunner: Sendable {
    func run(
        candidate: EvolutionCandidate,
        example: EvolutionExample
    ) async throws -> EvolutionRunOutput
}

public protocol EvolutionCandidateEvaluator: Sendable {
    func evaluate(
        candidate: EvolutionCandidate,
        dataset: EvolutionDataset
    ) async throws -> EvolutionCandidateEvaluation
}

public protocol EvolutionReportStore: Sendable {
    func save(_ report: EvolutionReport) async throws -> EvolutionReport
    func path(runID: String) -> String
}
