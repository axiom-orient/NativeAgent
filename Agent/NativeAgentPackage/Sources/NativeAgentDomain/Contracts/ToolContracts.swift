import Foundation
import LanguageModelCore

public enum ToolFailureCode: String, Codable, Sendable, Equatable, Hashable {
    case invalidInput = "invalid_input"
    case notFound = "not_found"
    case unsupported
    case permissionDenied = "permission_denied"
    case conflict
    case temporaryFailure = "temporary_failure"
    case partialEffect = "partial_effect"
    case unknownOutcome = "unknown_outcome"
}

package extension AgentError {
    var defaultToolFailureCode: ToolFailureCode {
        switch self {
        case .invalidConfiguration, .invalidToolCall, .invariantViolation:
            return .invalidInput
        case .toolNotFound, .unsupportedSurface, .unavailableProvider:
            return .unsupported
        case .sessionNotFound, .notFound:
            return .notFound
        case .approvalDenied, .pathOutsideSandbox, .accessDenied:
            return .permissionDenied
        case .sessionBusy, .sessionWaiting:
            return .conflict
        case .persistenceFailure, .effectLedgerFailure, .modelFailure, .maxTurnsExceeded, .budgetExceeded:
            return .temporaryFailure
        }
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public let callID: String
    public let toolName: String
    public let output: JSONValue
    public let isError: Bool
    public let artifacts: [ArtifactWriteRequest]
    public let metadata: [String: JSONValue]

    public init(
        callID: String,
        toolName: String,
        output: JSONValue,
        isError: Bool = false,
        artifacts: [ArtifactWriteRequest] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.callID = callID
        self.toolName = toolName
        self.output = output
        self.isError = isError
        self.artifacts = artifacts
        self.metadata = metadata
    }

    public static func text(
        callID: String,
        toolName: String,
        content: String,
        isError: Bool = false,
        artifacts: [ArtifactWriteRequest] = [],
        metadata: [String: JSONValue] = [:]
    ) -> ToolResult {
        ToolResult(
            callID: callID,
            toolName: toolName,
            output: .object(["content": .string(content)]),
            isError: isError,
            artifacts: artifacts,
            metadata: metadata
        )
    }

    public var renderedContent: String {
        if let content = output.objectValue?["content"]?.stringValue {
            return content
        }
        return output.displayString(prettyPrinted: true)
    }

    package func applying(_ event: ToolResultEvent) -> ToolResult {
        switch event {
        case let .identityChanged(callID, toolName):
            return copy(callID: callID, toolName: toolName, metadata: metadata)
        case let .metadataChanged(metadata):
            return copy(callID: callID, toolName: toolName, metadata: metadata)
        }
    }

    private func copy(
        callID: String,
        toolName: String,
        metadata: [String: JSONValue]
    ) -> ToolResult {
        ToolResult(
            callID: callID,
            toolName: toolName,
            output: output,
            isError: isError,
            artifacts: artifacts,
            metadata: metadata
        )
    }
}

package enum ToolResultEvent: Sendable {
    case identityChanged(callID: String, toolName: String)
    case metadataChanged([String: JSONValue])
}
