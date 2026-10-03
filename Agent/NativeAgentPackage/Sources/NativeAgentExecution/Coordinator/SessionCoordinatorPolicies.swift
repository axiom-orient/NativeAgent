import Foundation
import NativeAgentDomain

struct SessionStartInput: Sendable {
    let sessionID: String
    let userMessage: AgentMessage
    let systemPrompt: String?
    let title: String?
    let modelID: String?
    let metadata: [String: JSONValue]
    let providerID: String?
    let timestamp: Date

    init(
        sessionID: String,
        userMessage: AgentMessage,
        systemPrompt: String?,
        title: String?,
        modelID: String?,
        metadata: [String: JSONValue],
        providerID: String?,
        timestamp: Date
    ) {
        self.sessionID = sessionID
        self.userMessage = userMessage
        self.systemPrompt = systemPrompt
        self.title = title
        self.modelID = modelID
        self.metadata = metadata
        self.providerID = providerID
        self.timestamp = timestamp
    }

    init(
        sessionID: String,
        userPrompt: String,
        systemPrompt: String?,
        title: String?,
        modelID: String?,
        metadata: [String: JSONValue],
        requestMetadata: [String: JSONValue],
        providerID: String?,
        timestamp: Date
    ) {
        self.init(
            sessionID: sessionID,
            userMessage: AgentMessage(
                id: "session-start-user",
                role: .user,
                content: userPrompt,
                createdAt: timestamp,
                metadata: requestMetadata
            ),
            systemPrompt: systemPrompt,
            title: title,
            modelID: modelID,
            metadata: metadata,
            providerID: providerID,
            timestamp: timestamp
        )
    }
}

enum SessionSnapshotTransitions {
    static func makeStartedSession(
        input: SessionStartInput,
        idGenerator: @Sendable () -> String
    ) -> SessionSnapshot {
        var messages: [AgentMessage] = []
        if let systemPrompt = normalizedSystemPrompt(input.systemPrompt) {
            messages.append(
                AgentMessage(
                    id: idGenerator(),
                    role: .system,
                    content: systemPrompt,
                    createdAt: input.timestamp
                )
            )
        }
        messages.append(
            AgentMessage(
                id: input.userMessage.id,
                role: input.userMessage.role,
                contentParts: input.userMessage.contentParts,
                createdAt: input.timestamp,
                toolCallID: input.userMessage.toolCallID,
                toolName: input.userMessage.toolName,
                toolCalls: input.userMessage.toolCalls,
                metadata: input.userMessage.metadata
            )
        )
        return SessionSnapshot(
            sessionID: input.sessionID,
            title: input.title,
            status: .running,
            createdAt: input.timestamp,
            updatedAt: input.timestamp,
            messages: messages,
            providerID: input.providerID,
            modelID: input.modelID,
            metadata: input.metadata,
            waitState: nil
        )
    }

    static func appendingUserPrompt(
        _ userPrompt: String,
        requestMetadata: [String: JSONValue],
        to snapshot: SessionSnapshot,
        messageID: String,
        timestamp: Date
    ) throws -> SessionReduction {
        try appendingUserMessage(
            AgentMessage(
                id: messageID,
                role: .user,
                content: userPrompt,
                createdAt: timestamp,
                metadata: requestMetadata
            ),
            to: snapshot,
            timestamp: timestamp
        )
    }

    static func appendingUserMessage(
        _ message: AgentMessage,
        to snapshot: SessionSnapshot,
        timestamp: Date
    ) throws -> SessionReduction {
        try SessionReducer.reduce(
            .appendUserPrompt(
                message,
                updatedAt: timestamp
            ),
            state: snapshot
        )
    }

    static func replacingMetadata(
        _ metadata: [String: JSONValue],
        in snapshot: SessionSnapshot
    ) throws -> SessionSnapshot {
        try SessionReducer.reduce(.replaceMetadata(metadata), state: snapshot).snapshot
    }

    static func resumeIfNeeded(
        _ snapshot: SessionSnapshot,
        timestamp: Date
    ) throws -> SessionReduction? {
        guard snapshot.status == .failed else {
            return nil
        }
        return try SessionReducer.reduce(.resume(updatedAt: timestamp), state: snapshot)
    }

    static func enteringWait(
        _ waitState: SessionWaitState,
        in snapshot: SessionSnapshot,
        timestamp: Date
    ) throws -> SessionReduction {
        try SessionReducer.reduce(
            .enterWait(waitState, updatedAt: timestamp),
            state: snapshot
        )
    }

    static func clearingWait(
        _ snapshot: SessionSnapshot,
        timestamp: Date
    ) throws -> SessionReduction {
        try SessionReducer.reduce(.clearWait(updatedAt: timestamp), state: snapshot)
    }

    static func receivingSignal(
        _ signal: SessionSignal,
        in snapshot: SessionSnapshot,
        timestamp: Date
    ) throws -> SessionReduction {
        try SessionReducer.reduce(
            .receiveSignal(signal, updatedAt: timestamp),
            state: snapshot
        )
    }

    static func resolvingWait(
        _ snapshot: SessionSnapshot,
        signal: SessionSignal? = nil,
        responseContinuation: ResponseContinuationPolicy?,
        timestamp: Date
    ) throws -> SessionReduction {
        try SessionReducer.reduce(
            .resolveWaitAndUpdateMetadata(
                signal: signal,
                metadata: ResponseContinuationMetadata.applying(
                    policy: responseContinuation,
                    to: snapshot.metadata
                ),
                updatedAt: timestamp
            ),
            state: snapshot
        )
    }

    static func timingOutWait(
        _ snapshot: SessionSnapshot,
        identifier: String,
        reason: String,
        timestamp: Date
    ) throws -> SessionReduction {
        guard snapshot.status == .waiting,
              snapshot.waitState?.identifier == identifier else {
            throw AgentError.sessionWaiting(snapshot.sessionID)
        }
        return try SessionReducer.reduce(
            .fail(
                SessionFailure(
                    code: "wait_timed_out",
                    message: reason,
                    occurredAt: timestamp,
                    details: ["identifier": .string(identifier)]
                ),
                updatedAt: timestamp,
                reason: .waitTimedOut
            ),
            state: snapshot
        )
    }

    private static func normalizedSystemPrompt(_ prompt: String?) -> String? {
        guard let prompt else {
            return nil
        }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
    }
}
