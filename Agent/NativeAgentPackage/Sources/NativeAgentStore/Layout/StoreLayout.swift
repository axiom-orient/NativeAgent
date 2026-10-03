import Foundation
import NativeAgentDomain

public struct StoreLayout: Sendable, Equatable {
    /// Persistent directory name. Keep this value stable to preserve existing stores.
    public static let defaultSubdirectoryName = "NativeAgent"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var configDirectoryURL: URL {
        rootURL.appendingPathComponent("config", isDirectory: true)
    }

    public var manifestURL: URL {
        configDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)
    }

    public var sessionsRootURL: URL {
        rootURL.appendingPathComponent("sessions", isDirectory: true)
    }

    public var databaseURL: URL {
        rootURL.appendingPathComponent("native-agent.sqlite3", isDirectory: false)
    }

    public func sessionRootURL(sessionID: String) -> URL {
        sessionsRootURL.appendingPathComponent(sessionID, isDirectory: true)
    }

    public func artifactsDirectoryURL(sessionID: String) -> URL {
        sessionRootURL(sessionID: sessionID).appendingPathComponent("artifacts", isDirectory: true)
    }

    public static func defaultRootURL(
        appName: String,
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        subdirectoryName: String = StoreLayout.defaultSubdirectoryName
    ) throws -> URL {
        try StoreRootLocator.defaultRootURL(
            appName: appName,
            appGroupIdentifier: appGroupIdentifier,
            appGroupContainerURL: appGroupContainerURL,
            subdirectoryName: subdirectoryName
        )
    }
}
