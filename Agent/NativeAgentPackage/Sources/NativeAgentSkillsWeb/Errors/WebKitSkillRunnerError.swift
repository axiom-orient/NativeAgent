import Foundation

#if canImport(WebKit)
import WebKit

public enum WebKitSkillRunnerError: Error, Equatable, Sendable, LocalizedError {
    case policyViolation(String)
    case inputTooLarge(Int, limit: Int)
    case outputTooLarge(Int, limit: Int)
    case timeout
    case missingFunction
    case policyGuardUnavailable
    case invalidJSON
    case fileAccessDenied(String)
    case navigationBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .policyViolation(let message):
            return "WebKit skill policy violation: \(message)"
        case .inputTooLarge(let size, let limit):
            return "WebKit skill input was \(size) bytes, exceeding the \(limit) byte limit."
        case .outputTooLarge(let size, let limit):
            return "WebKit skill output was \(size) bytes, exceeding the \(limit) byte limit."
        case .timeout:
            return "WebKit skill script timed out."
        case .missingFunction:
            return "WebKit skill script did not define window.\(WebKitSkillScriptContract.entrypoint)."
        case .policyGuardUnavailable:
            return "WebKit skill policy guard was not installed."
        case .invalidJSON:
            return "WebKit skill script returned invalid JSON."
        case .fileAccessDenied(let path):
            return "WebKit skill file access was denied: \(path)"
        case .navigationBlocked(let destination):
            return "WebKit skill navigation was blocked by policy: \(destination)"
        }
    }
}
#endif
