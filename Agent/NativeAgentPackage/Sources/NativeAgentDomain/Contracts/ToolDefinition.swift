import LanguageModelCore
import Foundation

public enum ToolEffectKind: String, Codable, Sendable, Equatable, Hashable {
    case readOnly = "read_only"
    case mutation
}

public struct ToolDefinition: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let capabilityID: CapabilityID
    public let inputSchema: JSONValue
    public let approvalPolicy: ApprovalPolicy
    public let effect: ToolEffectKind
    public let metadata: [String: JSONValue]

    public init(
        name: String,
        description: String,
        capabilityID: CapabilityID,
        inputSchema: JSONValue,
        approvalPolicy: ApprovalPolicy,
        effect: ToolEffectKind = .mutation,
        metadata: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.description = description
        self.capabilityID = capabilityID
        self.inputSchema = inputSchema
        self.approvalPolicy = approvalPolicy
        self.effect = effect
        self.metadata = metadata
    }

    public var isReadOnly: Bool {
        effect == .readOnly
    }

    package var containsSensitiveData: Bool {
        metadata["sensitiveData"]?.boolValue == true
    }

    public var modelTool: ModelTool {
        ModelTool(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
    }
}
