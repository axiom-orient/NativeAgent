import NativeAgentDomain
import Foundation

public protocol RemoteSkillFetcher: Sendable {
    func fetchSkillMarkdown(baseURL: URL) async throws -> String
    func fetchSkillPackage(baseURL: URL) async throws -> RemoteSkillPackage
    func fetchSkillPluginRepository(repositoryURL: URL) async throws -> RemoteSkillPluginRepository
}

extension RemoteSkillFetcher {
    public func fetchSkillPackage(baseURL: URL) async throws -> RemoteSkillPackage {
        let markdown = try await fetchSkillMarkdown(baseURL: baseURL)
        return RemoteSkillPackage(files: [
            RemoteSkillPackageFile(relativePath: "SKILL.md", data: Data(markdown.utf8))
        ])
    }

    public func fetchSkillPluginRepository(
        repositoryURL: URL
    ) async throws -> RemoteSkillPluginRepository {
        throw AgentError.invalidToolCall(
            "Remote skill plugin repositories are not supported by this fetcher.")
    }
}

public struct RemoteSkillPackage: Sendable, Hashable {
    public let files: [RemoteSkillPackageFile]

    public init(files: [RemoteSkillPackageFile]) {
        self.files = files
    }

    public var skillMarkdown: String? {
        guard let file = files.first(where: { $0.relativePath == "SKILL.md" }) else { return nil }
        return String(data: file.data, encoding: .utf8)
    }
}

public struct RemoteSkillPackageFile: Sendable, Hashable {
    public let relativePath: String
    public let data: Data

    public init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

public struct RemoteSkillPluginRepository: Sendable, Hashable {
    public let sourceLocation: String
    public let pluginPackages: [RemoteSkillPluginPackage]

    public init(sourceLocation: String, pluginPackages: [RemoteSkillPluginPackage]) {
        self.sourceLocation = sourceLocation
        self.pluginPackages = pluginPackages
    }
}

public struct RemoteSkillPluginPackage: Sendable, Hashable {
    public let sourceLocation: String
    public let relativePath: String
    public let files: [RemoteSkillPackageFile]

    public init(
        sourceLocation: String,
        relativePath: String,
        files: [RemoteSkillPackageFile]
    ) {
        self.sourceLocation = sourceLocation
        self.relativePath = relativePath
        self.files = files
    }
}
