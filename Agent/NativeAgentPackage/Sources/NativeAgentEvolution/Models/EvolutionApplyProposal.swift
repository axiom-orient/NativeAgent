import NativeAgentDomain

public struct EvolutionApplyProposal: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable, Equatable {
        case pendingHostApproval = "pending_host_approval"
    }

    public let id: String
    public let runID: String
    public let sourceID: String
    public let sourceName: String
    public let candidateID: String
    public let candidateTitle: String
    public let rationale: String
    public let baselineValidationScore: Double
    public let candidateValidationScore: Double
    public let baselineHoldoutScore: Double?
    public let candidateHoldoutScore: Double?
    public let beforeContent: String
    public let afterContent: String
    public let recommendation: String
    public let requiresHostApproval: Bool
    public let status: Status
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        runID: String,
        sourceID: String,
        sourceName: String,
        candidateID: String,
        candidateTitle: String,
        rationale: String,
        baselineValidationScore: Double,
        candidateValidationScore: Double,
        baselineHoldoutScore: Double? = nil,
        candidateHoldoutScore: Double? = nil,
        beforeContent: String,
        afterContent: String,
        recommendation: String,
        requiresHostApproval: Bool = true,
        status: Status = .pendingHostApproval,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = EvolutionPath.sanitized(id)
        self.runID = EvolutionPath.sanitized(runID)
        self.sourceID = EvolutionPath.sanitized(sourceID)
        self.sourceName = sourceName.trimmedForNativeAgentEvolution
        self.candidateID = EvolutionPath.sanitized(candidateID)
        self.candidateTitle = candidateTitle.trimmedForNativeAgentEvolution
        self.rationale = rationale.trimmedForNativeAgentEvolution
        self.baselineValidationScore = min(1, max(0, baselineValidationScore.isFinite ? baselineValidationScore : 0))
        self.candidateValidationScore = min(1, max(0, candidateValidationScore.isFinite ? candidateValidationScore : 0))
        self.baselineHoldoutScore = baselineHoldoutScore.map { min(1, max(0, $0.isFinite ? $0 : 0)) }
        self.candidateHoldoutScore = candidateHoldoutScore.map { min(1, max(0, $0.isFinite ? $0 : 0)) }
        self.beforeContent = beforeContent
        self.afterContent = afterContent
        self.recommendation = recommendation.trimmedForNativeAgentEvolution
        self.requiresHostApproval = requiresHostApproval
        self.status = status
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case sourceID = "source_id"
        case sourceName = "source_name"
        case candidateID = "candidate_id"
        case candidateTitle = "candidate_title"
        case rationale
        case baselineValidationScore = "baseline_validation_score"
        case candidateValidationScore = "candidate_validation_score"
        case baselineHoldoutScore = "baseline_holdout_score"
        case candidateHoldoutScore = "candidate_holdout_score"
        case beforeContent = "before_content"
        case afterContent = "after_content"
        case recommendation
        case requiresHostApproval = "requires_host_approval"
        case status
        case metadata
    }
}
