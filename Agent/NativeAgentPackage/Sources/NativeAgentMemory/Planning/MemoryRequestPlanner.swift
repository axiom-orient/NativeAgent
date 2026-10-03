import NativeAgentDomain
internal import NativeAgentMemoryProjection
import Foundation

struct MemoryRequestPlan: Sendable, Equatable {
    var scope: MemoryScope
    var query: String?
    var captureTurns: [AgentMemoryTurn]
}

enum MemoryRequestPlanner {
    static let profileIDMetadataKey = "native-agent.memory.profile_id"
    static let userIDMetadataKey = "native-agent.memory.user_id"
    static let sessionKeyMetadataKey = "native-agent.memory.session_key"
    static let memoryDisabledMetadataKey = "native-agent.memory.disabled"
    static let contextDisabledMetadataKey = "native-agent.memory.context_disabled"
    static let captureDisabledMetadataKey = "native-agent.memory.capture_disabled"
    static let contextAttachedMetadataKey = "native-agent.memory.context_attached"
    static let contextMessageMetadataKey = "native-agent.memory.context"
    static let consolidationMetadataKey = "native-agent.memory.consolidation"

    static func makePlan(
        request: ModelRequest,
        response: ModelTurn? = nil,
        responseCreatedAt: Date = DeterministicCoreDefaults.timestamp,
        defaultProfileID: String,
        defaultUserID: String,
        defaultNamespace: String = ""
    ) -> MemoryRequestPlan {
        let scope = makeScope(
            request: request,
            defaultProfileID: defaultProfileID,
            defaultUserID: defaultUserID,
            defaultNamespace: defaultNamespace
        )
        let query = latestUserMessage(in: request.messages)?.content
        let captureMessages = capturableMessages(
            request: request,
            response: response,
            responseCreatedAt: responseCreatedAt
        )
        return MemoryRequestPlan(
            scope: scope,
            query: normalizedOptional(query),
            captureTurns: captureMessages.compactMap { agentMemoryTurn(from: $0, scope: scope, request: request) }
        )
    }

    static func makeCapturePlan(
        scope inputScope: MemoryScope,
        messages: [AgentMessage],
        defaultProfileID: String,
        defaultUserID: String,
        defaultNamespace: String = ""
    ) -> MemoryRequestPlan {
        let scope = makeScope(
            inputScope: inputScope,
            defaultProfileID: defaultProfileID,
            defaultUserID: defaultUserID,
            defaultNamespace: defaultNamespace
        )
        let request = ModelRequest(
            sessionID: scope.sessionKey,
            messages: messages,
            tools: []
        )
        let query = latestUserMessage(in: messages)?.content
        return MemoryRequestPlan(
            scope: scope,
            query: normalizedOptional(query),
            captureTurns: messages.compactMap { agentMemoryTurn(from: $0, scope: scope, request: request) }
        )
    }

    static func augment(
        request: ModelRequest,
        with context: MemoryContext,
        createdAt: Date
    ) -> ModelRequest {
        guard alreadyContainsMemoryContext(request) == false else {
            return request
        }
        guard let fragment = context.systemPromptFragment else {
            return request
        }

        let memoryMessage = AgentMessage(
            id: stableMessageID(sessionID: request.sessionID, content: fragment),
            role: .system,
            content: fragment,
            createdAt: createdAt,
            metadata: [contextMessageMetadataKey: .bool(true)]
        )
        var messages = request.messages
        let insertionIndex = messages.firstIndex { $0.role != .system } ?? messages.endIndex
        messages.insert(memoryMessage, at: insertionIndex)
        let metadata = request.metadata.merging(
            [
                contextAttachedMetadataKey: .bool(true),
                "native-agent.memory.match_count": .integer(Int64(context.matches.count)),
            ]
        ) { _, new in new }
        return request.applying(.contentsChanged(messages: messages, metadata: metadata))
    }

