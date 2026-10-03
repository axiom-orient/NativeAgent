import PageIndex
import XCTest

/// Batch put must produce the same on-disk state as sequential puts, keep
/// history semantics, and stay all-or-nothing.
final class SourceIndexBatchPutTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeArtifact(markdown: String, name: String, sourceRoot: URL) async throws -> SourceIndexArtifact {
        let fileURL = sourceRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: fileURL)
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()
        return try await builder.buildArtifact(from: fileURL, options: options)
    }

    func testBatchMatchesSequentialState() async throws {
        let workspaceA = try tempDirectory()
        let workspaceB = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            for url in [workspaceA, workspaceB, sourceRoot] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let artifacts = [
            try await makeArtifact(markdown: "# One\nalpha body", name: "one.md", sourceRoot: sourceRoot),
            try await makeArtifact(markdown: "# Two\nbeta body", name: "two.md", sourceRoot: sourceRoot),
            try await makeArtifact(markdown: "# Three\ngamma body", name: "three.md", sourceRoot: sourceRoot),
        ]

        let sequentialStore = try SourceIndexStore(workspaceURL: workspaceA)
        for artifact in artifacts {
            _ = try await sequentialStore.put(artifact)
        }

        let batchStore = try SourceIndexStore(workspaceURL: workspaceB)
        let entries = try await batchStore.put(artifacts)
        XCTAssertEqual(entries.count, 3)

        let sequentialSnapshot = try await sequentialStore.snapshot().sorted { $0.document.sourceID.rawValue < $1.document.sourceID.rawValue }
        let batchSnapshot = try await batchStore.snapshot().sorted { $0.document.sourceID.rawValue < $1.document.sourceID.rawValue }
        XCTAssertEqual(sequentialSnapshot.count, 3)
        XCTAssertEqual(batchSnapshot.map(\.version.checksum), sequentialSnapshot.map(\.version.checksum))
        XCTAssertEqual(batchSnapshot.map(\.document.title), sequentialSnapshot.map(\.document.title))
    }

    func testBatchUpdateWritesHistoryAndReplacesContent() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let store = try SourceIndexStore(workspaceURL: workspace)
        let first = try await makeArtifact(markdown: "# Doc\nfirst body", name: "doc.md", sourceRoot: sourceRoot)
        _ = try await store.put([first])

        // Same logical source (same path → same sourceID), new content.
        let fileURL = sourceRoot.appendingPathComponent("doc.md")
        try Data("# Doc\nsecond body".utf8).write(to: fileURL)
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()
        let second = try await builder.buildArtifact(from: fileURL, options: options)

        let entries = try await store.put([second])
        XCTAssertEqual(entries.count, 1)

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(snapshot.first?.document.rootNodes.contains(where: { node in
            node.title.contains("Doc") && (node.snippet?.contains("second") == true || node.summary?.contains("second") == true)
        }) == true)

        let sourceID = entries[0].sourceID
        let history = try await store.history(sourceID: sourceID)
        XCTAssertEqual(history.count, 1, "previous version must land in history")
    }

    func testBatchRejectsDuplicateSourceIDsBeforeFilesystemMutation() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let artifact = try await makeArtifact(markdown: "# Duplicate\nbody", name: "duplicate.md", sourceRoot: sourceRoot)
        let store = try SourceIndexStore(workspaceURL: workspace)

        do {
            _ = try await store.put([artifact, artifact])
            XCTFail("duplicate source IDs must be rejected")
        } catch let error as ASKPageIndexError {
            guard case .invalidArguments(let message) = error else {
                XCTFail("unexpected PageIndex error: \(error)")
                return
            }
            XCTAssertTrue(message.contains("duplicate source IDs"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("artifacts").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(SourceIndexStore.manifestFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".source-index.lock").path))
    }
}
