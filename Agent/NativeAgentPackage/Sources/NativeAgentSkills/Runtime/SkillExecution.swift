import Foundation
import NativeAgentDomain

public struct SkillScriptResponse: Codable, Hashable, Sendable {
    public struct WebViewPayload: Codable, Hashable, Sendable {
        public let url: String
        public let iframe: Bool?
        public let aspectRatio: Double?
        public let artifactFilename: String?
        public let title: String?

        public init(
            url: String = "",
            iframe: Bool? = nil,
            aspectRatio: Double? = nil,
            artifactFilename: String? = nil,
            title: String? = nil
        ) {
            self.url = url
            self.iframe = iframe
            self.aspectRatio = aspectRatio
            self.artifactFilename = artifactFilename
            self.title = title
        }
    }

    public struct ImagePayload: Codable, Hashable, Sendable {
        public let base64: String

        public init(base64: String) {
            self.base64 = base64
        }
    }

    public struct ArtifactPayload: Codable, Hashable, Sendable {
        public enum Role: String, Codable, Sendable {
            case attachment
            case webview
            case primary
        }

        public let filename: String
        public let mimeType: String
        public let text: String?
        public let base64: String?
        public let role: Role?
        public let metadata: [String: JSONValue]

        public init(
            filename: String,
            mimeType: String,
            text: String? = nil,
            base64: String? = nil,
            role: Role? = nil,
            metadata: [String: JSONValue] = [:]
        ) {
            self.filename = filename
            self.mimeType = mimeType
            self.text = text
            self.base64 = base64
            self.role = role
            self.metadata = metadata
        }
    }

    public struct GenreRecord: Codable, Hashable, Sendable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public let result: String?
    public let error: String?
    public let webview: WebViewPayload?
    public let image: ImagePayload?
    public let availableGenres: [GenreRecord]?
    public let artifacts: [ArtifactPayload]?

    public init(
        result: String? = nil,
        error: String? = nil,
        webview: WebViewPayload? = nil,
        image: ImagePayload? = nil,
        availableGenres: [GenreRecord]? = nil,
        artifacts: [ArtifactPayload]? = nil
    ) {
        self.result = result
        self.error = error
        self.webview = webview
        self.image = image
        self.availableGenres = availableGenres
        self.artifacts = artifacts
    }
}

public protocol SkillScriptRunner: Sendable {
    func run(
        skill: ManagedSkill,
        scriptURL: URL,
        readAccessURL: URL?,
        inputJSON: String,
        secret: String?,
        context: ToolExecutionContext
    ) async throws -> SkillScriptResponse
}

public protocol SkillIntentService: Sendable {
    func execute(
        intent: String,
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult

    func toolDefinition(for intent: String) async -> ToolDefinition?
}

public extension SkillIntentService {
    func toolDefinition(for intent: String) async -> ToolDefinition? {
        nil
    }

    func execute(
        intent: String,
        parameters: JSONValue,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        if let rawJSON = parameters.stringValue {
            return try await execute(intent: intent, parametersJSON: rawJSON, context: context)
        }
        return try await execute(intent: intent, parametersJSON: try parameters.canonicalString(), context: context)
    }
}
