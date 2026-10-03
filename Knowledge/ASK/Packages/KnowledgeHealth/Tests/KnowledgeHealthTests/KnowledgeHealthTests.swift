import Foundation
import Testing
import EvidenceIndex
import KnowledgeRuntime
@testable import KnowledgeHealth

struct KnowledgeHealthTests {
    @Test
    func healthRuntimeReportsCanonicalAndDerivedComponents() async throws {
        let root = temp("health")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let index = root.appendingPathComponent("index", isDirectory: true)
        try ASKRuntime(root: vault).ensureVault()
        _ = try ASKEvidenceIndex(workspaceURL: index)
        let report = try await ASKKnowledgeStorageHealthIntegration
            .makeStorageHealthRuntime(vaultURL: vault, evidenceIndexURL: index)
            .healthReport()
        #expect(report.derivedFreshness.map(\.component).contains(.search))
        #expect(report.derivedFreshness.map(\.component).contains(.evidence))
    }

    @Test
    func evidenceRepairFailsClosedWhenIndexIsNotAtCanonicalGeneration() async throws {
        let root = temp("repair")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let index = root.appendingPathComponent("index", isDirectory: true)
        try ASKRuntime(root: vault).ensureVault()
        let runtime = try await ASKKnowledgeStorageHealthIntegration.makeStorageHealthRuntime(
            vaultURL: vault, evidenceIndexURL: index
        )
        await #expect(throws: (any Error).self) {
            _ = try await runtime.rebuild(.evidence)
        }
    }

    @Test
    func derivedHealthFailureIsReportedAsCorrupt() async throws {
        let root = temp("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try ASKRuntime(root: vault).ensureVault()
        let runtime = ASKStorageHealthRuntime(
            canonical: ASKVaultCanonicalGenerationReader(root: vault),
            derivedIndexes: [FailingDerivedReader()]
        )

        let report = try await runtime.healthReport()
        #expect(report.isHealthy == false)
        #expect(report.derivedFreshness.first?.state == .corrupt)
    }
}

private struct FailingDerivedReader: ASKDerivedGenerationReading, Sendable {
    var component: ASKDerivedComponent { get async { .evidence } }

    func currentGeneration() async throws -> ASKStorageGeneration? {
        throw ASKError.database("synthetic health failure")
    }

    func rebuild(to canonicalGeneration: ASKStorageGeneration) async throws -> ASKStorageGeneration {
        throw ASKError.database("synthetic health failure")
    }
}

private func temp(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ask-health-\(name)-\(UUID().uuidString)", isDirectory: true)
}
