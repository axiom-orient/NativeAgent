import LanguageModelCore
import Foundation

package struct OperationAndCleanupFailure: Error, LocalizedError, Sendable, Equatable {
    package let operationFailure: String
    package let cleanupFailure: String

    package init(operationFailure: String, cleanupFailure: String) {
        self.operationFailure = operationFailure
        self.cleanupFailure = cleanupFailure
    }

    package var errorDescription: String? {
        "operation failed [\(operationFailure)]; cleanup also failed [\(cleanupFailure)]"
    }
}

package enum OperationCleanupCompletionPolicy {
    package static func resolve<Value>(
        operation: Result<Value, any Error>,
        cleanupError: (any Error)?
    ) throws -> Value {
        switch (operation, cleanupError) {
        case (.success(let value), nil):
            return value
        case (.failure(let operationError), nil):
            throw operationError
        case (.success, let cleanupError?):
            throw cleanupError
        case (.failure(let operationError), let cleanupError?):
            throw OperationAndCleanupFailure(
                operationFailure: String(describing: operationError),
                cleanupFailure: String(describing: cleanupError)
            )
        }
    }
}
