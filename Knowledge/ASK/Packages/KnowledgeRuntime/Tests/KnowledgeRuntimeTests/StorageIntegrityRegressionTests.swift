import Foundation
import Testing
@testable import KnowledgeRuntime
import KnowledgeCore

struct StorageIntegrityRegressionTests {
    @Test func healthMustDetectActualCorruptSQLite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-health-observed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ASKRuntime(root: root)
        try runtime.ensureVault()
        _ = try runtime.rebuild()
        let health = ASKStorageHealthIntegration.makeVaultStorageHealthRuntime(root: root)
        #expect(try await health.healthReport().isHealthy)
        try Data("definitely not a SQLite database".utf8).write(to: root.appendingPathComponent("mirror/knowledge.sqlite"))
        let after = try await health.healthReport()
        #expect(!after.isHealthy)
    }

    @Test func materializationMustRejectExistingNestedEscapeSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-symlink-vault-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ask-symlink-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: outside) }
        try ASKRuntime(root: root).ensureVault()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("wiki/queries/escape"), withDestinationURL: outside)
        var plan = DerivedOutputPlan()
        try plan.putText("wiki/queries/escape/report.md", content: "MUST STAY INSIDE VAULT")
        var rejected = false
        do { try Vault(root: root).syncDerivedOutputs(plan) } catch { rejected = true }
        let escaped = FileManager.default.fileExists(atPath: outside.appendingPathComponent("report.md").path)
        #expect(rejected)
        #expect(!escaped)
    }
}

extension StorageIntegrityRegressionTests {
    @Test func publicApplyMustNotWriteOutsideThroughNestedSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-public-symlink-vault-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ask-public-symlink-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: outside) }
        let runtime = ASKRuntime(root: root)
        try runtime.ensureVault()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("wiki/queries/escape"), withDestinationURL: outside)
        let slug = "queries/escape/report"
        let metadata = ProjectionMetadata(projectionKind: .queryArtifact, projectionSpace: .wiki,
            subjectKind: "project", subjectID: "core-audit", authorityIDs: [], sourceIDs: [], claimIDs: [], historical: false, approvalRequired: false)
        var document = ProjectionDocument(version: projectionDocumentVersion, slug: slug, title: "Core audit",
            bodyMD: "PUBLIC APPLY OUTSIDE WRITE", metadata: metadata, generatedFromHash: "", generatedAt: "2026-09-12T00:00:00Z")
        document.generatedFromHash = projectionDocumentHash(document)
        let write = ProjectionWrite(slug: slug, state: .accepted, document: document)
        let patch = try runtime.planProjectionRefresh(RefreshProjectionRequest(version: refreshProjectionRequestVersion,
            requestedAt: "2026-09-12T00:00:00Z", trigger: "core-audit", proposedWrites: [write])).patch
        let receipt = try runtime.buildReceipt(for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-09-12T00:01:00Z")
        var rejected = false
        do { _ = try runtime.apply(patch, receipt) } catch { rejected = true }
        let escaped = FileManager.default.fileExists(atPath: outside.appendingPathComponent("report.md").path)
        #expect(rejected)
        #expect(!escaped)
    }
}
