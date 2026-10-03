import Foundation
import NativeAgentDomain

public protocol AppIntentsToolService: Sendable {
    func toolDefinitions() -> [ToolDefinition]
    func executeIntent(
        named: String,
        arguments: JSONValue
    ) async throws -> ToolResult
}

public protocol ContextAwareAppIntentsToolService: AppIntentsToolService {
    func executeIntent(
        named: String,
        arguments: JSONValue,
        context: ToolExecutionContext
    ) async throws -> ToolResult
}

public struct AppIntentsToolPack: ToolPack {
    public let packID = "toolpack.appintents"
    private let service: any AppIntentsToolService

    public init(service: any AppIntentsToolService) {
        self.service = service
    }

    public func executors() -> [any ToolExecutor] {
        service.toolDefinitions().map { definition in
            ClosureToolExecutor(definition: definition) { call, context in
                let result: ToolResult
                if let contextual = service as? any ContextAwareAppIntentsToolService {
                    result = try await contextual.executeIntent(
                        named: call.name,
                        arguments: call.arguments,
                        context: context
                    )
                } else {
                    result = try await service.executeIntent(
                        named: call.name,
                        arguments: call.arguments
                    )
                }

                return result.applying(
                    .identityChanged(callID: call.id, toolName: call.name)
                )
            }
        }
    }
}
