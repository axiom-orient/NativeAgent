internal import NativeAgentMemoryProjection
import Foundation

public enum MemoryError: Error, Sendable, Equatable, LocalizedError {
    case emptyCapture
    case cancelled
    case memoryFailure(code: String, message: String)
    case detailedMemoryFailure(
        operation: String,
        code: String,
        message: String,
        cause: String?,
        context: [String: String]
    )
    case underlying(String)

    public var operation: String? {
        switch self {
        case .detailedMemoryFailure(let operation, _, _, _, _): return operation
        case .memoryFailure(let code, _): return code
        case .emptyCapture: return "memory.capture"
        case .cancelled: return "memory.cancel"
        case .underlying: return nil
        }
    }

    public var cause: String? {
        if case .detailedMemoryFailure(_, _, _, let cause, _) = self { return cause }
        return nil
    }

    public var context: [String: String] {
        if case .detailedMemoryFailure(_, _, _, _, let context) = self { return context }
        return [:]
    }

    public var errorDescription: String? {
        switch self {
        case .emptyCapture:
            return "No capturable user or assistant messages were provided."
        case .cancelled:
            return "Agent memory operation was cancelled."
        case .memoryFailure(let code, let message):
            return "Agent memory failure (\(code)): \(message)"
        case .detailedMemoryFailure(let operation, let code, let message, let cause, let context):
            var result = "Agent memory failure [\(operation)] (\(code)): \(message)"
            if let cause { result += ": \(cause)" }
            if context.isEmpty == false {
                result += " [context: " + context.keys.sorted().map { "\($0)=\(context[$0]!)" }.joined(separator: ",") + "]"
            }
            return result
        case .underlying(let message):
            return message
        }
    }
}

func mapMemoryError(_ error: any Error) -> MemoryError {
    if error is CancellationError { return .cancelled }
    if let memoryError = error as? AgentMemoryError {
        if memoryError.kind == .cancelled { return .cancelled }
        return .detailedMemoryFailure(
            operation: memoryError.operation,
            code: memoryError.code,
            message: memoryError.message,
            cause: memoryError.cause,
            context: memoryError.context
        )
    }
    if let nativeAgentMemoryError = error as? MemoryError {
        return nativeAgentMemoryError
    }
    return .underlying(String(describing: error))
}

func isMemoryCancellation(_ error: any Error) -> Bool {
    mapMemoryError(error) == .cancelled
}
