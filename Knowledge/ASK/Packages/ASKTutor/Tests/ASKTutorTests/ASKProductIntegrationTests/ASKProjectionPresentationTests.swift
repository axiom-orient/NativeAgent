import Foundation
import XCTest
@testable import ASKTutor
import KnowledgeCore
import KnowledgeRuntime
import EvidenceIndex
import PageIndex
import DocumentCore
import DocumentRuntime
import KnowledgePresentation

extension ASKProductIntegrationTests {
    func testProjectionPageIndexBuilderBuildsBindingsFromASKSourceEvidence() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try seedASKSourceEvidence(
            rootURL: runtime.workspace.askRoot,
            sourceID: "ask-src-1",
            title: "ASK source",
            body: """
# ASK source

ASK remains the truth owner.

## Tutoring

Tutor teaches from grounded ASK projections.
"""
        )

        let builder = ASKProjectionPageIndexBuilder()
        let result = try await builder.build(
            slug: "wiki/asktutor",
            reader: ASKRuntimeKnowledgeMaintainer(root: runtime.workspace.askRoot),
            workspace: runtime.workspace.knowledgeWorkspace
        )
        XCTAssertEqual(result.projectionSlug, "wiki/asktutor")
        XCTAssertTrue(result.unboundASKSourceIDs.isEmpty)
        XCTAssertEqual(result.bindings.map(\.askSourceID), ["ask-src-1"])
        XCTAssertGreaterThan(result.backlinkAudit.resolved.count, 0)

        let readingContext = try await runtime.loadProjectionReadingContext(slug: "wiki/asktutor")
        XCTAssertEqual(readingContext.unboundSourceIDs, [])
        XCTAssertGreaterThan(readingContext.catalogEntries.count, 0)
        XCTAssertGreaterThan(readingContext.backlinkAudit.resolved.count, 0)
    }

    func testLoadProjectionPresentationRematerializesWhenRuntimeManifestIsMissing() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try seedASKSourceEvidence(
            rootURL: runtime.workspace.askRoot,
            sourceID: "ask-src-1",
            title: "ASK source",
            body: """
# ASK source

ASK remains the truth owner.
"""
        )

        _ = try await ASKProjectionPageIndexBuilder().build(
            slug: "wiki/asktutor",
            reader: ASKRuntimeKnowledgeMaintainer(root: runtime.workspace.askRoot),
            workspace: runtime.workspace.knowledgeWorkspace
        )
        let presentation = try runtime.materializeProjectionPresentation(slug: "wiki/asktutor")
        let runtimeManifestURL = presentation.bundleRootURL.appendingPathComponent(
            presentation.manifest.runtimeManifestPath,
            isDirectory: false
        )
        try FileManager.default.removeItem(at: runtimeManifestURL)

        let readingContext = try await runtime.loadProjectionReadingContext(slug: "wiki/asktutor")

        XCTAssertEqual(readingContext.presentation.projection.slug, "wiki/asktutor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeManifestURL.path(percentEncoded: false)))
    }

    func testLoadProjectionReadingContextRetriesAfterTransientMissingRuntimeManifest() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let pageLoader = OneShotMissingManifestPageRuntimeLoader()
        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            pageLoader: pageLoader
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )

        _ = try runtime.materializeProjectionPresentation(slug: "wiki/asktutor")

        let readingContext = try await runtime.loadProjectionReadingContext(slug: "wiki/asktutor")
        let loadCount = await pageLoader.loadCount()

        XCTAssertEqual(readingContext.presentation.projection.slug, "wiki/asktutor")
        XCTAssertEqual(loadCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: readingContext.presentation.bundleRootURL
                    .appendingPathComponent(ASKPageRuntimeManifest.defaultFilename, isDirectory: false)
                    .path(percentEncoded: false)
            )
        )
    }

    func testLoadProjectionReadingContextUsesDecodedFileSystemPathsWhenWorkspaceContainsSpaces() async throws {
        let rootURL = try makeTemporaryDirectory(suffix: " Application Support")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try seedASKSourceEvidence(
            rootURL: runtime.workspace.askRoot,
            sourceID: "ask-src-1",
            title: "ASK source",
            body: """
# ASK source

ASK remains the truth owner.
"""
        )

        _ = try await ASKProjectionPageIndexBuilder().build(
            slug: "wiki/asktutor",
            reader: ASKRuntimeKnowledgeMaintainer(root: runtime.workspace.askRoot),
            workspace: runtime.workspace.knowledgeWorkspace
        )

        let readingContext = try await runtime.loadProjectionReadingContext(slug: "wiki/asktutor")
        let runtimeManifestURL = readingContext.presentation.bundleRootURL
            .appendingPathComponent(ASKPageRuntimeManifest.defaultFilename, isDirectory: false)
            .standardizedFileURL
        let decodedPath = runtimeManifestURL.path(percentEncoded: false)
        let encodedPath = runtimeManifestURL.path()

        XCTAssertEqual(readingContext.presentation.projection.slug, "wiki/asktutor")
        XCTAssertTrue(decodedPath.contains("Application Support"))
        XCTAssertTrue(encodedPath.contains("Application%20Support"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decodedPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: encodedPath))
    }

}
