import Foundation

public struct AgentMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    public let id: String
    public let role: Role
    /// A deterministic text projection of `contentParts`.
    public let content: String
    public let contentParts: [ModelContentPart]
    public let createdAt: Date
    public let toolCallID: String?
    public let toolName: String?
    public let toolCalls: [ToolCall]
    public let metadata: [String: JSONValue]
    public let usage: ModelUsage?
    public let responseID: String?
    public let reasoningSummary: String?
    public let stopReason: ModelStopReason?

    /// Exact text supplied to model providers. Tool messages preserve their
    /// human/UI `content`, while the model sees the durable structured result
    /// assembled from the already-persisted output, error flag, metadata, and
    /// artifact references. Text-only tool messages without structured
    /// runtime metadata supply their original content directly.
    public func modelVisibleContent() throws -> String {
        guard role == .tool else {
            return content
        }
        let hasRuntimeResult = metadata["output"] != nil
            || metadata["isError"] != nil
            || metadata["artifacts"] != nil
        guard hasRuntimeResult else {
            return content
        }
        let output = metadata["output"] ?? .object(["content": .string(content)])

        let reservedKeys: Set<String> = [
            "output", "isError", "artifacts", "sensitiveData", "effectReplayed"
        ]
        let resultMetadata = metadata.reduce(into: [String: JSONValue]()) { partial, entry in
            guard reservedKeys.contains(entry.key) == false else { return }
            partial[entry.key] = entry.value
        }
        let observation = JSONValue.object([
            "output": output,
            "isError": metadata["isError"] ?? .bool(false),
            "metadata": .object(resultMetadata),
            "artifacts": metadata["artifacts"] ?? .array([])
        ])
        return try observation.canonicalString()
    }

    /// Text convenience initializer. New media-aware callers should use the
    /// `contentParts` initializer so no provider has to recover structure from
    /// a string.
    public init(
        id: String,
        role: Role,
        content: String,
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolCalls: [ToolCall] = [],
        metadata: [String: JSONValue] = [:],
        usage: ModelUsage? = nil,
        responseID: String? = nil,
        reasoningSummary: String? = nil,
        stopReason: ModelStopReason? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.contentParts = [.text(content)]
        self.createdAt = createdAt
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
        self.metadata = metadata
        self.usage = role == .assistant ? usage : nil
        self.responseID = role == .assistant ? responseID : nil
        self.reasoningSummary = role == .assistant ? reasoningSummary : nil
        self.stopReason = role == .assistant ? stopReason : nil
    }

    public init(
        role: Role,
        content: String,
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolCalls: [ToolCall] = [],
        metadata: [String: JSONValue] = [:],
        usage: ModelUsage? = nil,
        responseID: String? = nil,
        reasoningSummary: String? = nil,
        stopReason: ModelStopReason? = nil
    ) {
        self.init(
            id: DeterministicCoreDefaults.identifier(
                prefix: "message",
                components: [
                    role.rawValue,
                    content,
                    DeterministicCoreDefaults.dateComponent(createdAt),
                    toolCallID ?? "",
                    toolName ?? "",
                    DeterministicCoreDefaults.toolCallsComponent(toolCalls),
                    DeterministicCoreDefaults.metadataComponent(metadata),
                    Self.terminalCodableComponent(role == .assistant ? usage : nil),
                    Self.terminalStringComponent(role == .assistant ? responseID : nil),
                    Self.terminalStringComponent(role == .assistant ? reasoningSummary : nil),
                    Self.terminalCodableComponent(role == .assistant ? stopReason : nil)
                ]
            ),
            role: role,
            content: content,
            createdAt: createdAt,
            toolCallID: toolCallID,
            toolName: toolName,
            toolCalls: toolCalls,
            metadata: metadata,
            usage: usage,
            responseID: responseID,
            reasoningSummary: reasoningSummary,
            stopReason: stopReason
        )
    }

    public init(
        id: String,
        role: Role,
        contentParts: [ModelContentPart],
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolCalls: [ToolCall] = [],
        metadata: [String: JSONValue] = [:],
        usage: ModelUsage? = nil,
        responseID: String? = nil,
        reasoningSummary: String? = nil,
        stopReason: ModelStopReason? = nil
    ) {
        self.id = id
        self.role = role
        self.content = contentParts.compactMap(\.text).joined()
        self.contentParts = contentParts
        self.createdAt = createdAt
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
        self.metadata = metadata
        self.usage = role == .assistant ? usage : nil
        self.responseID = role == .assistant ? responseID : nil
        self.reasoningSummary = role == .assistant ? reasoningSummary : nil
        self.stopReason = role == .assistant ? stopReason : nil
    }

    public init(
        role: Role,
        contentParts: [ModelContentPart],
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolCalls: [ToolCall] = [],
        metadata: [String: JSONValue] = [:],
        usage: ModelUsage? = nil,
        responseID: String? = nil,
        reasoningSummary: String? = nil,
        stopReason: ModelStopReason? = nil
    ) {
        let content = contentParts.compactMap(\.text).joined()
        self.init(
            id: DeterministicCoreDefaults.identifier(
                prefix: "message",
                components: [
                    role.rawValue,
                    content,
                    Self.contentPartsComponent(contentParts),
                    DeterministicCoreDefaults.dateComponent(createdAt),
                    toolCallID ?? "",
                    toolName ?? "",
                    DeterministicCoreDefaults.toolCallsComponent(toolCalls),
                    DeterministicCoreDefaults.metadataComponent(metadata),
                    Self.terminalCodableComponent(role == .assistant ? usage : nil),
                    Self.terminalStringComponent(role == .assistant ? responseID : nil),
                    Self.terminalStringComponent(role == .assistant ? reasoningSummary : nil),
                    Self.terminalCodableComponent(role == .assistant ? stopReason : nil)
                ]
            ),
            role: role,
            contentParts: contentParts,
            createdAt: createdAt,
            toolCallID: toolCallID,
            toolName: toolName,
            toolCalls: toolCalls,
            metadata: metadata,
            usage: usage,
            responseID: responseID,
            reasoningSummary: reasoningSummary,
            stopReason: stopReason
        )
    }

    public func applying(_ event: AgentMessageEvent) -> AgentMessage {
        switch event {
        case let .contentChanged(content):
            return copy(contentParts: [.text(content)], metadata: metadata)
        case let .metadataChanged(metadata):
            return copy(contentParts: contentParts, metadata: metadata)
        }
    }

    private func copy(
        contentParts: [ModelContentPart],
        metadata: [String: JSONValue]
    ) -> AgentMessage {
        AgentMessage(
            id: id,
            role: role,
            contentParts: contentParts,
            createdAt: createdAt,
            toolCallID: toolCallID,
            toolName: toolName,
            toolCalls: toolCalls,
            metadata: metadata,
            usage: usage,
            responseID: responseID,
            reasoningSummary: reasoningSummary,
            stopReason: stopReason
        )
    }

    private static func terminalStringComponent(_ value: String?) -> String {
        value.map { "some:\($0)" } ?? "none"
    }

    private static func terminalCodableComponent<T: Encodable>(_ value: T?) -> String {
        guard let value else { return "none" }
        guard let data = try? JSONEncoder.nativeAgent().encode(value) else { return "invalid" }
        return "some:\(SHA256HexDigest.digest(data))"
    }

    private static func contentPartsComponent(_ parts: [ModelContentPart]) -> String {
        guard let data = try? JSONEncoder.nativeAgent().encode(parts) else { return "" }
        return SHA256HexDigest.digest(data)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, contentParts, createdAt, toolCallID, toolName, toolCalls, metadata
        case usage, responseID, reasoningSummary, stopReason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        contentParts = try container.decode([ModelContentPart].self, forKey: .contentParts)
        guard contentParts.compactMap(\.text).joined() == content else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentParts,
                in: container,
                debugDescription: "AgentMessage content must equal the text projection of contentParts."
            )
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolCalls = try container.decode([ToolCall].self, forKey: .toolCalls)
        metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
        let decodedUsage = try container.decodeIfPresent(ModelUsage.self, forKey: .usage)
        let decodedResponseID = try container.decodeIfPresent(String.self, forKey: .responseID)
        let decodedReasoningSummary = try container.decodeIfPresent(String.self, forKey: .reasoningSummary)
        let decodedStopReason = try container.decodeIfPresent(ModelStopReason.self, forKey: .stopReason)
        usage = role == .assistant ? decodedUsage : nil
        responseID = role == .assistant ? decodedResponseID : nil
        reasoningSummary = role == .assistant ? decodedReasoningSummary : nil
        stopReason = role == .assistant ? decodedStopReason : nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(contentParts, forKey: .contentParts)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(responseID, forKey: .responseID)
        try container.encodeIfPresent(reasoningSummary, forKey: .reasoningSummary)
        try container.encodeIfPresent(stopReason, forKey: .stopReason)
    }
}

public enum AgentMessageEvent: Sendable {
    case contentChanged(String)
    case metadataChanged([String: JSONValue])
}
