import Foundation

struct SkillTemporaryWorkspaceFailure: Error, LocalizedError, Sendable {
    let operation: String
    let operationCommitted: Bool
    let operationFailure: String?
    let cleanupFailure: String

    var errorDescription: String? {
        if let operationFailure {
            return "\(operation) failed: \(operationFailure). Temporary workspace cleanup also failed: \(cleanupFailure)"
        }
        let outcome = operationCommitted ? "committed" : "completed"
        return "\(operation) \(outcome), but temporary workspace cleanup failed: \(cleanupFailure)"
    }
}

struct SkillTemporaryWorkspaceCleanup {
    let fileManager: FileManager

    func finish(
        _ temporaryRoot: URL,
        operation: String,
        operationFailure: (any Error)?,
        operationCommitted: Bool
    ) throws {
        do {
            if fileManager.fileExists(atPath: temporaryRoot.path) {
                try fileManager.removeItem(at: temporaryRoot)
            }
        } catch {
            throw SkillTemporaryWorkspaceFailure(
                operation: operation,
                operationCommitted: operationCommitted,
                operationFailure: operationFailure?.localizedDescription,
                cleanupFailure: error.localizedDescription
            )
        }
        if let operationFailure {
            throw operationFailure
        }
    }
}
