import NativeAgentDomain

enum PendingToolCallIndex {
    static func calls(in snapshot: SessionSnapshot) throws -> [ToolCall] {
        let resolvedCallIDs = Set(
            snapshot.messages
                .filter { $0.role == .tool }
                .compactMap(\.toolCallID)
        )

        var pending: [ToolCall] = []
        var callsByID: [String: ToolCall] = [:]
        for message in snapshot.messages where message.role == .assistant {
            for call in message.toolCalls {
                if let existing = callsByID[call.id] {
                    guard existing == call else {
                        throw AgentError.invariantViolation(
                            "Session \(snapshot.sessionID) reuses tool call identifier \(call.id) for a different call."
                        )
                    }
                    continue
                }
                callsByID[call.id] = call
                if resolvedCallIDs.contains(call.id) == false {
                    pending.append(call)
                }
            }
        }
        return pending
    }

    static func call(
        id: String,
        in snapshot: SessionSnapshot
    ) throws -> ToolCall {
        guard let call = try calls(in: snapshot).first(where: { $0.id == id }) else {
            throw AgentError.notFound("No pending tool call with identifier \(id).")
        }
        return call
    }
}
