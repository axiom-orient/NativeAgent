import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct BatchApplyTests {
    private func decision(
        in root: URL,
        id: String,
        decidedAt: String,
        approved: Bool = true,
        writeRaw: Bool = true
    ) throws -> (plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) {
        let rawText = Data("batch document \(id)".utf8)
        let relative = "raw/evidence/2026-04-07/\(id).txt"
        if writeRaw {
            let rawURL = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rawText.write(to: rawURL)
        }
        let collected = CollectedSource(
            sourceID: id,
            connector: "note",
            sourceKind: .text,
            title: "Title \(id)",
            observedAt: "2026-04-07T10:00:00Z",
            capturedAt: "2026-04-07T10:00:00Z",
            rawRelpath: relative,
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["batch"],
            metadata: [:],
            fragments: [
                CollectedFragment(fragmentID: "frag_\(id)", ordinal: 0, locator: [:], text: "Batch fragment for \(id).", fingerprint: nil)
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "batch/\(id)", requestedAt: "2026-04-07T10:00:00Z")
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: root).buildReceipt(
            for: plan,
            decision: approved ? .approved : .rejected,
            decidedBy: "tester",
            decidedAt: decidedAt
        )
        return (plan, receipt)
    }

    @Test
    func batchMatchesApplyingOneAtATime() throws {
        let batchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: batchRoot) }
        let sequentialRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sequentialRoot) }
        _ = try ASKRuntime(root: batchRoot).ensureVault()
        _ = try ASKRuntime(root: sequentialRoot).ensureVault()

        var batched: [(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)] = []
        for index in 0..<5 {
            let stamp = String(format: "2026-04-07T1%d:00:00Z", index)
            batched.append(try decision(in: batchRoot, id: "src_b\(index)", decidedAt: stamp))
            let single = try decision(in: sequentialRoot, id: "src_b\(index)", decidedAt: stamp)
            _ = try ASKRuntime(root: sequentialRoot).apply(single.plan, single.receipt)
        }

        let result = try Vault(root: batchRoot).applyBatch(batched)
        #expect(result.applied.count == 5)
        #expect(result.failure == nil)

        let batchState = try Vault(root: batchRoot).dumpState()
        let sequentialState = try Vault(root: sequentialRoot).dumpState()
        #expect(batchState.approvedPatchIDs == sequentialState.approvedPatchIDs)
        #expect(batchState.searchDocs == sequentialState.searchDocs)
        #expect(batchState.visibleProjections == sequentialState.visibleProjections)
        #expect(batchState.files == sequentialState.files)
    }

    @Test
    func batchStateEqualsARebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        var batched: [(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)] = []
        for index in 0..<4 {
            batched.append(try decision(in: root, id: "src_r\(index)", decidedAt: String(format: "2026-04-07T1%d:00:00Z", index)))
        }
        batched.append(try decision(in: root, id: "src_rejected", decidedAt: "2026-04-07T19:00:00Z", approved: false))

        let vault = Vault(root: root)
        _ = try vault.applyBatch(batched)
        let afterBatch = try vault.dumpState()

        _ = try vault.rebuild()
        #expect(try vault.dumpState() == afterBatch)
    }

    @Test
    func aBackdatedDecisionInABatchStillMatchesARebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        let batched = [
            try decision(in: root, id: "src_late", decidedAt: "2026-04-07T18:00:00Z"),
            try decision(in: root, id: "src_early", decidedAt: "2026-04-07T09:00:00Z"),
        ]

        let vault = Vault(root: root)
        _ = try vault.applyBatch(batched)
        let afterBatch = try vault.dumpState()

        _ = try vault.rebuild()
        #expect(try vault.dumpState() == afterBatch)
    }

    @Test
    func aFailedDecisionStopsTheBatchAndKeepsWhatWasCommitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        let good = try decision(in: root, id: "src_good", decidedAt: "2026-04-07T11:00:00Z")
        // Approved without its raw capture on disk: rejected at commit time.
        let bad = try decision(in: root, id: "src_bad", decidedAt: "2026-04-07T12:00:00Z", writeRaw: false)
        let never = try decision(in: root, id: "src_never", decidedAt: "2026-04-07T13:00:00Z")

        let vault = Vault(root: root)
        let result = try vault.applyBatch([good, bad, never])

        #expect(result.applied.map(\.patchID) == [good.plan.patchID])
        #expect(result.failure?.patchID == bad.plan.patchID)

        let state = try vault.dumpState()
        #expect(state.approvedPatchIDs == [good.plan.patchID])
        #expect(!state.approvedPatchIDs.contains(never.plan.patchID))
        #expect(state.pendingPatchIDs.isEmpty)

        // What was committed survives an independent rebuild.
        _ = try vault.rebuild()
        #expect(try vault.dumpState() == state)
    }

    @Test
    func materializationFailurePreservesCommittedPrefixAndStoppingFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        let good = try decision(in: root, id: "src_materialized_good", decidedAt: "2026-04-07T11:00:00Z")
        let bad = try decision(
            in: root,
            id: "src_materialized_bad",
            decidedAt: "2026-04-07T12:00:00Z",
            writeRaw: false
        )

        // A real filesystem obstruction in a derived output. Canonical journal
        // publication remains possible, while materialization of index.md fails.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("index.md"),
            withIntermediateDirectories: false
        )

        do {
            _ = try ASKRuntime(root: root).applyBatch([good, bad])
            Issue.record("Expected a typed post-commit batch materialization error")
        } catch let error as ASKBatchPostCommitMaterializationError {
            #expect(error.applied.map(\.patchID) == [good.plan.patchID])
            #expect(error.applied.map(\.decision) == [PatchDecision.approved.rawValue])
            #expect(error.failure?.patchID == bad.plan.patchID)
            #expect(!error.cause.isEmpty)
        }

        let committed = try ASKRuntime(root: root).sourceReceipts(sourceIDs: ["src_materialized_good"])
        #expect(committed["src_materialized_good"] != nil)

        try FileManager.default.removeItem(at: root.appendingPathComponent("index.md"))
        let repaired = try ASKRuntime(root: root).rebuild()
        #expect(repaired.approvedPatchIDs == [good.plan.patchID])
    }

    @Test
    func anEmptyBatchIsANoOpThatStillReportsState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        let single = try decision(in: root, id: "src_solo", decidedAt: "2026-04-07T11:00:00Z")
        _ = try ASKRuntime(root: root).apply(single.plan, single.receipt)

        let vault = Vault(root: root)
        let before = try vault.dumpState()
        let result = try vault.applyBatch([])

        #expect(result.applied.isEmpty)
        #expect(result.failure == nil)
        #expect(result.rebuild.approvedPatchIDs == [single.plan.patchID])
        #expect(try vault.dumpState() == before)
    }

    @Test
    func applyingTheSameDecisionTwiceDoesNotDuplicateTheReplayReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        let decision = try decision(in: root, id: "src_repeat", decidedAt: "2026-04-07T11:00:00Z")
        let runtime = ASKRuntime(root: root)
        let first = try runtime.apply(decision.plan, decision.receipt)
        let beforeRetry = try runtime.snapshot()
        let second = try runtime.apply(decision.plan, decision.receipt)
        let afterRetry = try runtime.snapshot()

        #expect(second.rebuild.approvedPatchIDs == first.rebuild.approvedPatchIDs)
        #expect(afterRetry == beforeRetry)
        _ = try runtime.rebuild()
        #expect(try runtime.snapshot() == afterRetry)
    }

    @Test(arguments: ["not-a-digest", "sha256:unsupported"])
    func approvedDecisionRejectsAnUnverifiableEvidenceHash(_ contentHash: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        var prepared = try decision(in: root, id: "src_unverifiable", decidedAt: "2026-04-07T12:00:00Z")
        prepared.plan.sourceReceipts[0].contentHash = contentHash
        let receipt = try ASKRuntime(root: root).buildReceipt(
            for: prepared.plan,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-07T12:00:00Z"
        )

        #expect(throws: Error.self) {
            try ASKRuntime(root: root).apply(prepared.plan, receipt)
        }
    }
}
