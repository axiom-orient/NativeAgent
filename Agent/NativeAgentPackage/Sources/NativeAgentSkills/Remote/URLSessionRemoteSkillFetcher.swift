import NativeAgentDomain
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct RemoteSkillFetchLimits: Sendable, Equatable {
    public static let supportedMaximumResponseBytes = 64 * 1_024 * 1_024
    public static let supportedMaximumFileBytes = 32 * 1_024 * 1_024
    public static let supportedMaximumPackageBytes = 128 * 1_024 * 1_024
    public static let supportedMaximumFileCount = 2_048
    public static let supportedMaximumDirectoryDepth = 32
    public static let supportedMaximumEntriesPerDirectory = 4_096

    public let maximumResponseBytes: Int
    public let maximumFileBytes: Int
    public let maximumPackageBytes: Int
    public let maximumFileCount: Int
    public let maximumDirectoryDepth: Int
    public let maximumEntriesPerDirectory: Int

    public init(
        maximumResponseBytes: Int = 16 * 1_024 * 1_024,
        maximumFileBytes: Int = 8 * 1_024 * 1_024,
        maximumPackageBytes: Int = 64 * 1_024 * 1_024,
        maximumFileCount: Int = 512,
        maximumDirectoryDepth: Int = 16,
        maximumEntriesPerDirectory: Int = 1_024
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumFileBytes = maximumFileBytes
        self.maximumPackageBytes = maximumPackageBytes
        self.maximumFileCount = maximumFileCount
        self.maximumDirectoryDepth = maximumDirectoryDepth
        self.maximumEntriesPerDirectory = maximumEntriesPerDirectory
    }

    func validate() throws {
        guard (1...Self.supportedMaximumResponseBytes).contains(maximumResponseBytes),
            (1...Self.supportedMaximumFileBytes).contains(maximumFileBytes),
            (1...Self.supportedMaximumPackageBytes).contains(maximumPackageBytes),
            maximumFileBytes <= maximumResponseBytes,
            maximumFileBytes <= maximumPackageBytes,
            (1...Self.supportedMaximumFileCount).contains(maximumFileCount),
            (1...Self.supportedMaximumDirectoryDepth).contains(maximumDirectoryDepth),
            (1...Self.supportedMaximumEntriesPerDirectory).contains(maximumEntriesPerDirectory)
        else {
            throw AgentError.invalidConfiguration(
                "Remote skill fetch limits are outside the supported mobile envelope."
            )
        }
    }
}

public struct URLSessionRemoteSkillFetcher: RemoteSkillFetcher {
    let session: URLSession
    let limits: RemoteSkillFetchLimits

    public init(
        session: URLSession = .shared,
        limits: RemoteSkillFetchLimits = RemoteSkillFetchLimits()
    ) {
        self.session = session
        self.limits = limits
    }

    public func fetchSkillMarkdown(baseURL: URL) async throws -> String {
        try limits.validate()
        let skillMDURL = GitHubRemoteSkillLocation.skillMarkdownURL(from: baseURL)
        let (data, response) = try await boundedData(
            for: URLRequest(url: skillMDURL),
            maximumByteCount: limits.maximumFileBytes
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentError.notFound("Remote SKILL.md fetch failed with status \(http.statusCode)")
        }
        guard let markdown = String(data: data, encoding: .utf8),
            !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AgentError.invalidToolCall("Remote SKILL.md is empty at \(skillMDURL.absoluteString)")
        }
        return markdown
    }

    public func fetchSkillPackage(baseURL: URL) async throws -> RemoteSkillPackage {
        try limits.validate()
        if let githubSkillRoot = GitHubRemoteSkillLocation.skillRoot(from: baseURL) {
            let package = try await fetchGitHubSkillPackage(root: githubSkillRoot)
            try validatePackageFiles(package.files)
            return package
        }
        let package = try await (self as any RemoteSkillFetcher)
            .fetchSkillPackage(baseURL: baseURL)
        try validatePackageFiles(package.files)
        return package
    }

    public func fetchSkillPluginRepository(
        repositoryURL: URL
    ) async throws -> RemoteSkillPluginRepository {
        try limits.validate()
        guard let root = GitHubRemoteSkillLocation.repositoryRoot(from: repositoryURL) else {
            throw AgentError.invalidToolCall(
                "Remote skill plugin install currently supports GitHub repository URLs.")
        }
        let packages = try await fetchGitHubPluginPackages(sourceRoot: root)
        guard !packages.isEmpty else {
            throw AgentError.notFound(
                "Remote GitHub repository does not contain NativeAgent skill plugin manifests.")
        }
        for package in packages {
            try validatePackageFiles(package.files)
        }
        return RemoteSkillPluginRepository(
            sourceLocation: root.sourceLocation,
            pluginPackages: packages
        )
    }

    func boundedData(
        for request: URLRequest,
        maximumByteCount: Int
    ) async throws -> (Data, URLResponse) {
        let effectiveLimit = min(maximumByteCount, limits.maximumResponseBytes)
        guard effectiveLimit > 0 else {
            throw AgentError.invalidConfiguration(
                "Remote skill response limit must be positive."
            )
        }

#if canImport(Darwin)
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(effectiveLimit) {
            throw AgentError.budgetExceeded(
                "Remote skill response exceeds \(effectiveLimit) bytes."
            )
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(effectiveLimit, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < effectiveLimit else {
                throw AgentError.budgetExceeded(
                    "Remote skill response exceeds \(effectiveLimit) bytes."
                )
            }
            data.append(byte)
        }
        return (data, response)
#else
        let (data, response) = try await session.data(for: request)
        guard data.count <= effectiveLimit else {
            throw AgentError.budgetExceeded(
                "Remote skill response exceeds \(effectiveLimit) bytes."
            )
        }
        return (data, response)
#endif
    }

    func validatePackageFiles(
        _ files: [RemoteSkillPackageFile]
    ) throws {
        guard files.count <= limits.maximumFileCount else {
            throw AgentError.budgetExceeded(
                "Remote skill package contains \(files.count) files; limit is " +
                    "\(limits.maximumFileCount)."
            )
        }
        var total = 0
        for file in files {
            guard file.data.count <= limits.maximumFileBytes else {
                throw AgentError.budgetExceeded(
                    "Remote skill file \(file.relativePath) exceeds " +
                        "\(limits.maximumFileBytes) bytes."
                )
            }
            guard file.data.count <= limits.maximumPackageBytes - total else {
                throw AgentError.budgetExceeded(
                    "Remote skill package exceeds \(limits.maximumPackageBytes) bytes."
                )
            }
            total += file.data.count
        }
    }
}
