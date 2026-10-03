import Foundation
import NativeAgentDomain
import LanguageModelCore
import NativeAgentExecution

/// Public, provider-neutral description of a remote model invocation whose
/// outcome is unknown after interruption.
public struct AgentPendingModelInvocation: Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let providerID: String
    public let snapshotRevision: Int64
    public let request: ModelRequest
    public let createdAt: Date

    package init(_ invocation: PendingModelInvocation) {
        self.id = invocation.id
        self.sessionID = invocation.sessionID
        self.providerID = invocation.providerID
        self.snapshotRevision = invocation.snapshotRevision
        self.request = invocation.request
        self.createdAt = invocation.createdAt
    }
}

/// Application-owned resolution for an uncertain remote model invocation.
/// NativeAgent never performs a blind retry without the explicit `.retry` decision.
public enum AgentModelInvocationResolution: Sendable, Equatable {
    case completed(ModelTurn)
    case retry(reason: String)
    case failed(String)

    package var runtimeValue: ModelInvocationRecoveryResolution {
        switch self {
        case .completed(let turn):
            .completed(turn)
        case .retry(let reason):
            .retry(reason: reason)
        case .failed(let reason):
            .failed(reason)
        }
    }
}

public enum AgentToolEffectDisposition: String, Codable, Sendable, Equatable {
    case executable
    case replayable
    case reconciliationRequired = "reconciliation_required"
    case invalid

    package init(_ value: ToolEffectRecoveryDisposition) {
        switch value {
        case .executable:
            self = .executable
        case .replayable:
            self = .replayable
        case .reconciliationRequired:
            self = .reconciliationRequired
        case .invalid:
            self = .invalid
        }
    }
}

/// One pending tool call and its durable effect receipt classification.
public struct AgentToolEffectRecoveryItem: Sendable, Equatable {
    public let call: ToolCall
    public let definition: ToolDefinition?
    public let effectRecord: EffectRecord?
    public let disposition: AgentToolEffectDisposition
    public let detail: String

    package init(_ item: ToolEffectRecoveryItem) {
        self.call = item.call
        self.definition = item.definition
        self.effectRecord = item.effectRecord
        self.disposition = AgentToolEffectDisposition(item.disposition)
        self.detail = item.detail
    }
}

/// Stable, side-effect-free inspection of pending tool work.
public struct AgentRecoveryInspection: Sendable, Equatable {
    public let snapshot: SessionSnapshot
    public let pendingToolEffects: [AgentToolEffectRecoveryItem]

    package init(_ inspection: SessionRecoveryInspection) {
        self.snapshot = inspection.snapshot
        self.pendingToolEffects = inspection.pendingToolEffects.map(AgentToolEffectRecoveryItem.init)
    }

    public var requiresHostReconciliation: Bool {
        pendingToolEffects.contains { $0.disposition == .reconciliationRequired }
    }
}

/// Host-verified outcome for a mutating tool effect that may already have
/// occurred outside the process.
public enum AgentToolEffectResolution: Sendable, Equatable {
    case completed(ToolResult)
    case failed(String)

    package var runtimeValue: ToolEffectRecoveryResolution {
        switch self {
        case .completed(let result):
            .completed(result)
        case .failed(let reason):
            .failed(reason)
        }
    }
}


/// Package-only provider-independent recovery surface used by higher composition layers.
/// It owns no state and delegates to the same execution-module recovery readers as `Agent`.
package struct AgentRecoveryAccess: Sendable {
    private let reader: SessionRecoveryReader

    package init(
        storage: AgentStorage,
        capabilities: [any AgentCapability],
        toolPacks: [any ToolPack],
        tools: [any ToolExecutor],
        contractOnlyDefinitions: [ToolDefinition] = [],
        configuration: AgentConfiguration
    ) throws {
        self.reader = try SessionRecoveryReader(
            runtimeStore: storage.store,
            executionClaimStore: storage.executionClaimStore,
            executionAuthority: storage.executionAuthority,
            toolPacks: Agent.assembledToolPacks(
                capabilities: capabilities,
                toolPacks: toolPacks,
                tools: tools
            ),
            contractOnlyDefinitions: contractOnlyDefinitions,
            configuration: configuration.recoveryRuntimeConfiguration
        )
    }

    package func pendingApproval(sessionID: String) async throws -> ApprovalRequest? {
        try await reader.pendingApprovalRequest(sessionID: sessionID)
    }

    package func pendingModelInvocation(
        sessionID: String
    ) async throws -> AgentPendingModelInvocation? {
        try await reader.pendingModelInvocation(sessionID: sessionID)
            .map(AgentPendingModelInvocation.init)
    }

    package func inspectRecovery(sessionID: String) async throws -> AgentRecoveryInspection {
        AgentRecoveryInspection(try await reader.inspectRecovery(sessionID: sessionID))
    }

    package func resolveModelInvocation(
        sessionID: String,
        invocationID: String,
        resolution: AgentModelInvocationResolution
    ) async throws -> (run: AgentRun, requiresContinuation: Bool) {
        let reconciliation = try await reader.resolveModelInvocation(
            sessionID: sessionID,
            invocationID: invocationID,
            resolution: resolution.runtimeValue
        )
        return (AgentRun(snapshot: reconciliation.snapshot), reconciliation.requiresContinuation)
    }

    package func resolveToolEffect(
        sessionID: String,
        callID: String,
        resolution: AgentToolEffectResolution
    ) async throws -> AgentRun {
        AgentRun(
            snapshot: try await reader.resolveToolEffect(
                sessionID: sessionID,
                callID: callID,
                resolution: resolution.runtimeValue
            )
        )
    }

    @discardableResult
    package func retryPendingExecutionClaimRelease(sessionID: String) async throws -> Bool {
        try await reader.retryPendingExecutionClaimRelease(sessionID: sessionID)
    }

    package func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        try await reader.loadArtifact(sessionID: sessionID, artifactID: artifactID)
    }

    package func toolEffect(sessionID: String, callID: String) async throws -> EffectRecord? {
        try await reader.toolEffect(sessionID: sessionID, callID: callID)
    }
}
