import Foundation

enum ConsensusRoleRequestKeys {
    static let role = "role"
    static let round = "round"
    static let engine = "engine"
}

public protocol ConsensusRoleDriver: Sendable {
    var name: String { get }
    func generate(request: ConsensusRoleRequest) async throws -> ConsensusRoleResponse
}

public struct ConsensusRoleRequest: Codable, Sendable, Equatable {
    public let system: String?
    public let user: String
    public let jsonSchema: String?
    public let temperature: Double?
    public let maxTokens: Int?
    public let metadata: [String: String]

    public init(
        system: String? = nil,
        user: String,
        jsonSchema: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.system = system
        self.user = user
        self.jsonSchema = jsonSchema
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.metadata = metadata
    }
}

public struct ConsensusRoleResponse: Codable, Sendable, Equatable {
    public let text: String
    public let metadata: [String: String]

    public init(text: String, metadata: [String: String] = [:]) {
        self.text = text
        self.metadata = metadata
    }
}
