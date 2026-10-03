import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct MaterializationIncrementalTests {
    private func ingest(
        into root: URL,
        id: String,
        text: String,
        decidedAt: String,
        generatedAt: String = "2026-04-07T10:00:00Z"
    ) throws -> ASKApplySummary {
        let rawText = Data(text.utf8)
        let relative = "raw/evidence/2026-04-07/\(id).txt"
        let rawURL = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: id,
            connector: "note",
            sourceKind: .text,
            title: "Title \(id)",
            observedAt: generatedAt,
            capturedAt: generatedAt,
            rawRelpath: relative,
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["incremental"],
            metadata: [:],
            fragments: [
                CollectedFragment(fragmentID: "frag_\(id)", ordinal: 0, locator: [:], text: text, fingerprint: nil)
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "incremental/\(id)", requestedAt: generatedAt)
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: root).buildReceipt(
            for: plan,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: decidedAt
        )
        return try ASKRuntime(root: root).apply(plan, receipt)
    }

    private func fileContents(_ vault: Vault) throws -> [String: Data] {
        var output: [String: Data] = [:]
        for relative in try vault.allFiles() where try !vault.isTransientPath(relative) {
            output[relative] = try Data(contentsOf: vault.root.appendingPathComponent(relative))
        }
        return output
    }

    @Test
    func incrementalMaterializationMatchesFullRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        _ = try ingest(into: root, id: "src_one", text: "first incremental document", decidedAt: "2026-04-07T11:00:00Z")
        _ = try ingest(into: root, id: "src_two", text: "second incremental document", decidedAt: "2026-04-07T12:00:00Z")

        let vault = Vault(root: root)
        let incremental = try fileContents(vault)

        let snapshot = try vault.loadStoreFromJournal()
        try vault.clearGeneratedOutputs()
        try vault.materializeFromStore(snapshot.store, report: snapshot.report)
        let fullRewrite = try fileContents(vault)

        #expect(incremental == fullRewrite)
    }

    @Test
    func materializationRemovesStaleDerivedFilesAndEmptyDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        _ = try ingest(into: root, id: "src_stale", text: "stale sweep document", decidedAt: "2026-04-07T11:00:00Z")

        let vault = Vault(root: root)
        let staleFile = root.appendingPathComponent("wiki/topics/orphan/stale-page.md")
        try FileManager.default.createDirectory(at: staleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale\n".utf8).write(to: staleFile)

        let snapshot = try vault.loadStoreFromJournal()
        try vault.materializeFromStore(snapshot.store, report: snapshot.report)

        #expect(!FileManager.default.fileExists(atPath: staleFile.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki/topics/orphan").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki/topics").path))
    }

    @Test
    func applyDoesNotWriteThePerRecordTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        _ = try ingest(into: root, id: "src_norecords", text: "no record tree", decidedAt: "2026-04-07T11:00:00Z")

        let vault = Vault(root: root)
        let written = try vault.allFiles().filter { $0.hasPrefix("records/") }
        #expect(written.isEmpty)
    }

    @Test
    func representationsSurviveApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()
        let runtime = ASKRuntime(root: root)

        try runtime.upsertRepresentation(
            RepresentationRecord(
                version: representationRecordVersion,
                sourceID: "src_rep",
                kind: .ocrText,
                sourceContentHash: "sha256:unsupported",
                generatedAt: "2026-04-07T10:00:00Z",
                generator: "tester",
                bodyMD: "representation body",
                metadata: [:]
            )
        )
        _ = try ingest(into: root, id: "src_after_rep", text: "apply after representation", decidedAt: "2026-04-07T11:00:00Z")

        #expect(try runtime.listRepresentations(sourceID: "src_rep").count == 1)
    }

    @Test
    func recordSnapshotExportsOutsideTheVault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try ASKRuntime(root: root).ensureVault()

        _ = try ingest(into: root, id: "src_export", text: "exported record", decidedAt: "2026-04-07T11:00:00Z")

        let vault = Vault(root: root)
        try vault.exportRecordSnapshot(to: destination)

        let exported = try persistenceRelativeFiles(in: destination)
        #expect(exported.contains("records/sources/src_export.json"))
        #expect(exported.contains { $0.hasPrefix("records/fragments/src_export/") })
        #expect(exported.contains { $0.hasPrefix("records/claims/") })

        let decoded = try CanonicalJSON.load(
            SourceReceipt.self,
            from: destination.appendingPathComponent("records/sources/src_export.json")
        )
        #expect(decoded.sourceID == "src_export")

        #expect(throws: ASKError.self) {
            try vault.exportRecordSnapshot(to: root.appendingPathComponent("inside"))
        }
    }

    @Test
    func derivedOutputPlanRejectsPathsOutsideOwnedTrees() throws {
        var plan = DerivedOutputPlan()
        #expect(throws: ASKError.self) {
            try plan.putText("raw/evidence/escape.md", content: "nope")
        }
        #expect(throws: ASKError.self) {
            try plan.putText("../escape.md", content: "nope")
        }
        try plan.putText("index.md", content: "ok")
        #expect(throws: ASKError.self) {
            try plan.putText("index.md", content: "duplicate")
        }
    }

    @Test
    func backdatedReceiptLeavesStateEqualToARebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ASKRuntime(root: root).ensureVault()

        _ = try ingest(into: root, id: "src_late", text: "decided later in wall clock", decidedAt: "2026-04-07T18:00:00Z")
        // Decided before the patch that is already in the journal: replay order
        // puts this one first, so the apply must not simply fold it onto the tip.
        _ = try ingest(into: root, id: "src_back", text: "decided earlier in wall clock", decidedAt: "2026-04-07T09:00:00Z")

        let vault = Vault(root: root)
        let afterApply = try vault.dumpState()
        let afterApplyFiles = try fileContents(vault)

        _ = try vault.rebuild()
        let afterRebuild = try vault.dumpState()
        let afterRebuildFiles = try fileContents(vault)

        #expect(afterApply == afterRebuild)
        #expect(afterApplyFiles == afterRebuildFiles)
    }
}
