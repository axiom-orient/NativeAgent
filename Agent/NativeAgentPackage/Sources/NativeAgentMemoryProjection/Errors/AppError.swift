import Foundation

enum ExitCode: Int32, Sendable {
    case ok = 0
    case validation = 1
    case workspace = 2
    case storage = 3
    case llm = 4
    case internalError = 5
}
struct AppError: Error, CustomStringConvertible, Equatable, Sendable {
    let exitCode: ExitCode
    let code: String
    let message: String
    let cause: String?
    let operation: String
    let context: [String: String]

    init(
        _ e: ExitCode,
        _ c: String,
        _ m: String,
        _ cause: (any Error)? = nil,
        operation: String? = nil,
        context: [String: String] = [:]
    ) {
        exitCode = e
        code = c
        message = m
        self.cause = cause.map { String(describing: $0) }
        self.operation = operation ?? c
        self.context = context
    }

    var description: String {
        guard let cause else { return "\(code): \(message)" }
        return "\(code): \(message): \(cause)"
    }

    static func validation(_ c: String, _ m: String, _ e: (any Error)? = nil) -> AppError {
        AppError(.validation, c, m, e)
    }

    static func workspace(_ c: String, _ m: String, _ e: (any Error)? = nil) -> AppError {
        AppError(.workspace, c, m, e)
    }

    static func storage(_ c: String, _ m: String, _ e: (any Error)? = nil) -> AppError {
        AppError(.storage, c, m, e)
    }

    static func internalError(_ c: String, _ m: String, _ e: (any Error)? = nil) -> AppError {
        AppError(.internalError, c, m, e)
    }
}

func asAppError(_ e: (any Error)?) -> AppError {
    (e as? AppError)
        ?? AppError.internalError(
            "internal_error", e == nil ? "unknown error" : "unexpected internal failure", e)
}
