import LanguageModelCore
import Foundation

public enum AgentError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case invalidToolCall(String)
    case toolNotFound(String)
    case approvalDenied(String)
    case sessionNotFound(String)
    case sessionBusy(String)
    case sessionWaiting(String)
    case persistenceFailure(String)
    case effectLedgerFailure(String)
    case modelFailure(String)
    case accessDenied(String)
    case unsupportedSurface(String)
    case pathOutsideSandbox(String)
    case invariantViolation(String)
    case maxTurnsExceeded(Int)
    case budgetExceeded(String)
    case unavailableProvider(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .invalidToolCall(let message),
             .toolNotFound(let message),
             .approvalDenied(let message),
             .persistenceFailure(let message),
             .effectLedgerFailure(let message),
             .modelFailure(let message),
             .accessDenied(let message),
             .unsupportedSurface(let message),
             .pathOutsideSandbox(let message),
             .invariantViolation(let message),
             .budgetExceeded(let message),
             .unavailableProvider(let message),
             .notFound(let message):
            return message
        case .sessionNotFound(let sessionID):
            return "Session not found: \(sessionID)"
        case .sessionBusy(let sessionID):
            return "Session is already running: \(sessionID)"
        case .sessionWaiting(let sessionID):
            return "Session is waiting for external resolution: \(sessionID)"
        case .maxTurnsExceeded(let turns):
            return "Maximum turn count exceeded: \(turns)"
        }
    }
}
