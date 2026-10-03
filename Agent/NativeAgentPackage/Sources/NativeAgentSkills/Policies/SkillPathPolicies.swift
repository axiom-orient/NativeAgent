import Foundation
import NativeAgentDomain

struct SkillPathPolicy: Sendable {
    let workspace: SkillWorkspace
    private let localhostHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    init(workspace: SkillWorkspace) {
        self.workspace = workspace
    }

    func normalizeRemoteSkillBaseURL(_ value: String) throws -> URL {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/SKILL.md") {
            trimmed.removeLast("/SKILL.md".count)
        }
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), url.scheme?.isEmpty == false else {
            throw AgentError.invalidToolCall("Invalid skill URL: \(value)")
        }
        return try validateTrustedRemoteURL(url, label: value)
    }

    func remoteURL(baseURL: String, pathComponent: String) throws -> URL {
        let rawBaseURL = baseURL
        guard let baseURL = URL(string: rawBaseURL) else {
            throw AgentError.invalidToolCall("Invalid remote skill base url: \(rawBaseURL)")
        }
        let trustedBaseURL = try validateTrustedRemoteURL(baseURL, label: rawBaseURL)
        let safePathComponent = try sanitizeRelativeSkillPath(pathComponent, kind: "remote skill")
        guard let url = URL(string: trustedBaseURL.absoluteString)?.appendingPathComponent(safePathComponent) else {
            throw AgentError.invalidToolCall("Invalid remote skill base url: \(rawBaseURL)")
        }
        return try validateTrustedRemoteURL(url, label: url.absoluteString)
    }

    func validateRemoteAbsoluteWebViewURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw AgentError.invalidToolCall("Invalid remote web view url: \(url.absoluteString)")
        }
        switch scheme {
        case "about", "data":
            return url
        case "https":
            guard url.host?.isEmpty == false else {
                throw AgentError.invalidToolCall("Remote web view url must include a host: \(url.absoluteString)")
            }
            return url
        case "http":
            guard let host = normalizedHost(for: url), localhostHosts.contains(host) else {
                throw AgentError.invalidToolCall("Remote web view url must use https or localhost http: \(url.absoluteString)")
            }
            return url
        default:
            throw AgentError.invalidToolCall("Unsupported remote web view url scheme: \(scheme)")
        }
    }

    func sanitizeRelativeSkillPath(_ rawValue: String, kind: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.invalidToolCall("\(kind.capitalized) path must not be empty")
        }
        if URL(string: trimmed)?.scheme?.isEmpty == false {
            throw AgentError.invalidToolCall("\(kind.capitalized) path must be relative")
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            throw AgentError.invalidToolCall("\(kind.capitalized) path must stay within the skill directory")
        }
        let components = NSString.path(withComponents: trimmed.split(separator: "/").map(String.init))
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty else {
            throw AgentError.invalidToolCall("\(kind.capitalized) path must not be empty")
        }
        if components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) {
            throw AgentError.invalidToolCall("\(kind.capitalized) path cannot contain traversal segments")
        }
        return components.joined(separator: "/")
    }

    func validatedChildURL(named relativePath: String, within root: URL) throws -> URL {
        let url = root
            .standardizedFileURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard url.pathComponents.starts(with: standardizedRoot.pathComponents) else {
            throw AgentError.invalidToolCall("Skill file escaped the expected directory")
        }
        return url
    }

    func validateWorkspaceURL(_ url: URL) throws {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(root: workspace.supportRootURL, candidate: normalized)
            || isInside(root: workspace.userSkillsRootURL, candidate: normalized)
        else {
            throw AgentError.invalidToolCall("Skill file is outside the managed NativeAgent skill workspace")
        }
    }

    func validateUserSkillsURL(_ url: URL) throws {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(root: workspace.userSkillsRootURL, candidate: normalized) else {
            throw AgentError.invalidToolCall("Skill file is outside the user skills documents root")
        }
    }

    private func isInside(root: URL, candidate: URL) -> Bool {
        let standardizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.pathComponents.starts(with: standardizedRoot.pathComponents)
    }

    private func validateTrustedRemoteURL(_ url: URL, label: String) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw AgentError.invalidToolCall("Invalid remote skill URL: \(label)")
        }
        guard url.host?.isEmpty == false else {
            throw AgentError.invalidToolCall("Remote skill URL must include a host: \(label)")
        }

        switch scheme {
        case "https":
            return url
        case "http":
            guard let host = normalizedHost(for: url), localhostHosts.contains(host) else {
                throw AgentError.invalidToolCall("Remote skill URL must use https or localhost http: \(label)")
            }
            return url
        default:
            throw AgentError.invalidToolCall("Unsupported remote skill URL scheme: \(scheme)")
        }
    }

    private func normalizedHost(for url: URL) -> String? {
        url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}
