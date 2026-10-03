import NativeAgentDomain
import Foundation

struct GitHubSkillRoot: Sendable, Equatable {
    var owner: String
    var repository: String
    var reference: String?
    var pathComponents: [String]

    var path: String {
        pathComponents.joined(separator: "/")
    }
}

struct GitHubRepositoryRoot: Sendable, Equatable {
    var owner: String
    var repository: String
    var reference: String?
    var pathComponents: [String]
    var originalURL: URL

    var path: String {
        pathComponents.joined(separator: "/")
    }

    var sourceLocation: String {
        if let reference {
            let suffix = path.isEmpty ? "" : "/\(path)"
            return "https://github.com/\(owner)/\(repository)/tree/\(reference)\(suffix)"
        }
        return "https://github.com/\(owner)/\(repository)"
    }
}

struct GitHubContentEntry: Decodable, Sendable {
    var name: String
    var path: String
    var type: String
    var downloadURL: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case type
        case downloadURL = "download_url"
    }
}

enum GitHubRemoteSkillLocation {
    static func skillMarkdownURL(from baseURL: URL) -> URL {
        if let githubURL = rawSkillURL(from: baseURL) {
            return githubURL
        }
        if baseURL.lastPathComponent == "SKILL.md" {
            return baseURL
        }
        return baseURL.appendingPathComponent("SKILL.md")
    }

    static func skillRoot(from url: URL) -> GitHubSkillRoot? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        if host == "raw.githubusercontent.com", components.count >= 4 {
            let pathComponents = Array(components.dropFirst(3))
            let rootComponents =
                pathComponents.last == "SKILL.md"
                ? Array(pathComponents.dropLast())
                : pathComponents
            return GitHubSkillRoot(
                owner: components[0],
                repository: components[1],
                reference: components[2],
                pathComponents: rootComponents
            )
        }

        guard host == "github.com", components.count >= 5 else { return nil }
        guard components[2] == "tree" else { return nil }
        return GitHubSkillRoot(
            owner: components[0],
            repository: components[1],
            reference: components[3],
            pathComponents: Array(components.dropFirst(4))
        )
    }

    static func repositoryRoot(from url: URL) -> GitHubRepositoryRoot? {
        guard let host = url.host?.lowercased(), host == "github.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        let repository = components[1].dropSuffix(".git")
        guard !owner.isEmpty, !repository.isEmpty else { return nil }

        if components.count == 2 {
            return GitHubRepositoryRoot(
                owner: owner,
                repository: repository,
                reference: nil,
                pathComponents: [],
                originalURL: url
            )
        }

        guard components.count >= 4, components[2] == "tree" else { return nil }
        return GitHubRepositoryRoot(
            owner: owner,
            repository: repository,
            reference: components[3],
            pathComponents: Array(components.dropFirst(4)),
            originalURL: url
        )
    }

    static func rawURL(
        owner: String,
        repository: String,
        reference: String?,
        pathComponents: [String]
    ) -> URL? {
        guard let reference else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/" + ([owner, repository, reference] + pathComponents).joined(separator: "/")
        return components.url
    }

    static func rawURL(
        owner: String,
        repository: String,
        reference: String,
        relativePath: String
    ) throws -> URL {
        guard let url = rawURL(
            owner: owner,
            repository: repository,
            reference: reference,
            pathComponents: relativePath.split(separator: "/").map(String.init)
        ) else {
            throw AgentError.invalidToolCall("Invalid GitHub raw URL for \(relativePath)")
        }
        return url
    }

    static func referenceCandidates(for root: GitHubRepositoryRoot) -> [String] {
        if let reference = root.reference {
            return [reference]
        }
        return ["main", "master"]
    }

    static func validateRepositoryRelativePath(_ rawPath: String) throws -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines).trimmedTrailingSlash()
        guard !path.isEmpty else {
            throw AgentError.invalidToolCall("NativeAgent skill repository plugin path must not be empty")
        }
        guard !path.hasPrefix("/"), !path.contains("\\") else {
            throw AgentError.invalidToolCall("NativeAgent skill repository plugin path must be relative")
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentError.invalidToolCall(
                "NativeAgent skill repository plugin path cannot contain traversal segments")
        }
        return components.joined(separator: "/")
    }

    private static func rawSkillURL(from url: URL) -> URL? {
        if let root = skillRoot(from: url) {
            return rawURL(
                owner: root.owner,
                repository: root.repository,
                reference: root.reference,
                pathComponents: root.pathComponents + ["SKILL.md"]
            )
        }
        if let blob = blobSkillFile(from: url) {
            return rawURL(
                owner: blob.owner,
                repository: blob.repository,
                reference: blob.reference,
                pathComponents: blob.pathComponents
            )
        }
        return nil
    }

    private static func blobSkillFile(from url: URL) -> GitHubSkillRoot? {
        guard let host = url.host?.lowercased(), host == "github.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 5,
            components[2] == "blob",
            components.last == "SKILL.md"
        else { return nil }
        return GitHubSkillRoot(
            owner: components[0],
            repository: components[1],
            reference: components[3],
            pathComponents: Array(components.dropFirst(4))
        )
    }
}
