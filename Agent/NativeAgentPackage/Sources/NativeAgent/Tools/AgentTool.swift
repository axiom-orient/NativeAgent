import NativeAgentDomain

/// Closure-backed tool intended for application integration.
public struct AgentTool: ToolExecutor {
    public let definition: ToolDefinition
    private let handler: @Sendable (ToolCall, ToolExecutionContext) async throws -> ToolResult

    public init(
        definition: ToolDefinition,
        handler: @escaping @Sendable (ToolCall, ToolExecutionContext) async throws -> ToolResult
    ) {
        self.definition = definition
        self.handler = handler
    }

    /// Convenience initializer for a JSON-in/JSON-out application function.
    public init(
        name: String,
        description: String,
        capabilityID: CapabilityID = "app",
        inputSchema: JSONValue = ToolSchema.object(properties: [:]),
        approvalPolicy: ApprovalPolicy = .requireApproval,
        effect: ToolEffectKind = .mutation,
        metadata: [String: JSONValue] = [:],
        handler: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.init(
            definition: ToolDefinition(
                name: name,
                description: description,
                capabilityID: capabilityID,
                inputSchema: inputSchema,
                approvalPolicy: approvalPolicy,
                effect: effect,
                metadata: metadata
            )
        ) { call, _ in
            ToolResult(
                callID: call.id,
                toolName: call.name,
                output: try await handler(call.arguments)
            )
        }
    }

    public func execute(
        call: ToolCall,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        try await handler(call, context)
    }
}
