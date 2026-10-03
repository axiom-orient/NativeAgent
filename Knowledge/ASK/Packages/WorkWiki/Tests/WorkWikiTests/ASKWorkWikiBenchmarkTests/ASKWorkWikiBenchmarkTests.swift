import XCTest
import WorkWiki

final class ASKWorkWikiBenchmarkTests: XCTestCase {
    func testLargeWorkspaceBenchmarkIndexesAndPublishesProjection() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.removeItem(at: workspace)

        let baselineURL = try XCTUnwrap(Bundle.module.url(forResource: "large-workspace-baseline", withExtension: "json"))
        let result = try await ASKWorkWikiLargeWorkspaceBenchmarkRunner().run(
            ASKWorkWikiLargeWorkspaceBenchmarkRequest(
                workspaceURL: workspace,
                documentCount: 12,
                requestedAt: "2026-04-20T10:00:00Z",
                resetExistingWorkspace: true,
                baselineURL: baselineURL
            )
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.operation, "benchmark-large-workspace")
        XCTAssertEqual(result.documentCount, 12)
        XCTAssertEqual(result.indexedCount, 12)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertGreaterThan(result.bytesWritten, 0)
        XCTAssertGreaterThan(result.evidenceHitCount, 0)
        XCTAssertEqual(result.projectionSlug, "work/reports/large-workspace-benchmark")
        XCTAssertGreaterThanOrEqual(result.durations.totalSeconds, result.durations.workflowSeconds)
        XCTAssertEqual(result.regression?.ok, true)
        XCTAssertEqual(result.regression?.failures, [])
        let path = try XCTUnwrap(result.publishedProjectionPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testBenchmarkProtectsExistingWorkspaceUnlessReset() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "keep".write(to: workspace.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await ASKWorkWikiLargeWorkspaceBenchmarkRunner().run(ASKWorkWikiLargeWorkspaceBenchmarkRequest(workspaceURL: workspace, documentCount: 1))
            XCTFail("Expected benchmark to reject non-empty workspace without reset")
        } catch {
            XCTAssertTrue(String(describing: error).contains("workspace already exists"))
        }
    }

    func testBenchmarkFailsWhenBaselineThresholdIsBreached() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let baselineURL = workspace.appendingPathComponent("impossible-baseline.json")
        let baseline = ASKWorkWikiBenchmarkBaseline(
            documentCount: 1,
            minimumIndexedCount: 1,
            maximumSkippedCount: 0,
            minimumEvidenceHitCount: 1,
            maximumWorkflowSeconds: 0.0,
            maximumTotalSeconds: 0.0
        )
        let data = try JSONEncoder().encode(baseline)
        try data.write(to: baselineURL)

        do {
            _ = try await ASKWorkWikiLargeWorkspaceBenchmarkRunner().run(
                ASKWorkWikiLargeWorkspaceBenchmarkRequest(
                    workspaceURL: workspace.appendingPathComponent("run", isDirectory: true),
                    documentCount: 1,
                    resetExistingWorkspace: true,
                    baselineURL: baselineURL
                )
            )
            XCTFail("Expected benchmark regression failure")
        } catch let error as ASKWorkWikiError {
            XCTAssertEqual(error.code, .benchmarkRegressionFailed)
        }
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ask-workwiki-benchmark-tests", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
