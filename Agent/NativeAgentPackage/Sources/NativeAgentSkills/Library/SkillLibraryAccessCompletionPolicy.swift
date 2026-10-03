import Foundation

enum SkillLibraryAccessOperationOutcome<Value> {
    case success(Value)
    case failure(any Error)
}

struct SkillLibraryAccessCompletionFailure: Error, Sendable, Equatable, LocalizedError {
    let operationFailure: String
    let releaseFailure: String

    var errorDescription: String? {
        "Skill library operation failed [\(operationFailure)]; access release also failed [\(releaseFailure)]"
    }
}

struct SkillLibraryAccessCompletionPolicy: Sendable {
    func resolve<Value>(
        outcome: SkillLibraryAccessOperationOutcome<Value>,
        releaseError: (any Error)?
    ) throws -> Value {
        switch (outcome, releaseError) {
        case (.success(let value), nil):
            return value
        case (.failure(let operationError), nil):
            throw operationError
        case (.success, let releaseError?):
            throw releaseError
        case (.failure(let operationError), let releaseError?):
            throw SkillLibraryAccessCompletionFailure(
                operationFailure: String(describing: operationError),
                releaseFailure: String(describing: releaseError)
            )
        }
    }
}
