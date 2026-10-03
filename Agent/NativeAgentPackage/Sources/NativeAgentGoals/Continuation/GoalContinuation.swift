import Foundation

public enum GoalContinuationDecision: String, Codable, Sendable, Equatable {
    case resume
    case keepWaiting = "keep_waiting"
    case skipPaused = "skip_paused"
    case skipComplete = "skip_complete"
    case skipCleared = "skip_cleared"
    case skipBudgetLimited = "skip_budget_limited"
    case skipBlocked = "skip_blocked"
    case skipFailed = "skip_failed"
    case skipActive = "skip_active"
}

public struct GoalContinuationPolicy: Codable, Sendable, Equatable {
    public let resumeActiveGoals: Bool
    public let resumeInterruptedFailedGoals: Bool
    public let resumeBudgetLimitedGoals: Bool
    public let resumeBlockedGoals: Bool
    public let resumeDueTimeWaits: Bool
    public let maxAutomaticResumes: Int
    public let additionalTurnsPerResume: Int
    public let interruptedErrorMarkers: [String]

    public init(
        resumeActiveGoals: Bool = true,
        resumeInterruptedFailedGoals: Bool = true,
        resumeBudgetLimitedGoals: Bool = false,
        resumeBlockedGoals: Bool = false,
        resumeDueTimeWaits: Bool = true,
        maxAutomaticResumes: Int = 3,
        additionalTurnsPerResume: Int = 3,
        interruptedErrorMarkers: [String] = ["cancel", "cancellation", "interrupted", "background", "terminated", "relaunch"]
    ) {
        self.resumeActiveGoals = resumeActiveGoals
        self.resumeInterruptedFailedGoals = resumeInterruptedFailedGoals
        self.resumeBudgetLimitedGoals = resumeBudgetLimitedGoals
        self.resumeBlockedGoals = resumeBlockedGoals
        self.resumeDueTimeWaits = resumeDueTimeWaits
        self.maxAutomaticResumes = max(0, maxAutomaticResumes)
        self.additionalTurnsPerResume = max(1, additionalTurnsPerResume)
        self.interruptedErrorMarkers = interruptedErrorMarkers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case resumeActiveGoals = "resume_active_goals"
        case resumeInterruptedFailedGoals = "resume_interrupted_failed_goals"
        case resumeBudgetLimitedGoals = "resume_budget_limited_goals"
        case resumeBlockedGoals = "resume_blocked_goals"
        case resumeDueTimeWaits = "resume_due_time_waits"
        case maxAutomaticResumes = "max_automatic_resumes"
        case additionalTurnsPerResume = "additional_turns_per_resume"
        case interruptedErrorMarkers = "interrupted_error_markers"
    }
}

public struct GoalContinuationItem: Codable, Sendable, Equatable {
    public let goalID: String
    public let status: GoalStatus
    public let decision: GoalContinuationDecision
    public let reason: String
    public let hostAction: GoalHostAction?
    public let session: GoalSession

    public init(
        goalID: String,
        status: GoalStatus,
        decision: GoalContinuationDecision,
        reason: String,
        hostAction: GoalHostAction? = nil,
        session: GoalSession
    ) {
        self.goalID = GoalPath.sanitized(goalID)
        self.status = status
        self.decision = decision
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostAction = hostAction
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case status
        case decision
        case reason
        case hostAction = "host_action"
        case session
    }
}

public struct GoalContinuationPlan: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let policy: GoalContinuationPolicy
    public let items: [GoalContinuationItem]

    public init(createdAt: Date, policy: GoalContinuationPolicy, items: [GoalContinuationItem]) {
        self.createdAt = createdAt
        self.policy = policy
        self.items = items
    }

    public var resumableItems: [GoalContinuationItem] {
        items.filter { $0.decision == .resume }
    }

    public var waitingItems: [GoalContinuationItem] {
        items.filter { $0.decision == .keepWaiting }
    }

    private enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case policy
        case items
    }
}

