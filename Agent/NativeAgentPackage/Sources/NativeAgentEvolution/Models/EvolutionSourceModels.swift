import NativeAgentDomain

public struct EvolutionArtifact: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let content: String
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        name: String,
        content: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = EvolutionPath.sanitized(id)
        self.name = name.trimmedForNativeAgentEvolution
        self.content = content
        self.metadata = metadata
    }
}

public struct EvolutionCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let content: String
    public let rationale: String
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        title: String,
        content: String,
        rationale: String = "",
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = EvolutionPath.sanitized(id)
        self.title = title.trimmedForNativeAgentEvolution
        self.content = content
        self.rationale = rationale.trimmedForNativeAgentEvolution
        self.metadata = metadata
    }
}
