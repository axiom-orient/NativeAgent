import Foundation
import NativeAgentDomain

public struct SkillWorkspace: Sendable, Hashable {
    public let supportRootURL: URL
    public let userSkillsRootURL: URL

    public init(
        supportRootURL: URL,
        userSkillsRootURL: URL
    ) {
        self.supportRootURL = supportRootURL.standardizedFileURL
        self.userSkillsRootURL = userSkillsRootURL.standardizedFileURL
    }


    public var stateFileURL: URL {
        supportRootURL.appendingPathComponent("config/skills/state.json", isDirectory: false)
    }

    public var secretsFileURL: URL {
        supportRootURL.appendingPathComponent("config/skills/skill-secrets.json", isDirectory: false)
    }

    public func userSkillDirectoryURL(named normalizedName: String) -> URL {
        userSkillsRootURL.appendingPathComponent(normalizedName, isDirectory: true)
    }

    public static func appScoped(
        appName: String,
        fileManager: FileManager = .default
    ) throws -> SkillWorkspace {
        let supportBase = try url(for: .applicationSupportDirectory, fileManager: fileManager)
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("NativeAgent/Skills", isDirectory: true)

        let documentsBase = try url(for: .documentDirectory, fileManager: fileManager)
            .appendingPathComponent("NativeAgent/Skills", isDirectory: true)

        return SkillWorkspace(
            supportRootURL: supportBase,
            userSkillsRootURL: documentsBase
        )
    }

    private static func url(
        for directory: FileManager.SearchPathDirectory,
        fileManager: FileManager
    ) throws -> URL {
        switch directory {
        case .applicationSupportDirectory, .documentDirectory:
            return try fileManager.url(
                for: directory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        default:
            throw AgentError.notFound("Unsupported skill workspace directory: \(directory.rawValue)")
        }
    }
}
