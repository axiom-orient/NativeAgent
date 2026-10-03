import Foundation
import XCTest
import EvidenceIndex
import PageIndex
@testable import WorkWiki

final class ASKWorkWikiQuickStartTests: XCTestCase, @unchecked Sendable {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-workwiki-quickstart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testQuickStartRunsEvidenceToApprovedProjectionPath() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await ASKWorkWikiQuickStartRunner().run(
            ASKWorkWikiQuickStartRequest(
                workspaceURL: workspace,
                requestedAt: "2026-04-20T10:00:00Z",
                decidedBy: "tester",
                reason: "verified quick start"
            )
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.operation, "quick-start")
        XCTAssertEqual(result.status, "applied")
        XCTAssertEqual(result.indexedCount, 1)
        XCTAssertFalse(result.indexedSourceIDs.isEmpty)
        XCTAssertEqual(result.reportTitle, "Quick Start Work Report")
        XCTAssertEqual(result.queryText, "onboarding quick-start")
        XCTAssertEqual(result.projectionSlug, "work/reports/quick-start-work-report")
        XCTAssertGreaterThan(result.evidenceHitCount, 0)
        XCTAssertEqual(result.applyDecision, "approved")
        XCTAssertTrue(result.remainingPendingPatchIDs.isEmpty)
        XCTAssertEqual(result.publishedProjectionTitle, "Quick Start Work Report")
        XCTAssertTrue(result.publishedProjectionPreview.contains("## Evidence Pack"))

