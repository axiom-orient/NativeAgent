import Foundation
import NativeAgentDomain

public enum SessionConsensusRoleDriverError: Error, Equatable {
    case missingAssistantResponse(sessionID: String)
    case emptyAssistantResponse(sessionID: String)
}

public struct SessionConsensusRunInput: Sendable {
    public let userPrompt: String
    public let systemPrompt: String?
    public let title: String?
    public let modelID: String?
    public let metadata: [String: JSONValue]
    public let requestMetadata: [String: JSONValue]
    public let outputFormat: ModelOutputFormat

    public init(
        userPrompt: String,
        systemPrompt: String? = nil,
        title: String? = nil,
        modelID: String? = nil,
        metadata: [String: JSONValue] = [:],
        requestMetadata: [String: JSONValue] = [:],
        outputFormat: ModelOutputFormat = .text
    ) {
        self.userPrompt = userPrompt
        self.systemPrompt = systemPrompt
        self.title = title
        self.modelID = modelID
        self.metadata = metadata
        self.requestMetadata = requestMetadata
        self.outputFormat = outputFormat
    }
}

public struct SessionConsensusRoleDriver: ConsensusRoleDriver, Sendable {
    public typealias SessionRunner = @Sendable (SessionConsensusRunInput) async throws -> SessionSnapshot

    public let name: String
    public let defaultModelID: String?
    private let runSession: SessionRunner

    public init(
        name: String,
        defaultModelID: String? = nil,
        runSession: @escaping SessionRunner
    ) {
        self.name = name
        self.defaultModelID = defaultModelID
        self.runSession = runSession
    }

    public func generate(request: ConsensusRoleRequest) async throws -> ConsensusRoleResponse {
        let snapshot = try await runSession(
            SessionConsensusRunInput(
                userPrompt: Self.makeUserPrompt(from: request),
                systemPrompt: request.system,
                title: Self.makeSessionTitle(from: request),
                modelID: defaultModelID,
                metadata: [:],
                requestMetadata: Self.makeRequestMetadata(from: request),
                outputFormat: try request.jsonSchema.map {
                    .jsonObject(schema: try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))
                } ?? .text
            )
        )

        let text = try Self.extractAssistantResponse(from: snapshot)
        return ConsensusRoleResponse(
            text: text,
            metadata: Self.makeResponseMetadata(from: snapshot)
        )
    }
}

private extension SessionConsensusRoleDriver {
    static func makeUserPrompt(from request: ConsensusRoleRequest) -> String {
        var sections: [String] = []
        if let user = TextUtil.normalizeOptional(request.user) {
            sections.append(user)
        }

        return sections.joined(separator: "\n\n")
    }

    static func makeRequestMetadata(from request: ConsensusRoleRequest) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = request.metadata.mapValues { .string($0) }

        metadata[ConsensusMetadataKeys.roleSession] = .bool(true)

        if let temperature = request.temperature {
            metadata[ConsensusMetadataKeys.roleTemperature] = .number(temperature)
        }
        if let maxTokens = request.maxTokens {
            metadata[ConsensusMetadataKeys.roleMaxTokens] = .integer(Int64(maxTokens))
        }
        if let jsonSchema = TextUtil.normalizeOptional(request.jsonSchema) {
            metadata[ConsensusMetadataKeys.roleJSONSchema] = .string(jsonSchema)
        }

        return metadata
    }

    static func makeSessionTitle(from request: ConsensusRoleRequest) -> String? {
        let role = TextUtil.normalizeOptional(request.metadata[ConsensusRoleRequestKeys.role])
        let round = TextUtil.normalizeOptional(request.metadata[ConsensusRoleRequestKeys.round])

        switch (role, round) {
        case let (.some(role), .some(round)):
            return "BAC \(role) r\(round)"
        case let (.some(role), .none):
            return "BAC \(role)"
        default:
            return nil
        }
    }

    static func extractAssistantResponse(from snapshot: SessionSnapshot) throws -> String {
        guard let message = snapshot.messages.last(where: { message in
            message.role == .assistant
        }) else {
            throw SessionConsensusRoleDriverError.missingAssistantResponse(sessionID: snapshot.sessionID)
        }

        guard let content = TextUtil.normalizeOptional(message.content) else {
            throw SessionConsensusRoleDriverError.emptyAssistantResponse(sessionID: snapshot.sessionID)
        }
        return content
    }

    static func makeResponseMetadata(from snapshot: SessionSnapshot) -> [String: String] {
        var metadata: [String: String] = [
            "sessionID": snapshot.sessionID,
            "messageCount": String(snapshot.messages.count),
            "artifactCount": String(snapshot.artifacts.count)
        ]

        if let providerID = snapshot.providerID {
            metadata["native-agent.provider.id"] = providerID
        }
        if let modelID = snapshot.modelID {
            metadata["modelID"] = modelID
        }

        return metadata
    }

}
