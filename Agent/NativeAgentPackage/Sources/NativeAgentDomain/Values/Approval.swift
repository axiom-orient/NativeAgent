import LanguageModelCore
import Foundation

public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let toolCall: ToolCall
    public let definition: ToolDefinition
    public let createdAt: Date

    public init(
        id: String,
        sessionID: String,
        toolCall: ToolCall,
        definition: ToolDefinition,
        createdAt: Date = DeterministicCoreDefaults.timestamp
    ) {
        self.id = id
        self.sessionID = sessionID
        self.toolCall = toolCall
        self.definition = definition
        self.createdAt = createdAt
    }

    public init(
        sessionID: String,
        toolCall: ToolCall,
        definition: ToolDefinition,
        createdAt: Date = DeterministicCoreDefaults.timestamp
    ) {
        self.init(
            id: DeterministicCoreDefaults.identifier(
                prefix: "approval",
                components: [
                    sessionID,
                    toolCall.id,
                    definition.name,
                    DeterministicCoreDefaults.dateComponent(createdAt)
                ]
            ),
            sessionID: sessionID,
            toolCall: toolCall,
            definition: definition,
            createdAt: createdAt
        )
    }
}

public enum ApprovalDecision: Codable, Sendable, Equatable {
    case approved(reason: String?)
    case denied(reason: String?)

    public var isApproved: Bool {
        if case .approved = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .approved(let reason), .denied(let reason):
            return reason
        }
    }
}
