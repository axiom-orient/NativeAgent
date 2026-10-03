import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct JournalOrderingTests {
    private let time = "2026-04-07T10:00:00Z"

    private func plan(
        _ id: String, slug: String = "work/reports/order", body: String,
        base: String? = nil, generatedAt: String? = nil
    ) -> KnowledgePatchPlan {
        var document = ProjectionDocument(
            version: projectionDocumentVersion, slug: slug, title: "Order", bodyMD: body,
            metadata: ProjectionMetadata(
                projectionKind: .queryArtifact, projectionSpace: .wiki,
                subjectKind: "work_report", subjectID: slug, authorityIDs: [],
                sourceIDs: [], claimIDs: [], historical: false, approvalRequired: false
            ), generatedFromHash: "pending", generatedAt: generatedAt ?? time
        )
        document.generatedFromHash = projectionDocumentHash(document)
        return KnowledgePatchPlan(
            version: knowledgePatchPlanVersion, patchID: id, patchKind: .projectionRefresh,
            generatedAt: generatedAt ?? time, sourceReceipts: [], sourceFragments: [],
            authorityRecords: [], projectionInvalidations: [],
            projectionWrites: [ProjectionWrite(
                slug: slug, state: .draft, document: document,
                precondition: ProjectionWritePrecondition(expectedBaseRevision: base)
            )], claims: [], evidence: [], claimEvidence: [], reviewItems: [], warnings: [],
            verification: VerificationReport(
                patchID: id, riskLevel: .medium, disposition: .needsReview,
                reasons: ["ordering_regression"], requiresHumanApproval: true
            ), operations: []
        )
    }

    private func receipt(_ plan: KnowledgePatchPlan, at: String) throws -> PatchDecisionReceipt {
        try ASKPatchDecisionFactory.makeReceipt(
            for: plan, decision: .approved, decidedBy: "tester", decidedAt: at
        )
    }

    private func journalBytes(_ root: URL) throws -> [String: Data] {
        let journal = root.appendingPathComponent(".ask/journal")
        let enumerator = try #require(FileManager.default.enumerator(
            at: journal, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var bytes: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                bytes[String(url.path.dropFirst(journal.path.count))] = try Data(contentsOf: url)
            }
        }
        return bytes
    }

    private func assertReplayEquality(_ vault: Vault) throws {
        let immediate = try vault.dumpState()
        _ = try vault.rebuild()
        #expect(try vault.dumpState() == immediate)
    }

    @Test(arguments: ["backdated", "equal-time-generated-order", "reverse-patch-id", "pending"])
    func invalidCanonicalCandidateNeverPublishes(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let first = plan("patch_z", body: "first")
        _ = try vault.apply(first, receipt: receipt(first, at: "2026-04-07T12:00:00Z"))
        let second = plan(
            "patch_a", body: "second", base: first.projectionWrites[0].document.generatedFromHash,
            generatedAt: kind == "equal-time-generated-order" ? "2026-04-07T09:00:00Z" : time
        )
        if kind == "pending" {
            try vault.stage(second)
            _ = try vault.rebuild()
        }
        let before = try journalBytes(root)
        let decidedAt = kind == "backdated" || kind == "pending"
            ? "2026-04-07T11:00:00Z" : "2026-04-07T12:00:00Z"
        #expect(throws: ASKError.self) {
            _ = try vault.apply(second, receipt: receipt(second, at: decidedAt))
        }
        #expect(try journalBytes(root) == before)
        try assertReplayEquality(vault)
    }

    @Test
    func successfulBackdatedAndDuplicateCommitsMatchReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let later = plan("patch_z", slug: "work/reports/later", body: "later")
        _ = try vault.apply(later, receipt: receipt(later, at: "2026-04-07T12:00:00Z"))
        let earlier = plan("patch_a", body: "earlier")
        let decision = try receipt(earlier, at: "2026-04-07T11:00:00Z")
        _ = try vault.apply(earlier, receipt: decision)
        try assertReplayEquality(vault)
        let before = try journalBytes(root)
        _ = try vault.apply(earlier, receipt: decision)
        #expect(try journalBytes(root) == before)
        try assertReplayEquality(vault)
    }

    @Test
    func batchRejectsInvalidLaterCandidateAndPreservesEarlierCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let first = plan("patch_z", body: "first")
        let invalid = plan("patch_a", body: "invalid", base: first.projectionWrites[0].document.generatedFromHash)
        let unattempted = plan("patch_next", slug: "work/reports/next", body: "unattempted")
        let result = try vault.applyBatch([
            (first, receipt(first, at: "2026-04-07T12:00:00Z")),
            (invalid, receipt(invalid, at: "2026-04-07T11:00:00Z")),
            (unattempted, receipt(unattempted, at: "2026-04-07T13:00:00Z"))
        ])
        #expect(result.applied.map(\.patchID) == [first.patchID])
        #expect(result.failure?.patchID == invalid.patchID)
        #expect(try vault.loadPatchPlan(patchID: invalid.patchID) == nil)
        #expect(try vault.loadPatchPlan(patchID: unattempted.patchID) == nil)
        try assertReplayEquality(vault)
    }

    @Test
    func batchUsesTheValidatedBackdatedStateForNextDependency() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let tip = plan("patch_tip", slug: "work/reports/tip", body: "tip")
        _ = try vault.apply(tip, receipt: receipt(tip, at: "2026-04-07T12:00:00Z"))
        let inserted = plan("patch_a", body: "inserted")
        let dependent = plan("patch_b", body: "dependent", base: inserted.projectionWrites[0].document.generatedFromHash)
        let result = try vault.applyBatch([
            (inserted, receipt(inserted, at: "2026-04-07T11:00:00Z")),
            (dependent, receipt(dependent, at: "2026-04-07T13:00:00Z"))
        ])
        #expect(result.failure == nil)
        #expect(result.applied.count == 2)
        try assertReplayEquality(vault)
    }

    @Test
    func appendConflictWithStandaloneEventIsRejectedBeforePublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let event = OperationLogEntry(
            logID: "log_shared", occurredAt: time, opKind: "observation", summary: "standalone event"
        )
        try vault.recordEvent(event)
        _ = try vault.rebuild()
        let before = try journalBytes(root)
        var candidate = plan("patch_event", body: "event")
        candidate.operations = [OperationLogEntry(
            logID: event.logID, occurredAt: time, opKind: "observation", summary: "patch operation"
        )]
        #expect(throws: ASKError.self) {
            _ = try vault.apply(candidate, receipt: receipt(candidate, at: "2026-04-07T12:00:00Z"))
        }
        #expect(try journalBytes(root) == before)
        try assertReplayEquality(vault)
    }
}