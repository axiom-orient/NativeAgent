import NativeAgentDomain
import Foundation

extension SkillLibrary {
    func normalizeRemoteSkillBaseURL(_ value: String) throws -> URL {
        try pathPolicy.normalizeRemoteSkillBaseURL(value)
    }

    func remoteURL(baseURL: String, pathComponent: String) throws -> URL {
        try pathPolicy.remoteURL(baseURL: baseURL, pathComponent: pathComponent)
    }

    func sanitizeRelativeSkillPath(_ rawValue: String, kind: String) throws -> String {
        try pathPolicy.sanitizeRelativeSkillPath(rawValue, kind: kind)
    }

    func validatedChildURL(named relativePath: String, within root: URL) throws -> URL {
        try pathPolicy.validatedChildURL(named: relativePath, within: root)
    }

    func validateAbsoluteWebViewURL(_ url: URL, for skill: ManagedSkill) throws -> URL {
        if url.isFileURL {
            let root = try skillDirectoryURL(for: skill).standardizedFileURL.resolvingSymlinksInPath()
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.pathComponents.starts(with: root.pathComponents) else {
                throw AgentError.invalidToolCall("Web view file url is outside the skill directory")
            }
            if skill.source.kind == .imported || skill.source.kind == .plugin || skill.source.kind == .web
            {
                try validateWorkspaceURL(candidate)
            }
            return candidate
        }

        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "https", "http", "data", "about":
            return url
        default:
            throw AgentError.invalidToolCall(
                "Unsupported web view url scheme: \(scheme.ifEmpty("unknown"))")
        }
    }

    func validateWorkspaceURL(_ url: URL) throws {
        try pathPolicy.validateWorkspaceURL(url)
    }

    func normalizeSkillName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
