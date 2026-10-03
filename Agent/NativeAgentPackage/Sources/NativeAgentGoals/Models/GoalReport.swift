public struct GoalReport: Codable, Sendable, Equatable {
    public let session: GoalSession
    public let status: GoalStatus
    public let agentSessionID: String?
    public let finalOutput: String
    public let storePath: String
    public let pendingHostAction: GoalHostAction?

    public init(session: GoalSession, storePath: String = "") {
        self.session = session
        self.status = session.status
        self.agentSessionID = session.agentSessionID
        self.finalOutput = session.turns.last?.output ?? ""
        self.storePath = storePath
        self.pendingHostAction = session.pendingHostAction
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case status
        case agentSessionID = "agent_session_id"
        case finalOutput = "final_output"
        case storePath = "store_path"
        case pendingHostAction = "pending_host_action"
    }
}
