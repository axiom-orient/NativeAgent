import LanguageModelCore
import Foundation

public enum ToolCatalogSourceKind: String, Codable, Sendable, Equatable {
    case hostSupplied
    case bundledManifest
    case appGroupMetadata
}

public struct ToolCatalogSourceDescriptor: Codable, Sendable, Equatable, Hashable {
    public let kind: ToolCatalogSourceKind
    public let identifier: String

    public init(kind: ToolCatalogSourceKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public struct ToolCatalogEntry: Codable, Sendable, Equatable {
    public let packID: String
    public let definition: ToolDefinition
    public let source: ToolCatalogSourceDescriptor
    public let metadata: [String: JSONValue]

    public init(
        packID: String,
        definition: ToolDefinition,
        source: ToolCatalogSourceDescriptor,
        metadata: [String: JSONValue] = [:]
    ) {
        self.packID = packID
        self.definition = definition
        self.source = source
        self.metadata = metadata
    }
}

public struct ToolCapabilitySummary: Codable, Sendable, Equatable {
    public let id: String
    public let description: String
    public let capabilityID: CapabilityID
    public let effect: ToolEffectKind
    public let approvalPolicy: ApprovalPolicy

    public init(definition: ToolDefinition) {
        self.id = definition.name
        self.description = definition.description
        self.capabilityID = definition.capabilityID
        self.effect = definition.effect
        self.approvalPolicy = definition.approvalPolicy
    }
}

public protocol ToolCatalogSource: Sendable {
    func loadEntries() async throws -> [ToolCatalogEntry]
}
