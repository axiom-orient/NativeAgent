public struct GoalSession: Codable, Sendable, Equatable {
    public let goalID: String
    public let objective: String
    public let successCondition: String
    public let status: GoalStatus
    public let maxTurns: Int
    public let minScore: Double
    public let maxStaleTurns: Int
    public let minProgressDelta: Double
    public let agentSessionID: String?
    public let turns: [GoalTurnRecord]
    public let lastReason: String

    public init(
        goalID: String = "default",
        objective: String,
        successCondition: String = "",
        status: GoalStatus = .active,
        maxTurns: Int = 8,
        minScore: Double = 0.86,
        maxStaleTurns: Int = 3,
        minProgressDelta: Double = 0.02,
        agentSessionID: String? = nil,
        turns: [GoalTurnRecord] = [],
        lastReason: String = ""
    ) {
        self.goalID = GoalPath.sanitized(goalID)
        self.objective = objective.trimmedForNativeAgentGoal
        self.successCondition = successCondition.trimmedForNativeAgentGoal
        self.status = status
        self.maxTurns = max(1, maxTurns)
        self.minScore = min(1, max(0, minScore.isFinite ? minScore : 0.86))
        self.maxStaleTurns = max(1, maxStaleTurns)
        self.minProgressDelta = min(1, max(0, minProgressDelta.isFinite ? minProgressDelta : 0.02))
        self.agentSessionID = agentSessionID?.trimmedForNativeAgentGoal.nonEmptyForNativeAgentGoal
        self.turns = turns
        self.lastReason = lastReason.trimmedForNativeAgentGoal
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goalID = GoalPath.sanitized(try c.decode(String.self, forKey: .goalID))
        objective = (try c.decode(String.self, forKey: .objective)).trimmedForNativeAgentGoal
        successCondition = (try c.decode(String.self, forKey: .successCondition)).trimmedForNativeAgentGoal
        status = try c.decode(GoalStatus.self, forKey: .status)
        maxTurns = max(1, try c.decode(Int.self, forKey: .maxTurns))
        let rawMinScore = try c.decode(Double.self, forKey: .minScore)
        minScore = min(1, max(0, rawMinScore.isFinite ? rawMinScore : 0.86))
        maxStaleTurns = max(1, try c.decode(Int.self, forKey: .maxStaleTurns))
        let rawDelta = try c.decode(Double.self, forKey: .minProgressDelta)
        minProgressDelta = min(1, max(0, rawDelta.isFinite ? rawDelta : 0.02))
        agentSessionID = try c.decodeIfPresent(String.self, forKey: .agentSessionID)?
            .trimmedForNativeAgentGoal.nonEmptyForNativeAgentGoal
        turns = try c.decode([GoalTurnRecord].self, forKey: .turns)
        lastReason = (try c.decode(String.self, forKey: .lastReason)).trimmedForNativeAgentGoal
    }

    public var nextTurn: Int { turns.count + 1 }
    public var latestScore: Double { turns.last?.score ?? 0 }
    public var latestOutput: String { turns.last?.output ?? "" }
    public var latestInstruction: String { turns.last?.nextInstruction ?? "" }
    public var pendingHostAction: GoalHostAction? {
        guard status == .waiting else { return nil }
        return turns.reversed().first(where: { $0.hostAction != nil })?.hostAction
    }

    package func applying(_ event: GoalSessionEvent) -> GoalSession {
        switch event {
        case let .appended(record):
            return GoalSession(
                goalID: goalID,
                objective: objective,
                successCondition: successCondition,
                status: status,
                maxTurns: maxTurns,
                minScore: minScore,
                maxStaleTurns: maxStaleTurns,
                minProgressDelta: minProgressDelta,
                agentSessionID: record.sessionID.trimmedForNativeAgentGoal.nonEmptyForNativeAgentGoal ?? agentSessionID,
                turns: turns + [record],
                lastReason: record.reason
            )
        case let .statusChanged(status):
            return GoalSession(
                goalID: goalID,
                objective: objective,
                successCondition: successCondition,
                status: status,
                maxTurns: maxTurns,
                minScore: minScore,
                maxStaleTurns: maxStaleTurns,
                minProgressDelta: minProgressDelta,
                agentSessionID: agentSessionID,
                turns: turns,
                lastReason: lastReason
            )
        case let .resumed(maxAdditionalTurns, minScore, maxStaleTurns, minProgressDelta):
            return GoalSession(
                goalID: goalID,
                objective: objective,
                successCondition: successCondition,
                status: .active,
                maxTurns: max(maxTurns, turns.count + max(1, maxAdditionalTurns)),
                minScore: minScore,
                maxStaleTurns: maxStaleTurns,
                minProgressDelta: minProgressDelta,
                agentSessionID: agentSessionID,
                turns: turns,
                lastReason: lastReason
            )
        case .turnBudgetExhausted:
            return GoalSession(
                goalID: goalID,
                objective: objective,
                successCondition: successCondition,
                status: .budgetLimited,
                maxTurns: maxTurns,
                minScore: minScore,
                maxStaleTurns: maxStaleTurns,
                minProgressDelta: minProgressDelta,
                agentSessionID: agentSessionID,
                turns: turns,
                lastReason: "goal reached maxTurns=\(maxTurns)"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case objective
        case successCondition = "success_condition"
        case status
        case maxTurns = "max_turns"
        case minScore = "min_score"
        case maxStaleTurns = "max_stale_turns"
        case minProgressDelta = "min_progress_delta"
        case agentSessionID = "agent_session_id"
        case turns
        case lastReason = "last_reason"
    }
}

package enum GoalSessionEvent: Sendable {
    case appended(GoalTurnRecord)
    case statusChanged(GoalStatus)
    case resumed(maxAdditionalTurns: Int, minScore: Double, maxStaleTurns: Int, minProgressDelta: Double)
    case turnBudgetExhausted
}
