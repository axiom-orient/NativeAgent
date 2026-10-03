import Foundation

public enum GoalError: Error, LocalizedError, Sendable, Equatable {
    case invalidGoalID
    case missingObjective
    case goalNotFound(String)
    case goalBusy(String)
    case invalidExecutionClaim(String)
    case goalDefinitionMismatch(String)
    case invalidStatusTransition(from: GoalStatus, to: GoalStatus)
    case invalidEvaluatorResponse(String)
    case storeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGoalID:
            "goal id is required"
        case .missingObjective:
            "goal objective is required"
        case .goalNotFound(let id):
            "goal \"\(id)\" was not found"
        case .goalBusy(let id):
            "goal \(id) is already executing"
        case .invalidExecutionClaim(let id):
            "goal \(id) execution claim is not owned by this store"
        case .goalDefinitionMismatch(let id):
            "goal \(id) already exists with a different objective or success condition"
        case .invalidStatusTransition(let from, let to):
            "invalid goal status transition from \(from.rawValue) to \(to.rawValue)"
        case .invalidEvaluatorResponse(let message):
            message
        case .storeFailure(let message):
            message
        }
    }
}
