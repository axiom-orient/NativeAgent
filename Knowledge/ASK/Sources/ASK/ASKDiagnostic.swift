import Foundation

public enum ASKErrorCode: String, Codable, Equatable, Sendable {
    case missingField
    case invalidRequest
    case unsupported
    case integrityViolation
    case notFound
    case conflict
    case permissionDenied
    case storageFailure
    case derivedOutputFailure
    case partialEffect
    case unknownOutcome
    case underlying
}

public enum ASKOperation: String, Codable, Equatable, Sendable {
    case plan
    case dryRun
    case apply
    case query
    case repair
}

public enum ASKRecoveryAction: String, Codable, Equatable, Sendable {
    case correctInput
    case retry
    case repairDerivedOutput
    case rebuildStorage
    case inspectOperation
    case inspectStorage
    case none
}

/// Stable, machine-readable failure exposed by the typed product boundary.
public struct ASKDiagnostic: Error, Codable, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public let code: ASKErrorCode
    public let operation: ASKOperation
    public let message: String
    public let context: [String: String]
    public let recovery: ASKRecoveryAction

    public init(
        code: ASKErrorCode,
        operation: ASKOperation,
        message: String,
        context: [String: String] = [:],
        recovery: ASKRecoveryAction = .none
    ) {
        self.code = code
        self.operation = operation
        self.message = message
        self.context = context
        self.recovery = recovery
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
