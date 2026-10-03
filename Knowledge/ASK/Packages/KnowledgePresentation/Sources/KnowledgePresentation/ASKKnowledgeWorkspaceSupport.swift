import Foundation

public enum ASKKnowledgeWorkspaceError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPresentationBundleName(String)
    case invalidASKSourceID(String)
    case projectionNotFound(String)
    case presentationNotMaterialized(String)
    case failedToWritePresentationMarkdown(String)
    case failedToWritePresentationDocument(String)
    case failedToWritePresentationManifest(String)

    public var description: String {
        switch self {
        case .invalidPresentationBundleName(let value): "Invalid presentation bundle name: \(value)"
        case .invalidASKSourceID(let value): "Invalid ASK source ID: \(value)"
        case .projectionNotFound(let slug): "Projection not found: \(slug)"
        case .presentationNotMaterialized(let slug): "Projection presentation is not materialized: \(slug)"
        case .failedToWritePresentationMarkdown(let slug): "Failed to write presentation markdown: \(slug)"
        case .failedToWritePresentationDocument(let slug): "Failed to write presentation document: \(slug)"
        case .failedToWritePresentationManifest(let slug): "Failed to write presentation manifest: \(slug)"
        }
    }
}

extension URL {
    package var askKnowledgeFileSystemPath: String {
        standardizedFileURL.path(percentEncoded: false)
    }
}

public struct ASKKnowledgeWorkspacePaths: Sendable, Hashable, Codable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var askRoot: URL { rootURL.appendingPathComponent("ASK", isDirectory: true) }
    public var presentationBundlesRoot: URL { rootURL.appendingPathComponent("ASKPageBundles", isDirectory: true) }
    public var pageIndexRoot: URL { rootURL.appendingPathComponent("ASKPageIndex", isDirectory: true) }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for directory in [rootURL, askRoot, presentationBundlesRoot, pageIndexRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func presentationBundleRoot(named bundleName: String) throws -> URL {
        let trimmed = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ASKKnowledgeWorkspaceError.invalidPresentationBundleName(bundleName)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ASKKnowledgeWorkspaceError.invalidPresentationBundleName(bundleName)
        }
        return components.reduce(presentationBundlesRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }
}
