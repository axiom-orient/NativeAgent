import Foundation
import NativeAgentDomain

enum StoreRootLocator {
    private static let maximumPathComponentUTF8Bytes = 255
    static func defaultRootURL(
        appName: String,
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        subdirectoryName: String = StoreLayout.defaultSubdirectoryName,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let baseURL = try resolveBaseURL(
            appGroupIdentifier: appGroupIdentifier,
            appGroupContainerURL: appGroupContainerURL,
            fileManager: fileManager,
            applicationSupportURL: applicationSupportURL
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )

        return try appendStorePath(
            to: baseURL,
            appName: appName,
            subdirectoryName: subdirectoryName
        )
    }

    static func resolveBaseURL(
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        fileManager: FileManager = .default,
        applicationSupportURL: URL?
    ) throws -> URL {
        if let appGroupIdentifier {
            return try resolveAppGroupBaseURL(
                appGroupIdentifier: appGroupIdentifier,
                appGroupContainerURL: appGroupContainerURL,
                fileManager: fileManager
            )
        }

        guard let applicationSupportURL else {
            throw AgentError.persistenceFailure(
                "Application Support directory is unavailable. " +
                "Use an explicit rootURL for ephemeral storage."
            )
        }
        return applicationSupportURL.standardizedFileURL
    }

    private static func appendStorePath(
        to baseURL: URL,
        appName: String,
        subdirectoryName: String
    ) throws -> URL {
        try validatePathComponent(appName, fieldName: "appName")
        try validatePathComponent(subdirectoryName, fieldName: "subdirectoryName")

        let standardizedBaseURL = baseURL.standardizedFileURL
        let storeURL = standardizedBaseURL
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent(subdirectoryName, isDirectory: true)
            .standardizedFileURL

        let baseComponents = standardizedBaseURL.pathComponents
        let storeComponents = storeURL.pathComponents
        guard storeComponents.count > baseComponents.count,
              storeComponents.starts(with: baseComponents)
        else {
            throw AgentError.pathOutsideSandbox("Store root escapes its container.")
        }
        return storeURL
    }

    private static func validatePathComponent(
        _ component: String,
        fieldName: String
    ) throws {
        let isBounded = component.utf8.count <= maximumPathComponentUTF8Bytes
        let isNamedComponent = component.isEmpty == false
            && component != "."
            && component != ".."
        let hasPathSeparator = component.contains("/") || component.contains("\\")
        let hasControlCharacter = component.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }

        guard isBounded,
              isNamedComponent,
              hasPathSeparator == false,
              hasControlCharacter == false
        else {
            throw AgentError.invalidConfiguration(
                "Invalid \(fieldName): expected one nonempty path component of at most \(maximumPathComponentUTF8Bytes) UTF-8 bytes."
            )
        }
    }

    private static func resolveAppGroupBaseURL(
        appGroupIdentifier: String,
        appGroupContainerURL: URL?,
        fileManager: FileManager
    ) throws -> URL {
        if let appGroupContainerURL {
            return appGroupContainerURL.standardizedFileURL
        }

        #if os(iOS) || os(macOS)
        guard let resolved = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw AgentError.persistenceFailure("App Group container is unavailable: \(appGroupIdentifier)")
        }
        return resolved.standardizedFileURL
        #else
        throw AgentError.persistenceFailure("App Group containers are not supported on this platform: \(appGroupIdentifier)")
        #endif
    }
}
