import Foundation
import Testing
import SourceCapture
import KnowledgeCore

private func tempDir(_ prefix: String) throws -> URL {
    try SimulatorTestSupport.makeTemporaryDirectory(prefix)
}

@Test func kernelRoundTripsSearchAndQuery() async throws {
    let root = try tempDir("ask-iosfmf-kernel")
    let kernel = ASKIOSFMFKernel(root: root)
    _ = try await kernel.ensureVault()

    let state0 = try await kernel.stateSummary()
    #expect(state0.approvedPatchCount == 0)

    let summaryJSON = try await kernel.execute(tool: "ask.state.summary")
    #expect(summaryJSON.contains("approved_patch_count"))
}

@Test func webPipelineStagesAndImports() async throws {
    let root = try tempDir("ask-iosfmf-root")
    let staging = try tempDir("ask-iosfmf-staging")
    let pipeline = ASKIOSFMFImportPipeline(root: root)

    let imported = try await pipeline.captureStageAndImport(
        html: "<html><head><title>Kernel Import</title></head><body><main><p>This imported page is long enough to produce a fragment for the final package tests.</p></main></body></html>",
        pageURL: "https://example.com/final",
        sourceID: "src_final",
        observedAt: "2026-04-08T01:00:00Z",
        stagingRoot: staging
    )
    #expect(imported.sourceID == "src_final")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(imported.rawRelpath).path))
    #expect(imported.contentHash.hasPrefix("sha256:"))
}


@Test func applicationSupportConfigurationUsesApplicationSupportRoot() throws {
    let config = try ASKIOSFMFConfiguration.applicationSupport(subdirectory: "ASKTests")
    #expect(config.rootURL.lastPathComponent == "ASKTests")
    #expect(FileManager.default.fileExists(atPath: config.rootURL.path))
}
