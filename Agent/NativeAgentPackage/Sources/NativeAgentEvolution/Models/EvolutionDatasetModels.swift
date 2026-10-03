import NativeAgentDomain

public struct EvolutionExample: Codable, Sendable, Equatable, Identifiable {
    public enum Split: String, Codable, Sendable, Equatable {
        case validation
        case holdout
    }

    public let id: String
    public let input: String
    public let expectedOutput: String
    public let split: Split
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        input: String,
        expectedOutput: String,
        split: Split = .validation,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = EvolutionPath.sanitized(id)
        self.input = input
        self.expectedOutput = expectedOutput
        self.split = split
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case input
        case expectedOutput = "expected_output"
        case split
        case metadata
    }
}

public struct EvolutionDataset: Codable, Sendable, Equatable {
    public let name: String
    public let examples: [EvolutionExample]

    public init(name: String, examples: [EvolutionExample]) {
        self.name = name.trimmedForNativeAgentEvolution
        self.examples = examples
    }

    public var validationExamples: [EvolutionExample] {
        examples.filter { $0.split == .validation }
    }

    public var holdoutExamples: [EvolutionExample] {
        examples.filter { $0.split == .holdout }
    }
}
