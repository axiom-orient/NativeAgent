import Foundation
import NativeAgentDomain

public enum GoalHostActionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case resolveApproval = "resolve_approval"
    case reconcileModelInvocation = "reconcile_model_invocation"
    case provideSignal = "provide_signal"
    case waitUntilTime = "wait_until_time"
}

public struct GoalHostAction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: GoalHostActionKind
    public let goalID: String
    public let sessionID: String
    public let waitIdentifier: String
    public let waitKind: SessionWaitKind
    public let title: String
    public let message: String
    public let resumeAt: Date?
    public let recommendedCoordinatorMethod: String
    public let recommendedGoalStoreMethod: String
    public let details: [String: JSONValue]

    public init(
        id: String,
        kind: GoalHostActionKind,
        goalID: String,
        sessionID: String,
        waitIdentifier: String,
        waitKind: SessionWaitKind,
        title: String,
        message: String,
        resumeAt: Date? = nil,
        recommendedCoordinatorMethod: String,
        recommendedGoalStoreMethod: String = "resume(goalID:)",
        details: [String: JSONValue] = [:]
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.goalID = GoalPath.sanitized(goalID)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.waitIdentifier = waitIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.waitKind = waitKind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resumeAt = resumeAt
        self.recommendedCoordinatorMethod = recommendedCoordinatorMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recommendedGoalStoreMethod = recommendedGoalStoreMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case goalID = "goal_id"
        case sessionID = "session_id"
        case waitIdentifier = "wait_identifier"
        case waitKind = "wait_kind"
        case title
        case message
        case resumeAt = "resume_at"
        case recommendedCoordinatorMethod = "recommended_coordinator_method"
        case recommendedGoalStoreMethod = "recommended_goal_store_method"
        case details
    }
}

public extension SessionWaitState {
    func nativeAgentGoalHostAction(goalID: String, sessionID: String) -> GoalHostAction {
        switch kind {
        case .approval:
            let toolName = details["toolName"]?.stringValue ?? "tool"
            let capabilityID = details["capabilityID"]?.stringValue ?? "unknown"
            return GoalHostAction(
                id: "goal-\(GoalPath.sanitized(goalID))-approval-\(identifier)",
                kind: .resolveApproval,
                goalID: goalID,
                sessionID: sessionID,
                waitIdentifier: identifier,
                waitKind: kind,
                title: "Resolve approval request",
                message: "Review and resolve approval request \(identifier) for tool \(toolName) using capability \(capabilityID).",
                recommendedCoordinatorMethod: "resolvePendingApproval(sessionID:requestID:decision:)",
                details: details
            )
        case .modelInvocation:
            let providerID = details["providerID"]?.stringValue ?? "unknown"
            return GoalHostAction(
                id: "goal-\(GoalPath.sanitized(goalID))-model-invocation-\(identifier)",
                kind: .reconcileModelInvocation,
                goalID: goalID,
                sessionID: sessionID,
                waitIdentifier: identifier,
                waitKind: kind,
                title: "Reconcile uncertain model invocation",
                message: "Verify the outcome of model invocation \(identifier) for provider \(providerID) before continuing.",
                recommendedCoordinatorMethod: "resolvePendingModelInvocation(sessionID:invocationID:resolution:)",
                details: details
            )
        case .signal:
            return GoalHostAction(
                id: "goal-\(GoalPath.sanitized(goalID))-signal-\(identifier)",
                kind: .provideSignal,
                goalID: goalID,
                sessionID: sessionID,
                waitIdentifier: identifier,
                waitKind: kind,
                title: "Provide host signal",
                message: "Provide signal \(identifier), then resume the goal loop.",
                recommendedCoordinatorMethod: "resumeSignalWait(sessionID:identifier:payload:)",
                details: details
            )
        case .time:
            let message: String
            if let resumeAt {
                message = "Wait until \(resumeAt.ISO8601Format()) before resuming the goal loop."
            } else {
                message = "Wait until the runtime time gate is satisfied before resuming the goal loop."
            }
            return GoalHostAction(
                id: "goal-\(GoalPath.sanitized(goalID))-time-\(identifier)",
                kind: .waitUntilTime,
                goalID: goalID,
                sessionID: sessionID,
                waitIdentifier: identifier,
                waitKind: kind,
                title: "Wait until scheduled resume time",
                message: message,
                resumeAt: resumeAt,
                recommendedCoordinatorMethod: "run(sessionID:) after resumeAt or resumeTimeWait(sessionID:identifier:)",
                details: details
            )
        }
    }
}
