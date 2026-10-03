import LanguageModelCore
import Foundation

public enum ToolEffectDecisionKind: String, Codable, Sendable, Equatable {
    case execute
    case replay
    case block
}

public struct ToolEffectDecisionEvent: Codable, Sendable, Equatable {
    public let sessionID: String
    public let callID: String
    public let toolName: String
    public let capabilityID: CapabilityID
    public let decision: ToolEffectDecisionKind
    public let reason: String?
    public let createdAt: Date

    public init(
        sessionID: String,
        callID: String,
        toolName: String,
        capabilityID: CapabilityID,
        decision: ToolEffectDecisionKind,
        reason: String? = nil,
        createdAt: Date = DeterministicCoreDefaults.timestamp
    ) {
        self.sessionID = sessionID
        self.callID = callID
        self.toolName = toolName
        self.capabilityID = capabilityID
        self.decision = decision
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct ToolExecutionDurationEvent: Codable, Sendable, Equatable {
    public let sessionID: String
    public let callID: String
    public let toolName: String
    public let capabilityID: CapabilityID
    public let durationSeconds: TimeInterval
    public let succeeded: Bool
    public let createdAt: Date

    public init(
        sessionID: String,
        callID: String,
        toolName: String,
        capabilityID: CapabilityID,
        durationSeconds: TimeInterval,
        succeeded: Bool,
        createdAt: Date = DeterministicCoreDefaults.timestamp
    ) {
        self.sessionID = sessionID
        self.callID = callID
        self.toolName = toolName
        self.capabilityID = capabilityID
        self.durationSeconds = durationSeconds
        self.succeeded = succeeded
        self.createdAt = createdAt
    }
}

/// Transient model-stream telemetry. Only the terminal `ModelTurn` is durable;
/// observers can use ordered deltas for UI without changing transcript state.
public struct ModelInvocationStreamEvent: Sendable, Equatable {
    public let sessionID: String
    public let providerID: String
    public let event: ModelEvent
    public let createdAt: Date

    public init(
        sessionID: String,
        providerID: String,
        event: ModelEvent,
        createdAt: Date = DeterministicCoreDefaults.timestamp
    ) {
        self.sessionID = sessionID
        self.providerID = providerID
        self.event = event
        self.createdAt = createdAt
    }
}

public protocol RuntimeObserver: Sendable {
    func record(modelStream event: ModelInvocationStreamEvent) async
    func record(effectDecision event: ToolEffectDecisionEvent) async
    func record(toolExecutionDuration event: ToolExecutionDurationEvent) async
}

public extension RuntimeObserver {
    func record(modelStream event: ModelInvocationStreamEvent) async {}
}
