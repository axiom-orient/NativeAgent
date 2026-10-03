import NativeAgentDomain

public struct EvolutionRunOutput: Codable, Sendable, Equatable {
    public let exampleID: String
    public let output: String
    public let errorMessage: String?
    public let metadata: [String: JSONValue]

    public init(
        exampleID: String,
        output: String,
        errorMessage: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.exampleID = EvolutionPath.sanitized(exampleID)
        self.output = output
        self.errorMessage = errorMessage?.trimmedForNativeAgentEvolution.nonEmptyForNativeAgentEvolution
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case exampleID = "example_id"
        case output
        case errorMessage = "error_message"
        case metadata
    }
}

public struct EvolutionExampleScore: Codable, Sendable, Equatable {
    public let exampleID: String
    public let score: Double
    public let reason: String
    public let output: String

    public init(exampleID: String, score: Double, reason: String, output: String) {
        self.exampleID = EvolutionPath.sanitized(exampleID)
        self.score = min(1, max(0, score.isFinite ? score : 0))
        self.reason = reason.trimmedForNativeAgentEvolution
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case exampleID = "example_id"
        case score
        case reason
        case output
    }
}

public struct EvolutionCandidateEvaluation: Codable, Sendable, Equatable {
    public let candidateID: String
    public let validationScore: Double
    public let holdoutScore: Double?
    public let exampleScores: [EvolutionExampleScore]
    public let passed: Bool
    public let reason: String

    public init(
        candidateID: String,
        validationScore: Double,
        holdoutScore: Double? = nil,
        exampleScores: [EvolutionExampleScore] = [],
        passed: Bool = true,
        reason: String = ""
    ) {
        self.candidateID = EvolutionPath.sanitized(candidateID)
        self.validationScore = min(1, max(0, validationScore.isFinite ? validationScore : 0))
        self.holdoutScore = holdoutScore.map { min(1, max(0, $0.isFinite ? $0 : 0)) }
        self.exampleScores = exampleScores
        self.passed = passed
        self.reason = reason.trimmedForNativeAgentEvolution
    }

    private enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case validationScore = "validation_score"
        case holdoutScore = "holdout_score"
        case exampleScores = "example_scores"
        case passed
        case reason
    }
}

public struct EvolutionCandidateReport: Codable, Sendable, Equatable {
    public let candidate: EvolutionCandidate
    public let evaluation: EvolutionCandidateEvaluation
    public let selected: Bool
    public let rejectedReason: String?

    public init(
        candidate: EvolutionCandidate,
        evaluation: EvolutionCandidateEvaluation,
        selected: Bool = false,
        rejectedReason: String? = nil
    ) {
        self.candidate = candidate
        self.evaluation = evaluation
        self.selected = selected
        self.rejectedReason = rejectedReason?.trimmedForNativeAgentEvolution.nonEmptyForNativeAgentEvolution
    }

    private enum CodingKeys: String, CodingKey {
        case candidate
        case evaluation
        case selected
        case rejectedReason = "rejected_reason"
    }
}
