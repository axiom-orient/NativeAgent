import Foundation

public enum EvolutionApplyMode: String, Codable, Sendable, Equatable {
    case reviewOnly = "review_only"
}

public struct EvolutionConfig: Codable, Sendable, Equatable {
    public static let standardMaximumCandidates = 4
    public static let minimumCandidates = 1
    public static let standardMinimumImprovement = 0.03
    public static let minimumScore = 0.0
    public static let maximumScore = 1.0
    public static let holdoutRegressionTolerance = 0.0001

    public let runID: String
    public let maxCandidates: Int
    public let minImprovement: Double
    public let requireHoldoutNoRegression: Bool
    public let applyMode: EvolutionApplyMode

    public init(
        runID: String = UUID().uuidString,
        maxCandidates: Int = EvolutionConfig.standardMaximumCandidates,
        minImprovement: Double = EvolutionConfig.standardMinimumImprovement,
        requireHoldoutNoRegression: Bool = true,
        applyMode: EvolutionApplyMode = .reviewOnly
    ) {
        self.runID = EvolutionPath.sanitized(runID)
        self.maxCandidates = max(EvolutionConfig.minimumCandidates, maxCandidates)
        let finiteImprovement = minImprovement.isFinite
            ? minImprovement
            : EvolutionConfig.standardMinimumImprovement
        self.minImprovement = min(
            EvolutionConfig.maximumScore,
            max(EvolutionConfig.minimumScore, finiteImprovement)
        )
        self.requireHoldoutNoRegression = requireHoldoutNoRegression
        self.applyMode = applyMode
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case maxCandidates = "max_candidates"
        case minImprovement = "min_improvement"
        case requireHoldoutNoRegression = "require_holdout_no_regression"
        case applyMode = "apply_mode"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(String.self, forKey: .runID)
        let maxCandidates = try container.decode(Int.self, forKey: .maxCandidates)
        let minImprovement = try container.decode(Double.self, forKey: .minImprovement)
        let requireHoldoutNoRegression = try container.decode(Bool.self, forKey: .requireHoldoutNoRegression)
        let applyMode = try container.decode(EvolutionApplyMode.self, forKey: .applyMode)

        guard runID == EvolutionPath.sanitized(runID), !runID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .runID,
                in: container,
                debugDescription: "run_id must already be a non-empty canonical EvolutionPath identifier"
            )
        }
        guard maxCandidates >= EvolutionConfig.minimumCandidates else {
            throw DecodingError.dataCorruptedError(
                forKey: .maxCandidates,
                in: container,
                debugDescription: "max_candidates must be at least \(EvolutionConfig.minimumCandidates)"
            )
        }
        guard minImprovement.isFinite,
              (EvolutionConfig.minimumScore...EvolutionConfig.maximumScore).contains(minImprovement)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .minImprovement,
                in: container,
                debugDescription: "min_improvement must be finite and between 0 and 1"
            )
        }

        self.runID = runID
        self.maxCandidates = maxCandidates
        self.minImprovement = minImprovement
        self.requireHoldoutNoRegression = requireHoldoutNoRegression
        self.applyMode = applyMode
    }
}
