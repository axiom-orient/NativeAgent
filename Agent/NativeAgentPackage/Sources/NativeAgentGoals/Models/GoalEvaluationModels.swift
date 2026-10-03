import NativeAgentDomain

public struct GoalEvaluation: Codable, Sendable, Equatable {
    public let satisfied: Bool
    public let blocked: Bool
    public let score: Double
    public let reason: String
    public let nextInstruction: String
    public let evaluator: String

    public init(
        satisfied: Bool,
        blocked: Bool = false,
        score: Double = 0,
        reason: String = "",
        nextInstruction: String = "",
        evaluator: String = "heuristic"
    ) {
        self.satisfied = satisfied
        self.blocked = blocked
        self.score = min(1, max(0, score.isFinite ? score : 0))
        self.reason = reason.trimmedForNativeAgentGoal
        self.nextInstruction = nextInstruction.trimmedForNativeAgentGoal
        self.evaluator = evaluator.trimmedForNativeAgentGoal.isEmpty ? "unknown" : evaluator.trimmedForNativeAgentGoal
    }

    private enum CodingKeys: String, CodingKey {
        case satisfied
        case blocked
        case score
        case reason
        case nextInstruction = "next_instruction"
        case evaluator
    }
}

public struct GoalTurnRecord: Codable, Sendable, Equatable {
    public let turn: Int
    public let sessionID: String
    public let status: SessionStatus
    public let output: String
    public let score: Double
    public let satisfied: Bool
    public let blocked: Bool
    public let reason: String
    public let nextInstruction: String
    public let errorMessage: String?
    public let waitKind: SessionWaitKind?
    public let hostAction: GoalHostAction?

    public init(
        turn: Int,
        sessionID: String,
        status: SessionStatus,
        output: String,
        evaluation: GoalEvaluation,
        errorMessage: String? = nil,
        waitKind: SessionWaitKind? = nil,
        hostAction: GoalHostAction? = nil
    ) {
        self.turn = max(1, turn)
        self.sessionID = sessionID.trimmedForNativeAgentGoal
        self.status = status
        self.output = output
        self.score = evaluation.score
        self.satisfied = evaluation.satisfied
        self.blocked = evaluation.blocked
        self.reason = evaluation.reason
        self.nextInstruction = evaluation.nextInstruction
        self.errorMessage = errorMessage?.trimmedForNativeAgentGoal.nonEmptyForNativeAgentGoal
        self.waitKind = waitKind
        self.hostAction = hostAction
    }

    private enum CodingKeys: String, CodingKey {
        case turn
        case sessionID = "session_id"
        case status
        case output
        case score
        case satisfied
        case blocked
        case reason
        case nextInstruction = "next_instruction"
        case errorMessage = "error_message"
        case waitKind = "wait_kind"
        case hostAction = "host_action"
    }
}
