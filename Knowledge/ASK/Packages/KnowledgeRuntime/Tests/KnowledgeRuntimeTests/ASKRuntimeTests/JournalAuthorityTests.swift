import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct JournalAuthorityTests {
    private func makeVault() throws -> (URL, Vault) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try ASKRuntime(root: root).ensureVault()
        return (root, Vault(root: root))
    }

    @discardableResult
    private func ingest(into root: URL, id: String, decidedAt: String, term: String = "Checkpoint") throws -> KnowledgePatchPlan {
        let rawText = Data("checkpoint document \(id)".utf8)
        let relative = "raw/evidence/2026-04-07/\(id).txt"
        let rawURL = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: id,
            connector: "note",
            sourceKind: .text,
            title: "\(term) Title \(id)",
            observedAt: "2026-04-07T10:00:00Z",
            capturedAt: "2026-04-07T10:00:00Z",
            rawRelpath: relative,
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["checkpoint"],
            metadata: [:],
            fragments: [
                CollectedFragment(fragmentID: "frag_\(id)", ordinal: 0, locator: [:], text: "\(term) fragment for \(id).", fingerprint: nil)
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "checkpoint/\(id)", requestedAt: decidedAt)
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: root).buildReceipt(
            for: plan,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: decidedAt
        )
        _ = try ASKRuntime(root: root).apply(plan, receipt)
        return plan
    }


    @Test
    func obsoleteCheckpointCannotReplaceCanonicalStateOrAffectCommit() throws {
        let (root, vault) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try ingest(into: root, id: "src_retained", decidedAt: "2026-04-07T11:00:00Z")
        let expected = try vault.dumpState()
        let path = root.appendingPathComponent(".ask/generation/checkpoint.json")
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let fields = ["patchPlans", "sources", "sourceFragments", "authorityRecords", "projectionInvalidations", "projectionSlugs", "projectionWrites", "claims", "evidence", "claimEvidence", "reviewItems", "operationLogs"]
        let emptyStore = Dictionary(uniqueKeysWithValues: fields.map { ($0, [String]()) })
        let forged: [String: Any] = ["version": "2", "journalFingerprint": try vault.journalIdentity().fingerprint,
            "store": emptyStore, "approvedPatchIDs": expected.approvedPatchIDs,
            "rejectedPatchIDs": [String](), "pendingPatchIDs": [String]()]
        for bytes in [try JSONSerialization.data(withJSONObject: forged), Data("{not-json".utf8)] {
            try bytes.write(to: path)
            #expect(try vault.dumpState() == expected)
            #expect(try Data(contentsOf: path) == bytes)
        }
        try ingest(into: root, id: "src_after", decidedAt: "2026-04-07T12:00:00Z")
        let after = try vault.dumpState()
        #expect(after.approvedPatchIDs.count == 2)
        #expect(after.searchDocs.count > expected.searchDocs.count)
        _ = try vault.rebuild()
        #expect(try vault.dumpState() == after)
        #expect(!after.files.contains(".ask/generation/checkpoint.json"))
    }

    @Test
    func canonicalReadsDoNotCreateDerivedCheckpoints() throws {
        let (root, vault) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try ingest(into: root, id: "src_read", decidedAt: "2026-04-07T11:00:00Z")
        _ = try vault.loadStoreFromJournal()
        _ = try vault.dumpState()
        _ = try ASKRuntime(root: root).search("checkpoint fragment", limit: 5)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".ask/generation/checkpoint.json").path))
    }

    @Test
    func canonicalJournalReadLatency() throws {
        let (root, vault) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            try ingest(into: root, id: "src_bench_\(index)", decidedAt: String(format: "2026-04-07T11:%02d:00Z", index))
        }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<100 { #expect(try vault.loadStoreFromJournal().report.approvedPatchIDs.count == 20) }
        print("JOURNAL_READ_LATENCY entries=20 reads=100 duration=\(start.duration(to: clock.now))")
    }

    @Test
    func sameCountFailedMaterializationCannotServeOrReportStaleSearchAsCurrent() async throws {
        let (root, vault) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try ingest(into: root, id: "src_revision", decidedAt: "2026-04-07T11:00:00Z", term: "Saffron")
        let before = try vault.dumpState()
        let marker = try Data(contentsOf: vault.generationMarkerURL())
        let index = root.appendingPathComponent("index.md")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do {
            try ingest(into: root, id: "src_revision", decidedAt: "2026-04-07T12:00:00Z", term: "Cobalt")
            Issue.record("Expected actual post-commit materialization failure")
        } catch let error as ASKPostCommitMaterializationError {
            print("SAME_COUNT_MATERIALIZATION_FAILURE: \(error)")
        }
        let after = try vault.dumpState()
        #expect(after.approvedPatchIDs.count == 2)
        #expect(after.searchDocs.count == before.searchDocs.count)
        #expect(try Data(contentsOf: vault.generationMarkerURL()) == marker)
        let mirrorBefore = try Data(contentsOf: vault.mirrorURL())
        let canonical = ASKVaultCanonicalGenerationReader(root: root)
        let reader = ASKVaultSearchGenerationReader(root: root, canonical: canonical)
        let expected = try await canonical.currentGeneration()
        let observed = try await reader.currentGeneration()
        #expect(observed?.value != expected.value)
        let context = try await canonical.currentGenerationContext()
        #expect(try await reader.currentGeneration(context: context)?.value != expected.value)
        #expect(!(try searchMirrorFirst(root: root.path, query: "Cobalt", limit: 8)).isEmpty)
        #expect((try searchMirrorFirst(root: root.path, query: "Saffron", limit: 8)).isEmpty)
        #expect(try Data(contentsOf: vault.mirrorURL()) == mirrorBefore)
        #expect(try Data(contentsOf: vault.generationMarkerURL()) == marker)
    }

}
