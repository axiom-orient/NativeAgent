import NativeAgentDomain
import Foundation

/// The model may inspect memory, but it has no write/update/delete capability.
public struct MemoryToolPack: ToolPack {
    public let packID = "toolpack.memory"
    private let memory: MemoryController
    private let scope: MemoryScope

    public init(memory: MemoryController, scope: MemoryScope = MemoryScope()) {
        self.memory = memory
        self.scope = scope
    }

    public func executors() -> [any ToolExecutor] {
        [ClosureToolExecutor(definition: definition) { [memory, scope] call, context in
            guard call.name == "memory.search" else {
                throw AgentError.invalidToolCall("Unknown memory tool: \(call.name)")
            }
            let request = try SearchRequest(arguments: call.arguments)
            var scoped = scope
            if scoped.sessionKey.isEmpty { scoped = MemoryScope(profileID: scope.profileID, userID: scope.userID, sessionKey: context.sessionID, namespace: scope.namespace) }
            let typed = try await memory.search(scope: scoped, query: request.query)
            return ToolResult(
                callID: call.id,
                toolName: call.name,
                output: output(typed.matches, historical: request.historical)
            )
        }]
    }

    private var definition: ToolDefinition {
        ToolDefinition(
            name: "memory.search",
            description: "Read historical memory evidence by query, kind, and optional time range.",
            capabilityID: CapabilityID(rawValue: "memory"),
            inputSchema: ToolSchema.object(
                properties: [
                    "query": ToolSchema.string(description: "Required lexical query.", minLength: 1, maxLength: 4_096),
                    "kinds": ToolSchema.array(items: ToolSchema.string(), description: "Optional record kinds.", maxItems: 5),
                    "from_ms": ToolSchema.integer(description: "Inclusive start timestamp in milliseconds."),
                    "to_ms": ToolSchema.integer(description: "Inclusive end timestamp in milliseconds."),
                    "historical": ToolSchema.boolean(description: "Include superseded records."),
                    "limit": ToolSchema.integer(description: "Maximum results.", minimum: 1, maximum: 8)
                ],
                required: ["query"]
            ),
            approvalPolicy: .automatic,
            effect: .readOnly
        )
    }
}

private struct SearchRequest {
    let query: MemorySearchQuery
    let historical: Bool

    init(arguments: JSONValue) throws {
        guard let object = arguments.objectValue else { throw AgentError.invalidToolCall("memory.search arguments must be an object.") }
        let allowed: Set<String> = ["query", "kinds", "from_ms", "to_ms", "historical", "limit"]
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) { throw AgentError.invalidToolCall("memory.search does not accept \(unknown).") }
        guard let query = object["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { throw AgentError.invalidToolCall("memory.search query must not be empty.") }
        let kinds: [MemoryRecordKind]
        if let rawKinds = object["kinds"] {
            guard let values = rawKinds.arrayValue, values.count <= 5 else { throw AgentError.invalidToolCall("memory.search kinds is invalid.") }
            kinds = try values.map {
                guard let raw = $0.stringValue, let kind = MemoryRecordKind(rawValue: raw) else { throw AgentError.invalidToolCall("memory.search kind is invalid.") }
                return kind
            }
        } else { kinds = [] }
        let from = try memorySearchOptionalInt(object["from_ms"], field: "from_ms")
        let to = try memorySearchOptionalInt(object["to_ms"], field: "to_ms")
        if let from, let to, from > to { throw AgentError.invalidToolCall("memory.search time range is reversed.") }
        let historical = object["historical"]?.boolValue ?? false
        if object["historical"] != nil && object["historical"]?.boolValue == nil { throw AgentError.invalidToolCall("memory.search historical must be boolean.") }
        let limitRaw = try memorySearchOptionalInt(object["limit"], field: "limit") ?? 8
        guard (1...8).contains(limitRaw) else { throw AgentError.invalidToolCall("memory.search limit must be between 1 and 8.") }
        let limit = Int(limitRaw)
        self.historical = historical
        self.query = MemorySearchQuery(query: query, kinds: kinds, fromMilliseconds: from, toMilliseconds: to, historical: historical, limit: limit)
    }

}

private func memorySearchOptionalInt(_ value: JSONValue?, field: String) throws -> Int64? {
    guard let value else { return nil }
    guard case .integer(let integer) = value else { throw AgentError.invalidToolCall("memory.search \(field) must be an integer.") }
    return integer
}

private func output(_ matches: [MemoryMatch], historical: Bool) -> JSONValue {
    .object([
        "historical": .bool(historical),
        "results": .array(matches.map { match in
            .object([
                "id": .string(match.id),
                "kind": .string(match.type),
                "role": .string(match.role),
                "content": .string(match.content),
                "score": .number(match.score),
                "source_session_id": .string(match.sourceSessionID),
                "source_message_ids": .array(match.sourceMessageIDs.map(JSONValue.string))
            ])
        })
    ])
}
