import Foundation

/// Provider-facing tool description.
///
/// Approval, capability ownership, and effect policy intentionally do not
/// cross the model-provider boundary. Agent runtime maps its `ToolDefinition`
/// into this transport-neutral value before invoking a provider.
public struct ModelTool: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolCall: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: JSONValue
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        name: String,
        arguments: JSONValue,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.metadata = metadata
    }

    public init(
        name: String,
        arguments: JSONValue,
        metadata: [String: JSONValue] = [:]
    ) {
        self.init(
            id: DeterministicCoreDefaults.identifier(
                prefix: "toolcall",
                components: [
                    name,
                    arguments.stableIdentityString(),
                    DeterministicCoreDefaults.metadataComponent(metadata)
                ]
            ),
            name: name,
            arguments: arguments,
            metadata: metadata
        )
    }
}
