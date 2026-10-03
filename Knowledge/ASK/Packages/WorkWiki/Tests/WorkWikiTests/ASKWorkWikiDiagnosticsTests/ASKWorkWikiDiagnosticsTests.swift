import XCTest
import KnowledgeCore
import WorkWiki

final class ASKWorkWikiDiagnosticsTests: XCTestCase {
    func testHumanOutputSnapshotForQuickStartResult() {
        let result = ASKWorkWikiQuickStartResult(
            ok: true,
            operation: "quick-start",
            status: "applied",
            workspacePath: "/tmp/ask-workwiki-quick-start",
            sourceRootPath: "/tmp/ask-workwiki-quick-start/source",
            indexPath: "/tmp/ask-workwiki-quick-start/index",
            vaultPath: "/tmp/ask-workwiki-quick-start/vault",
            sourcePath: "/tmp/ask-workwiki-quick-start/source/work/days/2026-04-20.md",
            indexedCount: 1,
            indexedSourceIDs: ["src_abc"],
            queryText: "onboarding quick-start",
            reportTitle: "Quick Start Work Report",
            patchID: "patch_123",
            projectionSlug: "work/reports/quick-start-work-report",
            evidenceHitCount: 1,
            doctorFindingCountBeforeApproval: 1,
            applyDecision: "approved",
            remainingPendingPatchIDs: [],
            publishedProjectionPath: "/tmp/ask-workwiki-quick-start/vault/wiki/queries/work/reports/quick-start-work-report.md",
            publishedProjectionTitle: "Quick Start Work Report",
            publishedProjectionPreview: "# Quick Start Work Report\n\n## Evidence Pack",
            followUpActions: ["read storageHealth for vault /tmp/ask-workwiki-quick-start/vault and index /tmp/ask-workwiki-quick-start/index"]
        )

        XCTAssertEqual(
            ASKWorkWikiDiagnosticRenderer.render(result),
            """
            workwiki quick-start: applied
            Workspace: /tmp/ask-workwiki-quick-start
            Source: /tmp/ask-workwiki-quick-start/source/work/days/2026-04-20.md
            Indexed evidence: 1
            Evidence hits: 1
            Patch ID: patch_123
            Projection slug: work/reports/quick-start-work-report
            Published projection: /tmp/ask-workwiki-quick-start/vault/wiki/queries/work/reports/quick-start-work-report.md
            Preview:
              # Quick Start Work Report

              ## Evidence Pack
            Next:
              - read storageHealth for vault /tmp/ask-workwiki-quick-start/vault and index /tmp/ask-workwiki-quick-start/index
            """
        )
    }

    func testHumanOutputSnapshotForStructuredError() {
        let diagnostic = ASKWorkWikiDiagnostic.make(
            operation: "from-existing-workspace",
            error: ASKWorkWikiHostError.missingArgument("--source-root")
        )

        XCTAssertEqual(
            ASKWorkWikiDiagnosticRenderer.render(diagnostic),
            """
            workwiki diagnostic
            Operation: from-existing-workspace
            Code: missing_argument
            Problem: Missing required argument
            Cause: The host operation requires --source-root, but it was not provided.
            Next:
              - provide a markdown/PDF sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace for import
            """
        )
    }

    func testDomainErrorDiagnosticForStaleEvidence() {
        let diagnostic = ASKWorkWikiDiagnostic.make(
            operation: "approve",
            error: ASKWorkWikiError(.staleIndexedEvidence, "work-wiki report approval requires fresh indexed evidence: src_1")
        )

        XCTAssertEqual(diagnostic.code, .staleIndexedEvidence)
        XCTAssertEqual(diagnostic.problem, "Stale or missing evidence blocks approval")
        XCTAssertEqual(diagnostic.operation, "approve")
        XCTAssertTrue(diagnostic.suggestedActions.contains("run storage/freshness diagnostics for stale or missing evidence"))
        XCTAssertTrue(diagnostic.suggestedActions.contains("approve with requireFreshEvidence=false only after explicit review"))
    }

    func testDomainErrorDiagnosticForSourceWorkspaceOverlap() {
        let diagnostic = ASKWorkWikiDiagnostic.make(
            operation: "from-existing-workspace",
            error: ASKWorkWikiError(.sourceWorkspaceOverlap, "from-existing-workspace requires workspaceURL and sourceRootURL to be separate non-overlapping paths")
        )

        XCTAssertEqual(diagnostic.code, .sourceWorkspaceOverlap)
        XCTAssertEqual(diagnostic.problem, "Source and generated workspace overlap")
        XCTAssertEqual(diagnostic.suggestedActions, ["provide sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace when importing an existing workspace"])
    }

    func testDomainErrorDiagnosticsForFreshnessIndexArchiveAndBenchmarkFailures() {
        let freshness = ASKWorkWikiDiagnostic.make(
            operation: "doctor",
            error: ASKWorkWikiError(.freshnessCheckFailed, "failed to build evidence freshness report")
        )
        XCTAssertEqual(freshness.code, .freshnessCheckFailed)
        XCTAssertEqual(freshness.problem, "Freshness check failed")

        let index = ASKWorkWikiDiagnostic.make(
            operation: "from-existing-workspace",
            error: ASKWorkWikiError(.sourceIndexFailed, "failed to index source file: /tmp/a.md")
        )
        XCTAssertEqual(index.code, .sourceIndexFailed)
        XCTAssertEqual(index.problem, "Source indexing failed")

        let archive = ASKWorkWikiDiagnostic.make(
            operation: nil,
            error: ASKWorkWikiError(.archiveExportFailed, "archive export failed")
        )
        XCTAssertEqual(archive.code, .archiveExportFailed)
        XCTAssertEqual(archive.problem, "Archive export failed")

        let benchmark = ASKWorkWikiDiagnostic.make(
            operation: "benchmark-large-workspace",
            error: ASKWorkWikiError(.benchmarkRegressionFailed, "benchmark result failed baseline thresholds")
        )
        XCTAssertEqual(benchmark.code, .benchmarkRegressionFailed)
        XCTAssertEqual(benchmark.problem, "Benchmark regression threshold failed")
    }

    func testMissingVaultArgumentDiagnostic() {
        let diagnostic = ASKWorkWikiDiagnostic.make(operation: "doctor", error: ASKWorkWikiHostError.missingArgument("--vault"))

        XCTAssertEqual(diagnostic.code, .missingVaultPath)
        XCTAssertEqual(diagnostic.problem, "Missing vault path")
        XCTAssertEqual(diagnostic.cause, "The host operation requires --vault, but it was not provided.")
        XCTAssertEqual(diagnostic.suggestedActions, ["run quickStart with resetExistingWorkspace to create a fresh sample workspace", "provide vaultURL before running doctor"])
    }
}
