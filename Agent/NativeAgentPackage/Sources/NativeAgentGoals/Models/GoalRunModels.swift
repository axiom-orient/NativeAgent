import NativeAgentDomain

public struct GoalRunResult: Codable, Sendable, Equatable {
    public let sessionID: String
    public let status: SessionStatus
    public let output: String
    public let errorMessage: String?
    public let waitState: SessionWaitState?
    public let metadata: [String: JSONValue]

    public init(
        sessionID: String,
        status: SessionStatus,
        output: String,
        errorMessage: String? = nil,
        waitState: SessionWaitState? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.sessionID = sessionID.trimmedForNativeAgentGoal
        self.status = status
        self.output = output
        self.errorMessage = errorMessage?.trimmedForNativeAgentGoal.nonEmptyForNativeAgentGoal
        self.waitState = waitState
        self.metadata = metadata
    }

    public init(snapshot: SessionSnapshot, errorMessage: String? = nil) {
        self.init(
            sessionID: snapshot.sessionID,
            status: snapshot.status,
            output: snapshot.currentTurnAssistantContent ?? "",
            errorMessage: errorMessage,
            waitState: snapshot.waitState,
            metadata: snapshot.metadata
        )
    }

    package func validateState() throws {
        switch (status, waitState) {
        case (.waiting, .some), (.running, .none), (.completed, .none), (.failed, .none):
            break
        case (.waiting, .none):
            throw AgentError.modelFailure(
                "Goal run result for session \(sessionID) is waiting without a wait state."
            )
        case (.running, .some), (.completed, .some), (.failed, .some):
            throw AgentError.modelFailure(
                "Goal run result for session \(sessionID) has a wait state while status is \(status.rawValue)."
            )
        }
        if let waitState {
            switch (waitState.kind, waitState.resumeAt) {
            case (.time, .some), (.approval, .none), (.modelInvocation, .none), (.signal, .none):
                break
            case (.time, .none):
                throw AgentError.modelFailure(
                    "Goal run result for session \(sessionID) has a time wait without a resume deadline."
                )
            case (.approval, .some), (.modelInvocation, .some), (.signal, .some):
                throw AgentError.modelFailure(
                    "Goal run result for session \(sessionID) has a non-time wait with a resume deadline."
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case output
        case errorMessage = "error_message"
        case waitState = "wait_state"
        case metadata
    }
}