public struct GoalContinuationPlanner: Sendable {
    public let policy: GoalContinuationPolicy
    private let now: @Sendable () -> Date

    public init(
        policy: GoalContinuationPolicy = GoalContinuationPolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.now = now
    }

    public func plan(for sessions: [GoalSession]) -> GoalContinuationPlan {
        let referenceTime = now()
        let items = sessions
            .sorted { $0.goalID < $1.goalID }
            .map { session in item(for: session, at: referenceTime) }
        return GoalContinuationPlan(createdAt: referenceTime, policy: policy, items: items)
    }

    private func item(for session: GoalSession, at referenceTime: Date) -> GoalContinuationItem {
        switch session.status {
        case .active:
            return GoalContinuationItem(
                goalID: session.goalID,
                status: session.status,
                decision: policy.resumeActiveGoals ? .resume : .skipActive,
                reason: policy.resumeActiveGoals ? "active goal can continue after relaunch" : "active goal auto-resume disabled",
                hostAction: session.pendingHostAction,
                session: session
            )
        case .waiting:
            if let hostAction = session.pendingHostAction,
               hostAction.kind == .waitUntilTime,
               let resumeAt = hostAction.resumeAt,
               policy.resumeDueTimeWaits,
               resumeAt <= referenceTime {
                return GoalContinuationItem(
                    goalID: session.goalID,
                    status: session.status,
                    decision: .resume,
                    reason: "time wait is due and can continue after relaunch",
                    hostAction: hostAction,
                    session: session
                )
            }
            return GoalContinuationItem(
                goalID: session.goalID,
                status: session.status,
                decision: .keepWaiting,
                reason: "goal is waiting for a host action before it can continue",
                hostAction: session.pendingHostAction,
                session: session
            )
        case .paused:
            return GoalContinuationItem(goalID: session.goalID, status: session.status, decision: .skipPaused, reason: "paused by host/user", hostAction: session.pendingHostAction, session: session)
        case .complete:
            return GoalContinuationItem(goalID: session.goalID, status: session.status, decision: .skipComplete, reason: "goal already complete", hostAction: session.pendingHostAction, session: session)
        case .cleared:
            return GoalContinuationItem(goalID: session.goalID, status: session.status, decision: .skipCleared, reason: "goal was cleared", hostAction: session.pendingHostAction, session: session)
        case .budgetLimited:
            return GoalContinuationItem(
                goalID: session.goalID,
                status: session.status,
                decision: policy.resumeBudgetLimitedGoals ? .resume : .skipBudgetLimited,
                reason: policy.resumeBudgetLimitedGoals ? "budget-limited goal is configured for retry" : "budget-limited retry disabled",
                hostAction: session.pendingHostAction,
                session: session
            )
        case .blocked:
            return GoalContinuationItem(
                goalID: session.goalID,
                status: session.status,
                decision: policy.resumeBlockedGoals ? .resume : .skipBlocked,
                reason: policy.resumeBlockedGoals ? "blocked goal is configured for retry" : "blocked retry disabled",
                hostAction: session.pendingHostAction,
                session: session
            )
        case .failed:
            let interrupted = isInterruptedFailure(session)
            return GoalContinuationItem(
                goalID: session.goalID,
                status: session.status,
                decision: policy.resumeInterruptedFailedGoals && interrupted ? .resume : .skipFailed,
                reason: interrupted ? "failed goal appears to be an interruption and can retry" : "failed goal does not match interruption markers",
                hostAction: session.pendingHostAction,
                session: session
            )
        }
    }

    private func isInterruptedFailure(_ session: GoalSession) -> Bool {
        let text = [session.lastReason, session.turns.last?.errorMessage ?? ""]
            .joined(separator: " ")
            .lowercased()
        guard !text.isEmpty else { return false }
        return policy.interruptedErrorMarkers.contains { marker in text.contains(marker) }
    }
}