    static func memoryDisabled(in request: ModelRequest) -> Bool {
        metadataBool(request.metadata[memoryDisabledMetadataKey])
            || metadataBool(request.metadata[consolidationMetadataKey])
    }

    static func contextDisabled(in request: ModelRequest) -> Bool {
        memoryDisabled(in: request)
            || metadataBool(request.metadata[contextDisabledMetadataKey])
            || alreadyContainsMemoryContext(request)
    }

    static func captureDisabled(in request: ModelRequest) -> Bool {
        memoryDisabled(in: request)
            || metadataBool(request.metadata[captureDisabledMetadataKey])
    }

    private static func makeScope(
        request: ModelRequest,
        defaultProfileID: String,
        defaultUserID: String,
        defaultNamespace: String
    ) -> MemoryScope {
        makeScope(
            inputScope: MemoryScope(
                profileID: metadataString(request.metadata[profileIDMetadataKey]) ?? "",
                userID: metadataString(request.metadata[userIDMetadataKey]) ?? "",
                sessionKey: metadataString(request.metadata[sessionKeyMetadataKey]) ?? request.sessionID
            ),
            defaultProfileID: defaultProfileID,
            defaultUserID: defaultUserID,
            defaultNamespace: defaultNamespace
        )
    }

    private static func makeScope(
        inputScope: MemoryScope,
        defaultProfileID: String,
        defaultUserID: String,
        defaultNamespace: String
    ) -> MemoryScope {
        MemoryScope(
            profileID: normalizedOptional(inputScope.profileID) ?? defaultProfileID,
            userID: normalizedOptional(inputScope.userID) ?? defaultUserID,
            sessionKey: normalizedOptional(inputScope.sessionKey) ?? "",
            namespace: normalizedOptional(inputScope.namespace) ?? defaultNamespace
        )
    }

    private static func latestUserMessage(in messages: [AgentMessage]) -> AgentMessage? {
        messages.reversed().first { $0.role == .user && normalizedOptional($0.content) != nil }
    }

    private static func capturableMessages(
        request: ModelRequest,
        response: ModelTurn?,
        responseCreatedAt: Date
    ) -> [AgentMessage] {
        var result: [AgentMessage] = []
        if let user = latestUserMessage(in: request.messages) {
            result.append(user)
        }
        if let response, normalizedOptional(response.content) != nil {
            result.append(
                AgentMessage(
                    role: .assistant,
                    content: response.content,
                    createdAt: responseCreatedAt,
                    metadata: response.metadata
                )
            )
        }
        return result
    }

    private static func agentMemoryTurn(
        from message: AgentMessage,
        scope: MemoryScope,
        request: ModelRequest
    ) -> AgentMemoryTurn? {
        guard let role = AgentMemoryRole(message.role) else { return nil }
        guard normalizedOptional(message.content) != nil else { return nil }
        let admission = MemoryCaptureAdmission.flags(for: message.metadata)
        return AgentMemoryTurn(
            role: role,
            content: message.content,
            timestampMilliseconds: timestampMilliseconds(message.createdAt),
            sessionID: request.sessionID,
            sessionKey: scope.sessionKey,
            isHidden: admission.isHidden,
            isSensitive: admission.isSensitive
        )
    }

    private static func alreadyContainsMemoryContext(_ request: ModelRequest) -> Bool {
        if metadataBool(request.metadata[contextAttachedMetadataKey]) { return true }
        return request.messages.contains { metadataBool($0.metadata[contextMessageMetadataKey]) }
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func timestampMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }


    private static func metadataString(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !string.isEmpty
        else {
            return nil
        }
        return string
    }

    private static func metadataBool(_ value: JSONValue?) -> Bool {
        guard case .bool(let bool)? = value else { return false }
        return bool
    }

    private static func stableMessageID(sessionID: String, content: String) -> String {
        let payload = "\(sessionID)\u{1f}\(content)"
        return "native-agent-memory-context-\(fnv1a64Hex(payload))"
    }

    private static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
