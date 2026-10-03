import Foundation
import Testing
import PageIndex
import EvidenceIndex

struct EvidenceSourceRelocationTests {
    @Test func samePathHistoryKeepsExactReferencesWithoutClaimingHistoricalBytesAreCurrent() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.standardizedFileURL.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        let oldFile = oldRoot.appendingPathComponent("note.md"), newFile = newRoot.appendingPathComponent("note.md")
        let indexURL = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try Data("# Decision\nFirst evidence establishes the onboarding plan.\n".utf8).write(to: oldFile)
        let builder = MarkdownSourceArtifactBuilder(), options = try ConfigLoader().load()
        let first = try await builder.buildArtifact(from: oldFile, options: options)
        let store = try SourceIndexStore(workspaceURL: indexURL)
        _ = try await store.put(first)
        let before = try await ASKEvidenceIndex.open(workspaceURL: indexURL)
        let pack = try await before.buildGroundedPack(.init(text: "onboarding plan", limit: 1), maxBytes: 8192)
        let reference = try #require(pack.evidence.first?.reference)
        guard case .available(let originalContent) = try await before.resolve(reference) else {
            Issue.record("Initial source-backed reference did not resolve"); return
        }
        try Data("# Decision\nSecond evidence replaces the onboarding plan.\n".utf8).write(to: oldFile)
        let second = try await builder.buildArtifact(from: oldFile, options: options)
        #expect(second.document.sourceID == first.document.sourceID)
        _ = try await store.put(second)
        try FileManager.default.moveItem(at: oldRoot, to: newRoot)

        #expect(try await store.relocateSourcePaths([oldFile.path: newFile], allowedDestinationRoots: [newRoot]) == 2)
        let reopened = try await ASKEvidenceIndex.open(workspaceURL: indexURL)
        #expect(try await reopened.freshness(sourceID: first.document.sourceID)?.freshness == .ok)
        guard case .available(let retained) = try await reopened.resolve(reference, freshnessRequirement: .retainedIndexedContent) else {
            Issue.record("Relocation lost the prior exact indexed reference"); return
        }
        #expect(retained.reference == reference)
        #expect(retained.excerpts == originalContent.excerpts)
        #expect(retained.sourceFreshness == .stale)
        #expect(try await reopened.resolve(reference, freshnessRequirement: .currentSource) == .unavailable(.sourceStale))
        #expect(try await store.list().count == 1)
        #expect(try await store.history(sourceID: first.document.sourceID).count == 1)
    }
}
