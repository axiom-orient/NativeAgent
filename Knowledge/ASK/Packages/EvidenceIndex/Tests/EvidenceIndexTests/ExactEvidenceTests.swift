import Foundation
import PageIndex
import Testing
@testable import EvidenceIndex

@Suite("Exact indexed evidence")
struct ExactEvidenceTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ask-exact-\(UUID().uuidString)")
    }

    private func artifact(_ text: String, path: URL? = nil, id: SourceID = "source", quality: SourceExtractionQuality = .digitalText) throws -> SourceIndexArtifact {
        let lines = text.components(separatedBy: "\n")
        return SourceIndexArtifact(
            document: SourceIndexDocument(sourceID: id, type: .md, title: "Evidence",
                coordinateSpace: .line, extentCount: lines.count,
                rootNodes: [SourceIndexNode(nodeID: "node", title: "Evidence",
                    range: try SourceRange(space: .line, start: 1, end: lines.count))]),
            excerpts: lines.enumerated().map { SourceExcerpt(index: $0.offset + 1, content: $0.element) },
            version: SourceVersion(checksum: StableDigest.sha256Hex(Data(text.utf8)),
                contentLength: text.utf8.count, modifiedAt: nil),
            sourcePath: path?.path, extractionQuality: quality)
    }

    private func onlyReference(_ index: ASKEvidenceIndex) async throws -> ASKEvidenceReference {
        let pack = try await index.buildGroundedPack(ASKEvidenceQuery(text: ""), freshnessRequirement: .retainedIndexedContent)
        return try #require(pack.evidence.first?.reference)
    }

    @Test func strictRejectsUnknownWhileExplicitHistoricalModeVerifiesIndexedContent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact("Evidence old\n한국어 line"))
        let index = ASKEvidenceIndex(store: store)
        #expect(try await index.buildPack(.init(query: .init(text: ""))).hits.count == 1)
        let strict = try await index.buildGroundedPack(.init(text: ""))
        #expect(strict.evidence.isEmpty)
        #expect(strict.rejected.map(\.reason) == [.sourceUnknown])
        let reference = try await onlyReference(index)
        let value = try await index.resolve(reference, freshnessRequirement: .retainedIndexedContent)
        guard case .available(let resolved) = value else { Issue.record("Expected indexed content"); return }
        #expect(resolved.sourceFreshness == .unknown)
        #expect(resolved.reference == reference)
        #expect(resolved.excerpts.map(\.content) == ["Evidence old", "한국어 line"])
        #expect(try await index.resolve(reference) == .unavailable(.sourceUnknown))
    }

    @Test func updatePinsOldContentAndDeleteRestoreHasExplicitOutcomes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("borrowed.md")
        try Data("Evidence old".utf8).write(to: source)
        let indexURL = root.appendingPathComponent("index")
        let store = try SourceIndexStore(workspaceURL: indexURL)
        let old = try artifact("Evidence old", path: source)
        try await store.put(old)
        let index = ASKEvidenceIndex(store: store)
        let pack = try await index.buildGroundedPack(.init(text: "Evidence"))
        let reference = try #require(pack.evidence.first?.reference)
        try Data("Evidence new".utf8).write(to: source)
        try await store.put(artifact("Evidence new", path: source))
        let reopened = try ASKEvidenceIndex(workspaceURL: indexURL)
        #expect(try await reopened.resolve(reference) == .unavailable(.sourceStale))
        guard case .available(let historical) = try await reopened.resolve(reference, freshnessRequirement: .retainedIndexedContent) else {
            Issue.record("Old history missing"); return
        }
        #expect(historical.excerpts.map(\.content) == ["Evidence old"])
        try FileManager.default.removeItem(at: source)
        #expect(try await reopened.resolve(reference) == .unavailable(.sourceMissing))
        guard case .available = try await reopened.resolve(reference, freshnessRequirement: .retainedIndexedContent) else {
            Issue.record("Borrowed raw deletion must not erase retained indexed history"); return
        }
        // Explicit index deletion purges that source's history; it is not a soft raw deletion.
        try await store.delete(sourceID: "source")
        #expect(try await reopened.resolve(reference, freshnessRequirement: .retainedIndexedContent) == .unavailable(.versionMissing))
        try await store.put(old)
        #expect(try await reopened.resolve(reference) == .unavailable(.sourceMissing))
        try Data("Evidence old".utf8).write(to: source)
        guard case .available(let restored) = try await reopened.resolve(reference) else {
            Issue.record("Exact restored bytes must resolve"); return
        }
        #expect(restored.reference == reference)
        #expect(restored.sourceFreshness == .ok)
    }

    @Test func missingVersionNeverFallsBackToLatest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact("Evidence new"))
        let index = ASKEvidenceIndex(store: store)
        let reference = try await onlyReference(index)
        let missing = try ASKEvidenceReference(sourceID: reference.sourceID,
            sourceVersionChecksum: "absent-version", nodeID: reference.nodeID,
            range: reference.range, contentSHA256: reference.contentSHA256)
        #expect(try await index.resolve(missing, freshnessRequirement: .retainedIndexedContent) == .unavailable(.versionMissing))
    }

    @Test func wrongDigestAndWrongRangeAreTypedFailures() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact("Evidence old\nsecond"))
        let index = ASKEvidenceIndex(store: store)
        let reference = try await onlyReference(index)
        let corrupt = try ASKEvidenceReference(sourceID: reference.sourceID,
            sourceVersionChecksum: reference.sourceVersionChecksum, nodeID: reference.nodeID,
            range: reference.range, contentSHA256: String(repeating: "0", count: 64))
        #expect(try await index.resolve(corrupt, freshnessRequirement: .retainedIndexedContent) == .unavailable(.digestMismatch))
        let wrongRange = try ASKEvidenceReference(sourceID: reference.sourceID,
            sourceVersionChecksum: reference.sourceVersionChecksum, nodeID: reference.nodeID,
            range: SourceRange(space: .line, start: 1, end: 1), contentSHA256: reference.contentSHA256)
        #expect(try await index.resolve(wrongRange, freshnessRequirement: .retainedIndexedContent) == .unavailable(.rangeUnavailable))
    }

    @Test func presentationClippingDoesNotChangeReferenceIdentity() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact("Evidence\nline 2\nline 3"))
        let index = ASKEvidenceIndex(store: store)
        let short = try await index.buildGroundedPack(.init(text: "", excerptLineLimit: 1), freshnessRequirement: .retainedIndexedContent)
        let full = try await index.buildGroundedPack(.init(text: "", excerptLineLimit: 20), freshnessRequirement: .retainedIndexedContent)
        #expect(short.evidence.first?.reference == full.evidence.first?.reference)
        #expect(short.evidence.first?.hit.excerpt != full.evidence.first?.hit.excerpt)
        let empty = try await index.buildGroundedPack(.init(text: ""), maxBytes: 1, freshnessRequirement: .retainedIndexedContent)
        #expect(empty.truncated && empty.evidence.isEmpty)
        #expect(empty.renderedMarkdown.utf8.count <= 1)
    }

    @Test func malformedReferenceDecodeIsRejected() throws {
        let ref = try ASKEvidenceReference(sourceID: "s", sourceVersionChecksum: "v", nodeID: "n",
            range: SourceRange(space: .line, start: 1, end: 1), contentSHA256: String(repeating: "a", count: 64))
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(ref)) as? [String: Any])
        json["contentSHA256"] = "not-a-digest"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ASKEvidenceReference.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try JSONDecoder().decode(ASKEvidenceReference.self, from: encoder.encode(ref)) == ref)
    }

    @Test func exactQueriesDoNotCreateAbsentWorkspaceOrMutateStoredBytes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try ASKEvidenceIndex(workspaceURL: root)
        #expect(try await index.buildGroundedPack(.init(text: "")).evidence.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact("Evidence"))
        let reference = try await onlyReference(index)
        func snapshot() throws -> [String: Data] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            var values: [String: Data] = [:]
            for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                values[url.path] = try Data(contentsOf: url)
            }
            return values
        }
        let before = try snapshot()
        _ = try await index.resolve(reference, freshnessRequirement: .retainedIndexedContent)
        _ = try await index.buildGroundedPack(.init(text: ""), freshnessRequirement: .retainedIndexedContent)
        #expect(try snapshot() == before)
    }

    @Test(arguments: [SourceExtractionQuality.unsupported, .ocrRequired])
    func unsupportedExtractionCannotBecomeGroundedThroughDirectReference(quality: SourceExtractionQuality) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try artifact("Evidence", quality: quality)
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact)
        let reference = try ASKEvidenceReference(sourceID: artifact.document.sourceID,
            sourceVersionChecksum: artifact.version.checksum, nodeID: "node",
            range: SourceRange(space: .line, start: 1, end: 1),
            contentSHA256: ASKEvidenceGrounding.digest(artifact.excerpts))
        let index = ASKEvidenceIndex(store: store)
        #expect(try await index.resolve(reference, freshnessRequirement: .retainedIndexedContent) == .unavailable(.extractionUnavailable))
    }

    @Test func searchFindsLateValuesAndGroundingKeepsMatchingContext() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("settlement.md")
        let lines = (1...24).map { "일반 안내 항목 \($0)" }
            + ["확정 정산 금액은 48271원이다.", "부가세는 포함되지 않는다.", "납부일은 2026-10-15이다."]
        let text = lines.joined(separator: "\n")
        try Data(text.utf8).write(to: source)
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        try await store.put(artifact(text, path: source))
        let index = ASKEvidenceIndex(store: store)
        let short = try await index.buildGroundedPack(.init(text: "48271", excerptLineLimit: 5))
        let hit = try #require(short.evidence.first)
        #expect(hit.hit.excerpt.contains("48271원"))
        #expect(hit.hit.excerpt.contains("부가세는 포함되지 않는다"))
        #expect(hit.hit.excerpt.components(separatedBy: "\n").count <= 5)
        let full = try await index.buildGroundedPack(.init(text: "48271", excerptLineLimit: 100))
        #expect(hit.reference == full.evidence.first?.reference)
        guard case .available(let resolved) = try await index.resolve(hit.reference) else {
            Issue.record("Matching excerpt must resolve to the unchanged full node"); return
        }
        #expect(resolved.excerpts.map(\.content) == lines)
        let hidden = try await index.search(.init(text: "48271", excerptLineLimit: 0))
        #expect(hidden.count == 1 && hidden.first?.excerpt == "")
        #expect(try await index.search(.init(text: "482710")).isEmpty)
    }

    @Test func groundedLimitCountsAdmittedEvidenceNotRejectedCandidates() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleSource = root.appendingPathComponent("stale.md")
        let freshSource = root.appendingPathComponent("fresh.md")
        let staleIndexed = "priority topic priority topic priority topic"
        let freshText = "priority topic"
        try Data(staleIndexed.utf8).write(to: staleSource)
        try Data(freshText.utf8).write(to: freshSource)

        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        try await store.put(artifact(staleIndexed, path: staleSource, id: "stale"))
        try await store.put(artifact(freshText, path: freshSource, id: "fresh"))
        let index = ASKEvidenceIndex(store: store)

        // Make the highest-scoring indexed candidate stale without reindexing it.
        try Data("changed bytes".utf8).write(to: staleSource)
        #expect(try await index.search(.init(text: "priority topic", limit: 1)).map(\.sourceID) == [SourceID("stale")])

        let grounded = try await index.buildGroundedPack(.init(text: "priority topic", limit: 1))
        #expect(grounded.evidence.map { $0.hit.sourceID } == [SourceID("fresh")])
        #expect(grounded.rejected.map(\.sourceID) == [SourceID("stale")])
        #expect(grounded.rejected.map(\.reason) == [.sourceStale])
    }

    @Test func numericQueryDoesNotMatchDigitsInsideAnotherValue() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceIndexStore(workspaceURL: root)
        try await store.put(artifact("승인 예산은 170원이다.", id: "wrong"))
        try await store.put(artifact("승인 예산은 17,000원이다.", id: "thousands"))
        try await store.put(artifact("승인 예산은 17.5원이다.", id: "decimal"))
        try await store.put(artifact("승인 예산은 17원이다.", id: "exact"))
        let hits = try await ASKEvidenceIndex(store: store).search(.init(text: "17"))
        #expect(hits.map(\.sourceID) == [SourceID("exact")])
        let index = ASKEvidenceIndex(store: store)
        #expect(try await index.search(.init(text: "17,000")).map(\.sourceID) == [SourceID("thousands")])
        #expect(try await index.search(.init(text: "17.5")).map(\.sourceID) == [SourceID("decimal")])
        #expect(try await index.search(.init(text: "17원")).map(\.sourceID) == [SourceID("exact")])
    }

    @Test func boundsFailBeforeIO() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try ASKEvidenceIndex(workspaceURL: root)
        await #expect(throws: (any Error).self) { _ = try await index.buildGroundedPack(.init(text: ""), maxBytes: -1) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
