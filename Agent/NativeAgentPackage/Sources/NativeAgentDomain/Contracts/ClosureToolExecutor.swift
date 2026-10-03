import LanguageModelCore
public struct ClosureToolExecutor: ToolExecutor {
    public let definition: ToolDefinition
    private let closure: @Sendable (ToolCall, ToolExecutionContext) async throws -> ToolResult

    public init(
        definition: ToolDefinition,
        closure: @escaping @Sendable (ToolCall, ToolExecutionContext) async throws -> ToolResult
    ) {
        self.definition = definition
        self.closure = closure
    }

    public func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        try await closure(call, context)
    }
}
