import NativeAgentDomain
import Foundation

enum SkillWorkspaceTransactionPhase: String, Codable, Sendable {
    case prepared
    case filesApplied
    case stateSaved
}

enum SkillWorkspaceTransactionAction: Sendable {
    case filesApplied
    case stateSaved
}

struct SkillWorkspaceTransactionReducer: Sendable {
    func reduce(
        phase: SkillWorkspaceTransactionPhase,
        action: SkillWorkspaceTransactionAction
    ) throws -> SkillWorkspaceTransactionPhase {
        switch (phase, action) {
        case (.prepared, .filesApplied):
            return .filesApplied
        case (.filesApplied, .stateSaved):
            return .stateSaved
        default:
            throw AgentError.invariantViolation(
                "Invalid skill workspace transaction transition: \(phase.rawValue) -> \(action)")
        }
    }
}

struct SkillWorkspaceTransactionOperation: Codable, Equatable, Sendable {
    let index: Int
    let directoryName: String
    let originalDigest: String?
    let replacementDigest: String?
}

struct SkillWorkspaceTransactionJournal: Codable, Equatable, Sendable {
    static let currentVersion = "native-agent.skill.workspace-transaction/1"

    let version: String
    let phase: SkillWorkspaceTransactionPhase
    let previousState: SkillState
    let updatedState: SkillState
    let operations: [SkillWorkspaceTransactionOperation]

    init(
        version: String = SkillWorkspaceTransactionJournal.currentVersion,
        phase: SkillWorkspaceTransactionPhase,
        previousState: SkillState,
        updatedState: SkillState,
        operations: [SkillWorkspaceTransactionOperation]
    ) {
        self.version = version
        self.phase = phase
        self.previousState = previousState
        self.updatedState = updatedState
        self.operations = operations
    }

    func applying(_ action: SkillWorkspaceTransactionAction) throws
        -> SkillWorkspaceTransactionJournal
    {
        SkillWorkspaceTransactionJournal(
            version: version,
            phase: try SkillWorkspaceTransactionReducer().reduce(phase: phase, action: action),
            previousState: previousState,
            updatedState: updatedState,
            operations: operations
        )
    }
}

struct SkillWorkspaceTransactionFailure: Error, LocalizedError, Sendable {
    let operation: String
    let primaryFailure: String
    let recoveryFailure: String

    var errorDescription: String? {
        "Skill workspace transaction \(operation) failed: \(primaryFailure). Recovery also failed: \(recoveryFailure)"
    }
}

struct SkillWorkspaceTransactionCommittedCleanupFailure: Error, LocalizedError, Sendable {
    let cleanupFailure: String

    var errorDescription: String? {
        "Skill workspace transaction committed, but durable cleanup is pending: \(cleanupFailure)"
    }
}
