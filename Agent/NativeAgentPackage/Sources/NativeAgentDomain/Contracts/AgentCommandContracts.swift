/// Caller-owned identity for one durable Agent command.
///
/// This is a provider- and runtime-neutral value. The runtime validates it
/// against the authoritative session revision before applying a transition.
public struct AgentCommandIdentity: Codable, Sendable, Equatable {
    public let operationID: String
    public let expectedRevision: Int64

    public init(operationID: String, expectedRevision: Int64) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
    }
}

/// Receipt for a command recorded by the durable session store.
///
/// The receipt is a result value, not mutable runtime state. Its revision is
/// the authoritative revision produced by the accepted transition.
public struct AgentCommandReceipt: Codable, Sendable, Equatable {
    public let operationID: String
    public let sessionID: String
    public let revision: Int64

    public init(operationID: String, sessionID: String, revision: Int64) {
        self.operationID = operationID
        self.sessionID = sessionID
        self.revision = revision
    }
}
