import NativeAgentDomain

/// One durable Agent advancement result.
///
/// `output` is derived from the transcript and is not a second source of truth.
public struct AgentRun: Sendable, Equatable {
    public let snapshot: SessionSnapshot

    public init(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
    }

    public var sessionID: String { snapshot.sessionID }
    public var status: SessionStatus { snapshot.status }
    public var messages: [AgentMessage] { snapshot.messages }
    public var artifacts: [ArtifactRecord] { snapshot.artifacts }

    public var output: String? {
        snapshot.currentTurnAssistantContent
    }
}
