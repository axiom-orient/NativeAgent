import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

extension ASKWorkWikiQuickStartRunner {
    func indexSourceFiles(sourceRootURL: URL, indexURL: URL) async throws -> IndexedSources {
        let options = try ConfigLoader().load()
        let store = try SourceIndexStore(workspaceURL: indexURL)
        var sourceIDs: [SourceID] = []
        var indexedPaths: [String] = []
        var skippedSources: [ASKWorkWikiSkippedSource] = []

        // Build first so per-file problems keep their skip classification;
        // writing is one batched manifest flush instead of N full rewrites.
        var built: [(url: URL, artifact: SourceIndexArtifact)] = []
        let discovered = try sourceFiles(under: sourceRootURL)
        for fileURL in discovered {
            do {
                let artifact = try await sourceArtifactBuilder.buildArtifact(from: fileURL, options: options)
                built.append((fileURL, artifact))
            } catch let error as ASKPageIndexError where isSkippableIndexError(error) {
                skippedSources.append(ASKWorkWikiSkippedSource(path: fileURL.path, reason: error.errorDescription ?? String(describing: error)))
            } catch {
                throw ASKWorkWikiError(
                    .sourceIndexFailed,
                    "failed to index source file: \(fileURL.path)",
                    context: ["path": fileURL.path, "cause": String(describing: error)]
                )
            }
        }

        do {
            let entries = try await store.reconcile(built.map(\.artifact),
                sourceRootURL: sourceRootURL, discoveredSourceURLs: discovered)
            for (pair, entry) in zip(built, entries) {
                sourceIDs.append(entry.sourceID)
                indexedPaths.append(pair.url.path)
            }
        } catch {
            throw ASKWorkWikiError(
                .sourceIndexFailed,
                "failed to write the indexed source batch",
                context: ["path": indexURL.path, "cause": String(describing: error)]
            )
        }

        return IndexedSources(
            sourceIDs: sourceIDs,
            indexedPaths: indexedPaths.sorted(),
            skippedSources: skippedSources.sorted { $0.path < $1.path }
        )
    }

    func sourceFiles(under root: URL) throws -> [URL] {
        try files(under: root, matchingExtensions: ["md", "markdown", "pdf"], missingDescription: "source path does not exist")
    }

    func markdownFiles(under root: URL) throws -> [URL] {
        try files(under: root, matchingExtensions: ["md", "markdown"], missingDescription: "markdown source path does not exist")
    }

    func files(under root: URL, matchingExtensions extensions: Set<String>, missingDescription: String) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ASKWorkWikiError(.sourcePathNotFound, "\(missingDescription): \(root.path)", context: ["path": root.path])
        }
        if !isDirectory.boolValue {
            return extensions.contains(root.pathExtension.lowercased()) ? [root] : []
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        for child in children {
            if try isSymbolicLink(at: child) {
                throw ASKWorkWikiError(
                    .sourceIndexFailed,
                    "source tree contains symbolic link",
                    context: ["path": child.path]
                )
            }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                files.append(contentsOf: try self.files(under: child, matchingExtensions: extensions, missingDescription: missingDescription))
            } else if values.isRegularFile == true, extensions.contains(child.pathExtension.lowercased()) {
                files.append(child)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func isSkippableIndexError(_ error: ASKPageIndexError) -> Bool {
        switch error {
        case .unsupportedFileFormat, .unsupportedOperation, .dependencyUnavailable:
            return true
        default:
            return false
        }
    }
}

struct IndexedSources: Sendable, Equatable {
    var sourceIDs: [SourceID]
    var indexedPaths: [String]
    var skippedSources: [ASKWorkWikiSkippedSource]
}
