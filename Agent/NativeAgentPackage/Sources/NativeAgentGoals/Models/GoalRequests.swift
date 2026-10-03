public struct GoalRunRequest: Codable, Sendable, Equatable {
    public let goalID: String
    public let objective: String
    public let successCondition: String
    public let maxTurns: Int
    public let minScore: Double
    public let maxStaleTurns: Int
    public let minProgressDelta: Double
    public let resumeExisting: Bool

    public init(
        goalID: String = "default",
        objective: String,
        successCondition: String = "",
        maxTurns: Int = 8,
        minScore: Double = 0.86,
        maxStaleTurns: Int = 3,
        minProgressDelta: Double = 0.02,
        resumeExisting: Bool = true
    ) {
        self.goalID = GoalPath.sanitized(goalID)
        self.objective = objective.trimmedForNativeAgentGoal
        self.successCondition = successCondition.trimmedForNativeAgentGoal
        self.maxTurns = max(1, maxTurns)
        self.minScore = min(1, max(0, minScore.isFinite ? minScore : 0.86))
        self.maxStaleTurns = max(1, maxStaleTurns)
        self.minProgressDelta = min(1, max(0, minProgressDelta.isFinite ? minProgressDelta : 0.02))
        self.resumeExisting = resumeExisting
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goalID = GoalPath.sanitized(try c.decode(String.self, forKey: .goalID))
        objective = (try c.decode(String.self, forKey: .objective)).trimmedForNativeAgentGoal
        successCondition = (try c.decode(String.self, forKey: .successCondition)).trimmedForNativeAgentGoal
        maxTurns = max(1, try c.decode(Int.self, forKey: .maxTurns))
        let rawMinScore = try c.decode(Double.self, forKey: .minScore)
        minScore = min(1, max(0, rawMinScore.isFinite ? rawMinScore : 0.86))
        maxStaleTurns = max(1, try c.decode(Int.self, forKey: .maxStaleTurns))
        let rawDelta = try c.decode(Double.self, forKey: .minProgressDelta)
        minProgressDelta = min(1, max(0, rawDelta.isFinite ? rawDelta : 0.02))
        resumeExisting = try c.decode(Bool.self, forKey: .resumeExisting)
    }

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case objective
        case successCondition = "success_condition"
        case maxTurns = "max_turns"
        case minScore = "min_score"
        case maxStaleTurns = "max_stale_turns"
        case minProgressDelta = "min_progress_delta"
        case resumeExisting = "resume_existing"
    }
}

public struct GoalTurnRequest: Codable, Sendable, Equatable {
    public let goalID: String
    public let turn: Int
    public let input: String
    public let objective: String
    public let successCondition: String
    public let agentSessionID: String?

    public init(
        goalID: String,
        turn: Int,
        input: String,
        objective: String,
        successCondition: String = "",
        agentSessionID: String? = nil
    ) {
        self.goalID = GoalPath.sanitized(goalID)
        self.turn = max(1, turn)
        self.input = input
        self.objective = objective.trimmedForNativeAgentGoal
        self.successCondition = successCondition.trimmedForNativeAgentGoal
        self.agentSessionID = agentSessionID?.trimmedForNativeAgentGoal.nonEmptyForNativeAgentGoal
    }

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case turn
        case input
        case objective
        case successCondition = "success_condition"
        case agentSessionID = "agent_session_id"
    }
}
