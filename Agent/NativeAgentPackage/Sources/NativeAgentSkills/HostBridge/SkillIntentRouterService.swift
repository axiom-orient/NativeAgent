import Foundation
import NativeAgentDomain

public struct SkillIntentHandler: Sendable {
    public typealias Closure = @Sendable (_ parameters: JSONValue, _ context: ToolExecutionContext) async throws -> ToolResult

    public let definition: ToolDefinition?
    private let closure: Closure

    public init(
        definition: ToolDefinition? = nil,
        _ closure: @escaping Closure
    ) {
        self.definition = definition
        self.closure = closure
    }

    public func execute(parameters: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        try await closure(parameters, context)
    }
}

public actor SkillIntentRouterService: SkillIntentService {
    private var handlers: [String: SkillIntentHandler]

    public init(handlers: [String: SkillIntentHandler] = [:]) {
        self.handlers = handlers
    }

    public func register(intent: String, handler: SkillIntentHandler) {
        handlers[intent] = handler
    }

    public func unregister(intent: String) {
        handlers.removeValue(forKey: intent)
    }


    public func toolDefinition(for intent: String) async -> ToolDefinition? {
        handlers[intent]?.definition
    }

    public func execute(
        intent: String,
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        guard let handler = handlers[intent] else {
            throw AgentError.notFound("No skill intent registered for \(intent)")
        }

        let payload = parametersJSON.normalizedJSONPayload
        guard let data = payload.data(using: .utf8) else {
            throw AgentError.invalidToolCall("Intent parameters must be valid UTF-8 JSON")
        }
        let parameters = try JSONDecoder.nativeAgent().decode(JSONValue.self, from: data)
        guard parameters.objectValue != nil else {
            throw AgentError.invalidToolCall("Intent parameters must decode to a JSON object")
        }
        return try await handler.execute(parameters: parameters, context: context)
    }
}
