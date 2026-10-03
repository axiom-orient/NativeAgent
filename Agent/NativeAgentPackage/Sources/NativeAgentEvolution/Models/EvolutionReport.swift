import Foundation
import NativeAgentDomain

public struct EvolutionReport: Codable, Sendable, Equatable {
    public let runID: String
    public let createdAt: Date
    public let source: EvolutionArtifact
    public let datasetName: String
    public let config: EvolutionConfig
    public let baseline: EvolutionCandidateEvaluation
    public let candidates: [EvolutionCandidateReport]
    public let selectedCandidateID: String?
    public let recommendation: String
    public let storePath: String

    public init(
        runID: String,
        createdAt: Date,
        source: EvolutionArtifact,
        datasetName: String,
        config: EvolutionConfig,
        baseline: EvolutionCandidateEvaluation,
        candidates: [EvolutionCandidateReport],
        selectedCandidateID: String? = nil,
        recommendation: String,
        storePath: String = ""
    ) {
        self.runID = EvolutionPath.sanitized(runID)
        self.createdAt = createdAt
        self.source = source
        self.datasetName = datasetName.trimmedForNativeAgentEvolution
        self.config = config
        self.baseline = baseline
        self.candidates = candidates
        self.selectedCandidateID = selectedCandidateID?.trimmedForNativeAgentEvolution.nonEmptyForNativeAgentEvolution
        self.recommendation = recommendation.trimmedForNativeAgentEvolution
        self.storePath = storePath
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case createdAt = "created_at"
        case source
        case datasetName = "dataset_name"
        case config
        case baseline
        case candidates
        case selectedCandidateID = "selected_candidate_id"
        case recommendation
        case storePath = "store_path"
    }
}

extension EvolutionReport {
    func storing(at path: String) -> EvolutionReport {
        EvolutionReport(
            runID: runID,
            createdAt: createdAt,
            source: source,
            datasetName: datasetName,
            config: config,
            baseline: baseline,
            candidates: candidates,
            selectedCandidateID: selectedCandidateID,
            recommendation: recommendation,
            storePath: path
        )
    }
}

public extension EvolutionReport {
    var selectedCandidateReport: EvolutionCandidateReport? {
        guard let selectedCandidateID else { return nil }
        return candidates.first { $0.candidate.id == selectedCandidateID && $0.selected }
            ?? candidates.first { $0.candidate.id == selectedCandidateID }
    }

    var selectedCandidate: EvolutionCandidate? {
        selectedCandidateReport?.candidate
    }

    func makeApplyProposal(
        proposalID: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) throws -> EvolutionApplyProposal {
        guard let selected = selectedCandidateReport else { throw EvolutionError.noSelectedCandidate }
        let id = proposalID?.nonEmptyForNativeAgentEvolution ?? "apply-\(runID)-\(selected.candidate.id)"
        return EvolutionApplyProposal(
            id: id,
            runID: runID,
            sourceID: source.id,
            sourceName: source.name,
            candidateID: selected.candidate.id,
            candidateTitle: selected.candidate.title,
            rationale: selected.candidate.rationale,
            baselineValidationScore: baseline.validationScore,
            candidateValidationScore: selected.evaluation.validationScore,
            baselineHoldoutScore: baseline.holdoutScore,
            candidateHoldoutScore: selected.evaluation.holdoutScore,
            beforeContent: source.content,
            afterContent: selected.candidate.content,
            recommendation: recommendation,
            requiresHostApproval: true,
            status: .pendingHostApproval,
            metadata: metadata
        )
    }
}
