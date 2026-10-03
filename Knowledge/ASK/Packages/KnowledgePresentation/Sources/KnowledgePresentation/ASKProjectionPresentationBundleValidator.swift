import Foundation

package struct ASKProjectionPresentationBundleValidator: Sendable {
    package init() {}

    package func loadExistingManifest(
        bundleRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ASKProjectionPresentationManifest? {
        let canonicalBundleRoot = bundleRoot.standardizedFileURL
        guard fileManager.fileExists(atPath: canonicalBundleRoot.askKnowledgeFileSystemPath) else {
            return nil
        }

        let manifestURL = canonicalBundleRoot
            .appendingPathComponent(ASKProjectionPresentationManifest.defaultFilename, isDirectory: false)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: manifestURL.askKnowledgeFileSystemPath) else {
            return nil
        }

        let manifest = try JSONDecoder().decode(
            ASKProjectionPresentationManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        let runtimeManifestURL = canonicalBundleRoot
            .appendingPathComponent(manifest.runtimeManifestPath, isDirectory: false)
            .standardizedFileURL
        let documentURL = canonicalBundleRoot
            .appendingPathComponent(manifest.documentJSONPath, isDirectory: false)
            .standardizedFileURL

        guard fileManager.fileExists(atPath: runtimeManifestURL.askKnowledgeFileSystemPath),
              fileManager.fileExists(atPath: documentURL.askKnowledgeFileSystemPath) else {
            return nil
        }

        return manifest
    }
}
