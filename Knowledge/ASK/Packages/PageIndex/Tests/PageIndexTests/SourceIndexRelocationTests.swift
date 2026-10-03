import Foundation
import Testing
import PageIndex

struct SourceIndexRelocationTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func artifact(at url: URL, text: String) async throws -> SourceIndexArtifact {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return try await MarkdownSourceArtifactBuilder().buildArtifact(from: url, options: ConfigLoader().load())
    }

    private func persistedJSON(_ root: URL) throws -> [String: Data] {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: Data] = [:]
        for case let file as URL in files where file.pathExtension == "json" {
            result[file.path] = try Data(contentsOf: file)
        }
        return result
    }

    @Test func currentAndHistorySharingOnePathPreserveExactAnchorsAndRootOwnership() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        let oldFile = oldRoot.appendingPathComponent("note.md"), newFile = newRoot.appendingPathComponent("note.md")
        let index = root.appendingPathComponent("index")
        let store = try SourceIndexStore(workspaceURL: index)
        let first = try await artifact(at: oldFile, text: "# Note\nFirst evidence.\n")
        _ = try await store.reconcile([first], sourceRootURL: oldRoot, discoveredSourceURLs: [oldFile])
        let firstStored = try #require(try await store.get(sourceID: first.document.sourceID))
        let node = try #require(firstStored.document.rootNodes.first)
        let snippet = try #require(node.snippet)
        let anchor = SourceAnchor(sourceID: firstStored.document.sourceID,
            sourceVersionChecksum: firstStored.version.checksum, nodeID: node.nodeID,
            sectionPath: [node.title], range: node.range, snippet: snippet)
        let originalResolved = try #require(try await store.resolve(anchor: anchor))
        let second = try await artifact(at: oldFile, text: "# Note\nSecond evidence with different bytes.\n")
        _ = try await store.reconcile([second], sourceRootURL: oldRoot, discoveredSourceURLs: [oldFile])
        let secondStored = try #require(try await store.get(sourceID: second.document.sourceID))
        let originalEntry = try #require(try await store.list().first)
        try FileManager.default.moveItem(at: oldRoot, to: newRoot)

        #expect(try await store.relocateSourcePaths([oldFile.path: newFile], allowedDestinationRoots: [newRoot]) == 2)
        let reopened = try SourceIndexStore(workspaceURL: index)
        let current = try #require(try await reopened.get(sourceID: secondStored.document.sourceID))
        let history = try #require(try await reopened.get(sourceID: firstStored.document.sourceID,
            versionChecksum: firstStored.version.checksum))
        for (actual, original) in [(current, secondStored), (history, firstStored)] {
            #expect(actual.document == original.document)
            #expect(actual.version == original.version)
            #expect(actual.excerpts == original.excerpts)
            #expect(actual.frontmatter == original.frontmatter)
            #expect(actual.extractionQuality == original.extractionQuality)
            #expect(actual.sourcePath == newFile.path)
            #expect(actual.evidenceMetadata?.sourcePath == newFile.path)
        }
        #expect(try await reopened.resolve(anchor: anchor)?.excerpts == originalResolved.excerpts)
        #expect(try await reopened.list().first?.sourceRootIdentity == originalEntry.sourceRootIdentity)
        #expect(try await reopened.retainedSourcePaths() == [newFile.path])
        #expect(try await reopened.list().count == 1)
        #expect(try await reopened.history(sourceID: first.document.sourceID).count == 1)
    }

    @Test func checksumMismatchRejectsTheWholeBatchWithoutChangingPersistedEvidence() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        let index = root.appendingPathComponent("index")
        let values = try await [
            artifact(at: oldRoot.appendingPathComponent("one.md"), text: "# One\nValid evidence.\n"),
            artifact(at: oldRoot.appendingPathComponent("two.md"), text: "# Two\nOther evidence.\n")
        ].sorted { $0.document.sourceID.rawValue < $1.document.sourceID.rawValue }
        let store = try SourceIndexStore(workspaceURL: index)
        _ = try await store.reconcile(values, sourceRootURL: oldRoot,
            discoveredSourceURLs: values.map { URL(fileURLWithPath: $0.sourcePath!) })
        try FileManager.default.moveItem(at: oldRoot, to: newRoot)
        let replacements = Dictionary(uniqueKeysWithValues: values.map {
            ($0.sourcePath!, newRoot.appendingPathComponent(URL(fileURLWithPath: $0.sourcePath!).lastPathComponent))
        })
        let bad = try #require(values.last)
        let badFile = try #require(replacements[bad.sourcePath!])
        // Equal length isolates checksum validation; the first source is valid.
        try Data(repeating: 90, count: bad.version.contentLength).write(to: badFile)
        let before = try persistedJSON(index)
        await #expect(throws: ASKPageIndexError.self) {
            try await store.relocateSourcePaths(replacements, allowedDestinationRoots: [newRoot])
        }
        #expect(try persistedJSON(index) == before)
        #expect(!FileManager.default.fileExists(atPath: index.appendingPathComponent(".source-index-pending.json").path))
    }

    @Test(arguments: [false, true])
    func fileAndAncestorSymlinksCannotRedirectRelocation(ancestor: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("old/note.md")
        let allowedRoot = root.appendingPathComponent("owned")
        let outside = root.appendingPathComponent("outside")
        let outsideFile = outside.appendingPathComponent("note.md")
        let value = try await artifact(at: oldFile, text: "# Note\nExact but outside allowed root.\n")
        let index = root.appendingPathComponent("index")
        let store = try SourceIndexStore(workspaceURL: index)
        _ = try await store.put(value)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldFile, to: outsideFile)
        let target: URL
        if ancestor {
            let link = allowedRoot.appendingPathComponent("nested")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            target = link.appendingPathComponent("note.md")
        } else {
            target = allowedRoot.appendingPathComponent("note.md")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outsideFile)
        }
        let before = try persistedJSON(index), outsideBytes = try Data(contentsOf: outsideFile)
        await #expect(throws: ASKPageIndexError.self) {
            try await store.relocateSourcePaths([oldFile.path: target], allowedDestinationRoots: [allowedRoot])
        }
        #expect(try persistedJSON(index) == before)
        #expect(try Data(contentsOf: outsideFile) == outsideBytes)
    }

    @Test func existingOldSourceCannotBeReboundAndSuccessfulRepairIsIdempotent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("old/note.md"), newRoot = root.appendingPathComponent("new")
        let newFile = newRoot.appendingPathComponent("note.md"), index = root.appendingPathComponent("index")
        let value = try await artifact(at: oldFile, text: "# Note\nExisting borrowed original.\n")
        let store = try SourceIndexStore(workspaceURL: index)
        _ = try await store.put(value)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: oldFile, to: newFile)
        let before = try persistedJSON(index)
        await #expect(throws: ASKPageIndexError.self) {
            try await store.relocateSourcePaths([oldFile.path: newFile], allowedDestinationRoots: [newRoot])
        }
        #expect(try persistedJSON(index) == before)
        try FileManager.default.removeItem(at: oldFile)
        #expect(try await store.relocateSourcePaths([oldFile.path: newFile], allowedDestinationRoots: [newRoot]) == 1)
        let repaired = try persistedJSON(index)
        #expect(try await store.relocateSourcePaths([oldFile.path: newFile], allowedDestinationRoots: [newRoot]) == 0)
        #expect(try persistedJSON(index) == repaired)
    }
}
