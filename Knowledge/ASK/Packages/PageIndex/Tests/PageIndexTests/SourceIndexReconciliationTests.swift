import Foundation
import Testing
@testable import PageIndex

/// Exercises the public host-supplied artifact boundary with real files and stores.
/// Markdown/PDF extraction is intentionally not part of this fixture.
struct SourceIndexReconciliationTests {
    @Test func ordinaryPathIdentityTerminatesAtFilesystemRoot() {
        let file = URL(fileURLWithPath: "/ask-no-owned-marker-\(UUID().uuidString)/note.md")
        #expect(SourceIdentityFactory.makeID(forFileAt: file) ==
            SourceIdentityFactory.makeID(logicalKey: file.standardizedFileURL.resolvingSymlinksInPath().path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func artifact(at url: URL, text: String) throws -> SourceIndexArtifact {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        return SourceIndexArtifact(
            document: SourceIndexDocument(sourceID: SourceIdentityFactory.makeID(forFileAt: url),
                type: .md, title: "Note", coordinateSpace: .line, extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "Note", range: range, snippet: text)]),
            excerpts: [SourceExcerpt(index: 1, content: text)],
            version: SourceIdentityFactory.makeVersion(data: data), sourcePath: url.path,
            extractionQuality: .digitalText)
    }

    @Test func deletionRetiresOnlyOwnedRootAndKeepsExactHistory() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let aRoot = root.appendingPathComponent("a"), bRoot = root.appendingPathComponent("b")
        let aURL = aRoot.appendingPathComponent("note.md"), bURL = bRoot.appendingPathComponent("note.md")
        let first = try artifact(at: aURL, text: "first")
        let other = try artifact(at: bURL, text: "other")
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        _ = try await store.reconcile([first], sourceRootURL: aRoot, discoveredSourceURLs: [aURL])
        _ = try await store.reconcile([other], sourceRootURL: bRoot, discoveredSourceURLs: [bURL])
        let next = try artifact(at: aURL, text: "second")
        _ = try await store.reconcile([next], sourceRootURL: aRoot, discoveredSourceURLs: [aURL])
        try FileManager.default.removeItem(at: aURL)
        _ = try await store.reconcile([], sourceRootURL: aRoot, discoveredSourceURLs: [])
        #expect(try await store.get(sourceID: first.document.sourceID) == nil)
        #expect(try await store.get(sourceID: other.document.sourceID) == other)
        #expect(try await store.get(sourceID: first.document.sourceID, versionChecksum: first.version.checksum) == first)
        #expect(try await store.get(sourceID: first.document.sourceID, versionChecksum: next.version.checksum) == next)
        #expect(try await store.get(sourceID: first.document.sourceID, versionChecksum: "missing") == nil)
        let anchor = SourceAnchor(sourceID: first.document.sourceID, sourceVersionChecksum: first.version.checksum,
            nodeID: "root", sectionPath: ["Note"], range: first.document.rootNodes[0].range, snippet: "first")
        #expect(try await store.resolve(anchor: anchor)?.excerpts == first.excerpts)
        #expect(try await store.retainedSourcePaths().contains(aURL.path))
    }

    @Test func discoveredButUnsupportedSourceIsNotTreatedAsDeleted() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/note.md")
        let first = try artifact(at: source, text: "first")
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        _ = try await store.reconcile([first], sourceRootURL: source.deletingLastPathComponent(), discoveredSourceURLs: [source])
        _ = try await store.reconcile([], sourceRootURL: source.deletingLastPathComponent(), discoveredSourceURLs: [source])
        #expect(try await store.get(sourceID: first.document.sourceID) == first)
    }

    @Test func foreignRootRejectedBeforeMutation() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/note.md")
        let first = try artifact(at: source, text: "first")
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        await #expect(throws: ASKPageIndexError.self) {
            try await store.reconcile([first], sourceRootURL: root.appendingPathComponent("foreign"), discoveredSourceURLs: [source])
        }
        #expect(try await store.list().isEmpty)
    }

    @Test func ownedGenerationRootIsStableAndRevisitedVersionDoesNotConflict() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = "root-0123456789abcdef01234567"
        let generations = root.appendingPathComponent("ASKImportedSources/\(identity)/generations")
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        var versions: [SourceIndexArtifact] = []
        var roots: [URL] = []
        for text in ["A", "B", "A", "C"] {
            let generation = generations.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            try Data(identity.utf8).write(to: generation.appendingPathComponent(".ask-source-identity"))
            let file = generation.appendingPathComponent("note.md")
            let value = try artifact(at: file, text: text)
            versions.append(value); roots.append(generation)
            _ = try await store.reconcile([value], sourceRootURL: generation, discoveredSourceURLs: [file])
        }
        #expect(Set(versions.map { $0.document.sourceID }).count == 1)
        #expect(SourceIdentityFactory.rootIdentity(for: roots[0]) == SourceIdentityFactory.rootIdentity(for: roots[3]))
        // Immutable history keeps the first exact artifact, including original raw location.
        #expect(try await store.get(sourceID: versions[0].document.sourceID,
            versionChecksum: versions[0].version.checksum) == versions[0])
        _ = try await store.reconcile([], sourceRootURL: roots[3], discoveredSourceURLs: [])
        #expect(try await store.list().isEmpty)
        #expect(try await store.history(sourceID: versions[0].document.sourceID).count == 3)
    }
    @Test func unownedEntriesAreNotInferredFromSnapshotPaths() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = "root-0123456789abcdef01234567"
        let generations = root.appendingPathComponent("ASKImportedSources/\(identity)/generations")
        let original = generations.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data(identity.utf8).write(to: original.appendingPathComponent(".ask-source-identity"))
        let value = try artifact(at: original.appendingPathComponent("note.md"), text: "historical")
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        _ = try await store.put(value)
        try FileManager.default.removeItem(at: original)
        let current = generations.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data(identity.utf8).write(to: current.appendingPathComponent(".ask-source-identity"))
        _ = try await store.reconcile([], sourceRootURL: current, discoveredSourceURLs: [])
        #expect(try await store.get(sourceID: value.document.sourceID) == value)
        #expect(try await store.list().first?.sourceRootIdentity == nil)
        #expect(try await store.history(sourceID: value.document.sourceID).isEmpty)
    }
}
