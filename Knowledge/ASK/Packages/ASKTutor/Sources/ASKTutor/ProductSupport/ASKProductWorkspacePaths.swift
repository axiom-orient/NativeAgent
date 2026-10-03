import Foundation
import KnowledgePresentation

public struct ASKProductWorkspacePaths: Sendable, Hashable, Codable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }


    public var knowledgeWorkspace: ASKKnowledgeWorkspacePaths {
        ASKKnowledgeWorkspacePaths(rootURL: rootURL)
    }

    public var askRoot: URL { rootURL.appendingPathComponent("ASK", isDirectory: true) }
    public var tutorStoreRoot: URL { rootURL.appendingPathComponent("ASKTutorStore", isDirectory: true) }
    public var presentationBundlesRoot: URL { rootURL.appendingPathComponent("ASKPageBundles", isDirectory: true) }
    public var pageIndexRoot: URL { rootURL.appendingPathComponent("ASKPageIndex", isDirectory: true) }
    public var pendingTutorInsightsRoot: URL { rootURL.appendingPathComponent("ASKTutorInsights", isDirectory: true) }
    public var appliedTutorInsightsRoot: URL { rootURL.appendingPathComponent("ASKTutorInsightsApplied", isDirectory: true) }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for directory in [
            rootURL,
            askRoot,
            tutorStoreRoot,
            presentationBundlesRoot,
            pageIndexRoot,
            pendingTutorInsightsRoot,
            appliedTutorInsightsRoot,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func presentationBundleRoot(named bundleName: String) throws -> URL {
        let trimmed = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ASKProductIntegrationError.invalidPresentationBundleName(bundleName)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                throw ASKProductIntegrationError.invalidPresentationBundleName(bundleName)
            }
        }
        return components.reduce(presentationBundlesRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    public func ensurePresentationBundleDirectory(
        named bundleName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let bundleRoot = try presentationBundleRoot(named: bundleName)
        try fileManager.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        return bundleRoot
    }
}
