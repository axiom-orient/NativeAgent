import Foundation

/// Whether an external effect is known not to have happened after an error.
///
/// The default for an unclassified error is ``outcomeUnknown``. This is
/// intentionally fail-closed: retrying a mutation whose remote outcome is
/// unknown can duplicate the mutation.
public enum EffectFailureCertainty: String, Codable, Sendable, Hashable {
    case definiteFailure
    case outcomeUnknown
}

/// Adopt this protocol on errors emitted by model clients and tool executors
/// when the implementation can prove whether the external effect occurred.
public protocol EffectFailureClassifying: Error {
    var effectFailureCertainty: EffectFailureCertainty { get }
}

/// A transport-safe failure value that preserves operation, cause, and context.
/// It does not retain an arbitrary underlying `Error`, because provider errors
/// are not necessarily `Sendable` across actor boundaries.
public struct EffectFailure: Error, EffectFailureClassifying, Sendable {
    public let effectFailureCertainty: EffectFailureCertainty
    public let operation: String
    public let cause: String
    public let context: [String: String]

    public init(
        certainty: EffectFailureCertainty,
        operation: String,
        cause: String,
        context: [String: String] = [:]
    ) {
        self.effectFailureCertainty = certainty
        self.operation = operation
        self.cause = cause
        self.context = context
    }

    public static func definiteFailure(
        operation: String,
        cause: String,
        context: [String: String] = [:]
    ) -> EffectFailure {
        EffectFailure(
            certainty: .definiteFailure,
            operation: operation,
            cause: cause,
            context: context
        )
    }

    public static func outcomeUnknown(
        operation: String,
        cause: String,
        context: [String: String] = [:]
    ) -> EffectFailure {
        EffectFailure(
            certainty: .outcomeUnknown,
            operation: operation,
            cause: cause,
            context: context
        )
    }
}

extension EffectFailure: LocalizedError {
    public var errorDescription: String? {
        var fields = ["operation=\(operation)", "cause=\(cause)"]
        fields.append(contentsOf: context.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
        return fields.joined(separator: "; ")
    }
}

/// A failure proven to have happened before a mutating tool crossed its effect boundary.
///
/// This value is package-scoped because it is an execution contract between built-in tool packs
/// and the kernel, not a host-facing public error model.
package struct ToolPreflightFailure: Error, EffectFailureClassifying, Sendable {
    package let code: ToolFailureCode
    package let operation: String
    package let cause: String
    package let context: [String: String]

    package var effectFailureCertainty: EffectFailureCertainty { .definiteFailure }

    package init(
        code: ToolFailureCode,
        operation: String,
        cause: String,
        context: [String: String] = [:]
    ) {
        self.code = code
        self.operation = operation
        self.cause = cause
        self.context = context
    }
}

extension ToolPreflightFailure: LocalizedError {
    package var errorDescription: String? {
        var fields = ["operation=\(operation)", "cause=\(cause)"]
        fields.append(contentsOf: context.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
        return fields.joined(separator: "; ")
    }
}

public enum EffectFailureClassifier {
    /// Unclassified errors are unknown by design. Providers must explicitly
    /// opt into `definiteFailure` only when no externally visible effect can
    /// have occurred.
    public static func certainty(for error: any Error) -> EffectFailureCertainty {
        if let classified = error as? any EffectFailureClassifying {
            return classified.effectFailureCertainty
        }
        return .outcomeUnknown
    }
}
