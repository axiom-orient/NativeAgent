import XCTest
import WorkWiki

final class ASKWorkWikiPresentationTests: XCTestCase {
    func testFromExistingWorkspaceResultMapsToHeadlessPresentationModel() {
        let result = ASKWorkWikiFromExistingWorkspaceResult(
            ok: true,
            operation: "from-existing-workspace",
            status: "applied",
            workspacePath: "/tmp/workspace",
            sourceRootPath: "/tmp/source",
            indexPath: "/tmp/workspace/index",
            vaultPath: "/tmp/workspace/vault",
            indexedCount: 2,
            indexedSourceIDs: ["src_1", "src_2"],
            indexedPaths: ["/tmp/source/a.md", "/tmp/source/b.md"],
            skippedCount: 1,
            skippedSources: [ASKWorkWikiSkippedSource(path: "/tmp/source/c.pdf", reason: "PDFKit unavailable")],
            queryText: "shipping blocker",
            reportTitle: "Shipping Report",
            patchID: "patch_1",
            projectionSlug: "work/reports/shipping",
            evidenceHitCount: 3,
            doctorFindingCountBeforeApproval: 1,
            applyDecision: "approved",
            remainingPendingPatchIDs: [],
            publishedProjectionPath: "/tmp/workspace/vault/wiki/queries/work/reports/shipping.md",
            publishedProjectionTitle: "Shipping Report",
            publishedProjectionPreview: "# Shipping Report\nEvidence",
            followUpActions: ["read published projection at /tmp/workspace/vault/wiki/queries/work/reports/shipping.md", "read storageHealth for vault /tmp/workspace/vault and index /tmp/workspace/index"]
        )

        let model = ASKWorkWikiFromExistingWorkspacePresentationExtension.makePresentationModel(from: result)
        XCTAssertEqual(model.title, "Shipping Report")
        XCTAssertEqual(model.status, "applied")
        XCTAssertEqual(model.primaryAction?.label, "Read published projection")
        XCTAssertEqual(model.metrics.first?.value, "2")
        XCTAssertTrue(model.sections.contains { $0.title == "Skipped sources" })
    }
}
