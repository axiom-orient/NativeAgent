import EvidenceIndex
import PageIndex
import XCTest

/// Covers the handle pool and artifact cache contract. Freshness is deliberately
/// recomputed from source bytes so metadata-preserving edits cannot be hidden.
final class ASKEvidenceIndexCacheTests: XCTestCase, @unchecked Sendable {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-evidence-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMarkdown(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func indexFile(at url: URL, workspace: URL) async throws -> SourceID {
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()
        let artifact = try await builder.buildArtifact(from: url, options: options)
        let store = try SourceIndexStore(workspaceURL: workspace)
        let entry = try await store.put(artifact)
        return entry.sourceID
    }

    func testOpenReturnsSharedHandleForSameWorkspace() async throws {
        let workspaceA = try tempDirectory()
        let workspaceB = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }

        let first = try await ASKEvidenceIndex.open(workspaceURL: workspaceA)
        let second = try await ASKEvidenceIndex.open(workspaceURL: workspaceA)
        let other = try await ASKEvidenceIndex.open(workspaceURL: workspaceB)

        XCTAssertTrue(first === second, "same workspace must reuse one handle")
        XCTAssertFalse(first === other, "different workspaces need distinct handles")
    }

    func testArtifactCacheRefreshesOnManifestChangeWhileFreshnessStaysLive() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let sourceURL = sourceRoot.appendingPathComponent("probe.md")
        try writeMarkdown("# Probe\noriginal checkpoint body\n", to: sourceURL)
        _ = try await indexFile(at: sourceURL, workspace: workspace)

        let handle = try await ASKEvidenceIndex.open(workspaceURL: workspace)
        let query = ASKEvidenceQuery(text: "checkpoint", limit: 10)

        let initial = try await handle.search(query)
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial.first?.freshness, .ok)
        XCTAssertEqual(initial.first?.excerpt.contains("original"), true)

        // External edit without re-indexing: the artifact stays cached (old
        // excerpt), while freshness is recomputed from current source bytes.
        try writeMarkdown("# Probe\nedited checkpoint body\n", to: sourceURL)
        let afterEdit = try await handle.search(query)
        XCTAssertEqual(afterEdit.first?.excerpt.contains("original"), true)
        XCTAssertEqual(afterEdit.first?.freshness, .stale)

        // Re-indexing rewrites the manifest, so the cached artifact set must
        // refresh to the edited content and return to fresh.
        _ = try await indexFile(at: sourceURL, workspace: workspace)
        let afterReindex = try await handle.search(query)
        XCTAssertEqual(afterReindex.first?.excerpt.contains("edited"), true)
        XCTAssertEqual(afterReindex.first?.freshness, .ok)
    }

    func testPoolEvictionKeepsHandlesFunctional() async throws {
        let openedWorkspaces = try (0..<18).map { _ in try tempDirectory() }
        defer {
            for url in openedWorkspaces {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let first = try await ASKEvidenceIndex.open(workspaceURL: openedWorkspaces[0])
        for url in openedWorkspaces.dropFirst().prefix(16) {
            _ = try await ASKEvidenceIndex.open(workspaceURL: url)
        }
        let reopened = try await ASKEvidenceIndex.open(workspaceURL: openedWorkspaces[17])
        XCTAssertFalse(first === reopened)
        _ = try await first.search(ASKEvidenceQuery(text: "anything", limit: 1))
    }

    func testFreshnessDetectsSameSizeEditWithPreservedModificationDate() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let sourceURL = sourceRoot.appendingPathComponent("probe.md")
        try writeMarkdown("# Probe\noriginal checkpoint body\n", to: sourceURL)
        let originalDate = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date
        _ = try await indexFile(at: sourceURL, workspace: workspace)

        let handle = try await ASKEvidenceIndex.open(workspaceURL: workspace)
        let query = ASKEvidenceQuery(text: "checkpoint", limit: 10)
        let initial = try await handle.search(query)
        XCTAssertEqual(initial.first?.freshness, .ok)

        try writeMarkdown("# Probe\nrevised checkpoint body\n", to: sourceURL)
        if let originalDate {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: sourceURL.path)
        }

        let afterEdit = try await handle.search(query)
        XCTAssertEqual(afterEdit.first?.freshness, .stale)
    }
}