        let publishedPath = try XCTUnwrap(result.publishedProjectionPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedPath))
        let published = try String(contentsOfFile: publishedPath, encoding: .utf8)
        XCTAssertTrue(published.contains("slug: \"work/reports/quick-start-work-report\""))
        XCTAssertTrue(published.contains("Freshness: ok"))
    }

    func testQuickStartProtectsExistingWorkspaceUnlessReset() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "keep".write(to: workspace.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await ASKWorkWikiQuickStartRunner().run(
                ASKWorkWikiQuickStartRequest(workspaceURL: workspace, requestedAt: "2026-04-20T10:00:00Z")
            )
            XCTFail("Expected quick-start to reject non-empty workspace without reset")
        } catch {
            XCTAssertTrue(String(describing: error).contains("workspace already exists"))
        }

        let result = try await ASKWorkWikiQuickStartRunner().run(
            ASKWorkWikiQuickStartRequest(workspaceURL: workspace, requestedAt: "2026-04-20T10:00:00Z", resetExistingWorkspace: true)
        )
        XCTAssertTrue(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("existing.txt").path))
    }

    func testFromExistingWorkspaceIndexesMarkdownAndPublishesProjection() async throws {
        let sourceRoot = try tempDirectory()
        let workspace = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: workspace)
        }
        try FileManager.default.removeItem(at: workspace)

        let noteURL = sourceRoot.appendingPathComponent("notes/project-alpha.md")
        try FileManager.default.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # Project Alpha

        ## Shipping blockers
        The onboarding blocker was fixed and release notes were prepared.

        ## Next actions
        Verify the beta feedback before shipping.
        """.write(to: noteURL, atomically: true, encoding: .utf8)

        let result = try await ASKWorkWikiQuickStartRunner().runFromExistingWorkspace(
            ASKWorkWikiFromExistingWorkspaceRequest(
                sourceRootURL: sourceRoot,
                workspaceURL: workspace,
                title: "Project Alpha Report",
                queryText: "onboarding blocker",
                requestedAt: "2026-04-20T10:00:00Z",
                decidedBy: "tester",
                reason: "verified existing workspace",
                slug: "work/reports/project-alpha",
                resetExistingWorkspace: true
            )
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.operation, "from-existing-workspace")
        XCTAssertEqual(result.status, "applied")
        XCTAssertEqual(result.indexedCount, 1)
        XCTAssertEqual(result.indexedPaths.map(normalizedTemporaryPath), [normalizedTemporaryPath(noteURL.path)])
        XCTAssertGreaterThan(result.evidenceHitCount, 0)
        XCTAssertEqual(result.applyDecision, "approved")
        XCTAssertTrue(result.remainingPendingPatchIDs.isEmpty)
        XCTAssertEqual(result.projectionSlug, "work/reports/project-alpha")
        XCTAssertEqual(result.publishedProjectionTitle, "Project Alpha Report")
        XCTAssertTrue(result.publishedProjectionPreview.contains("onboarding blocker"))

        let publishedPath = try XCTUnwrap(result.publishedProjectionPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedPath))
        let published = try String(contentsOfFile: publishedPath, encoding: .utf8)
        XCTAssertTrue(published.contains("slug: \"work/reports/project-alpha\""))
        XCTAssertTrue(published.contains("Freshness: ok"))
    }

    func testFromExistingWorkspaceRejectsOverlappingSourceAndWorkspacePaths() async throws {
        let sourceRoot = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let workspaceInsideSource = sourceRoot.appendingPathComponent("generated-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceInsideSource, withIntermediateDirectories: true)
        try "# Keep\n".write(to: sourceRoot.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)

        do {
            _ = try await ASKWorkWikiQuickStartRunner().runFromExistingWorkspace(
                ASKWorkWikiFromExistingWorkspaceRequest(
                    sourceRootURL: sourceRoot,
                    workspaceURL: workspaceInsideSource,
                    title: "Unsafe Workspace",
                    queryText: "keep",
                    requestedAt: "2026-04-20T10:00:00Z",
                    resetExistingWorkspace: true
                )
            )
            XCTFail("Expected from-existing-workspace to reject overlapping source/workspace paths")
        } catch {
            XCTAssertTrue(String(describing: error).contains("separate non-overlapping paths"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("keep.md").path))
    }


    func testFromExistingWorkspaceIndexesMarkdownAndPDFSourcesWithInjectedBuilder() async throws {
        let sourceRoot = try tempDirectory()
        let workspace = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: workspace)
        }
        try FileManager.default.removeItem(at: workspace)

        let markdownURL = sourceRoot.appendingPathComponent("notes/project-alpha.md")
        let pdfURL = sourceRoot.appendingPathComponent("briefs/project-alpha.pdf")
        try FileManager.default.createDirectory(at: markdownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Project Alpha\n\nMarkdown onboarding blocker evidence.\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        try "PDF onboarding blocker evidence and rollout note.".write(to: pdfURL, atomically: true, encoding: .utf8)

        let result = try await ASKWorkWikiQuickStartRunner(sourceArtifactBuilder: MixedSourceArtifactBuilder()).runFromExistingWorkspace(
            ASKWorkWikiFromExistingWorkspaceRequest(
                sourceRootURL: sourceRoot,
                workspaceURL: workspace,
                title: "Mixed Source Report",
                queryText: "onboarding blocker evidence",
                requestedAt: "2026-04-20T10:00:00Z",
                decidedBy: "tester",
                reason: "verified mixed source workspace",
                slug: "work/reports/mixed-source",
                resetExistingWorkspace: true
            )
        )

        XCTAssertEqual(result.indexedCount, 2)
        XCTAssertEqual(
            Set(result.indexedPaths.map(normalizedTemporaryPath)),
            Set([normalizedTemporaryPath(markdownURL.path), normalizedTemporaryPath(pdfURL.path)])
        )
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(result.skippedSources.isEmpty)
        XCTAssertGreaterThan(result.evidenceHitCount, 0)
        XCTAssertEqual(result.applyDecision, "approved")
        XCTAssertEqual(result.projectionSlug, "work/reports/mixed-source")
    }

    func testFromExistingWorkspaceRejectsSymlinkedSourceDirectory() async throws {
        let sourceRoot = try tempDirectory()
        let outsideRoot = try tempDirectory()
        let workspace = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
            try? FileManager.default.removeItem(at: workspace)
        }
        let secretURL = outsideRoot.appendingPathComponent("secret.md")
        try "outside source root".write(to: secretURL, atomically: true, encoding: .utf8)
        let linkURL = sourceRoot.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideRoot)
        try FileManager.default.removeItem(at: workspace)

        do {
            _ = try await ASKWorkWikiQuickStartRunner().runFromExistingWorkspace(
                ASKWorkWikiFromExistingWorkspaceRequest(
                    sourceRootURL: sourceRoot,
                    workspaceURL: workspace,
                    title: "Symlinked source",
                    queryText: "outside source",
                    requestedAt: "2026-04-20T10:00:00Z",
                    resetExistingWorkspace: true
                )
            )
            XCTFail("Expected symlinked source directory to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("symbolic link"))
        }
    }
}

private func normalizedTemporaryPath(_ path: String) -> String {
    path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
}

private struct MixedSourceArtifactBuilder: SourceArtifactBuilding {
    func buildArtifact(from url: URL, options: ASKPageIndexOptions) async throws -> SourceIndexArtifact {
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8) ?? url.lastPathComponent
        let version = SourceIdentityFactory.makeVersion(data: data)
        let sourceID = SourceIdentityFactory.makeID(forFileAt: url)
        let isPDF = url.pathExtension.lowercased() == "pdf"
        let range = try SourceRange(space: isPDF ? .page : .line, start: 1, end: 1)
        let node = SourceIndexNode(
            nodeID: "root",
            title: url.deletingPathExtension().lastPathComponent,
            range: range,
            summary: content,
            snippet: content
        )
        return SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: isPDF ? .pdf : .md,
                title: url.lastPathComponent,
                description: content,
                coordinateSpace: isPDF ? .page : .line,
                extentCount: 1,
                rootNodes: [node]
            ),
            excerpts: [SourceExcerpt(index: 1, content: content)],
            version: version,
            sourcePath: url.path,
            extractionQuality: .digitalText
        )
    }
}
