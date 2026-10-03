import Foundation
import XCTest
import KnowledgeCore
import KnowledgeRuntime

final class ASKStorageIntegrationTests: XCTestCase {
    func testVaultStorageHealthReportsMissingSearchMirrorThenRebuilds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-storage-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = ASKRuntime(root: root)
        try runtime.ensureVault()

        let health = ASKStorageHealthIntegration.makeVaultStorageHealthRuntime(root: root)
        let initial = try await health.healthReport()
        XCTAssertEqual(initial.derivedFreshness.map(\.component), [.search])
        XCTAssertEqual(initial.derivedFreshness.first?.state, .missing)

        let rebuilt = try await health.rebuild(.search)
        XCTAssertEqual(rebuilt.results.map(\.component), [.search])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ask/generation/canonical.json").path))

        let after = try await health.healthReport()
        XCTAssertTrue(after.isHealthy)
        XCTAssertEqual(after.derivedFreshness.first?.state, .healthy)
    }

    func testApplyMaterializesHealthySearchMirror() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-storage-apply-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try ASKRuntime(root: root).ensureVault()
        let rawText = Data("shipping blocker owner handoff".utf8)
        let rawURL = root.appendingPathComponent("raw/evidence/2026-04-25/src_storage_apply.txt")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_storage_apply",
            connector: "note",
            sourceKind: .text,
            title: "Storage Apply Search",
            observedAt: "2026-04-25T10:00:00Z",
            capturedAt: "2026-04-25T10:00:00Z",
            rawRelpath: "raw/evidence/2026-04-25/src_storage_apply.txt",
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["shipping"],
            metadata: [:],
            fragments: [
                CollectedFragment(
                    fragmentID: "frag_storage_apply",
                    ordinal: 0,
                    locator: [:],
                    text: "Shipping blocker owner handoff must stay searchable after apply.",
                    fingerprint: nil
                )
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "notes/storage", requestedAt: "2026-04-25T10:01:00Z")
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: root).buildReceipt(
            for: plan,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-25T10:02:00Z"
        )

        _ = try ASKRuntime(root: root).apply(plan, receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ask/generation/canonical.json").path))

        let health = ASKStorageHealthIntegration.makeVaultStorageHealthRuntime(root: root)
        let report = try await health.healthReport()
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.derivedFreshness.map(\.state), [.healthy])
    }
}
