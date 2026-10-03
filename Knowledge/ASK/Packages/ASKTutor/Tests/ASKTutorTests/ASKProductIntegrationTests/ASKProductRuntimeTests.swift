import Foundation
import XCTest
@testable import ASKTutor
import KnowledgeCore
import KnowledgeRuntime
import EvidenceIndex
import PageIndex
import DocumentCore
import DocumentRuntime

extension ASKProductIntegrationTests {
    func testRuntimeCreatesCanonicalRootsAndBootstrapsTutor() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()

        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.workspace.askRoot.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.workspace.tutorStoreRoot.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.workspace.presentationBundlesRoot.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.workspace.pageIndexRoot.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.workspace.pendingTutorInsightsRoot.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.workspace.appliedTutorInsightsRoot.path(percentEncoded: false)))

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T00:00:00Z"
            )
        )
        XCTAssertEqual(learner.learnerID, "learner-1")

        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: "learner-1",
                title: "Warmup",
                scope: .global,
                requestedAt: "2026-04-13T00:01:00Z"
            )
        )
        XCTAssertEqual(session.learnerID, "learner-1")
        XCTAssertEqual(session.scope, .global)

        let indexedSources = try await runtime.pageIndex.listSources()
        XCTAssertTrue(indexedSources.isEmpty)
        XCTAssertTrue(try runtime.tutorInsightStore.list().isEmpty)
        XCTAssertTrue(try runtime.tutorInsightAppliedStore.list().isEmpty)
    }

    func testRuntimeLoadsPresentationBundleFromCanonicalRoot() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        let bundleRoot = try runtime.workspace.ensurePresentationBundleDirectory(named: "algebra/intro")
        try "# Intro\n\nASK product integration bundle.\n".write(
            to: bundleRoot.appendingPathComponent("document.md"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = ASKPageRuntimeManifest(
            markdown: ASKPageRuntimeMarkdownArtifact(
                path: "document.md",
                documentID: ASKPageDocumentID("doc.intro"),
                sourceID: ASKPageSourceID("source.intro"),
                title: "Intro"
            )
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: bundleRoot.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename),
            options: .atomic
        )

        let package = try await runtime.loadPresentationBundle(named: "algebra/intro")
        XCTAssertEqual(package.document.title, "Intro")
        XCTAssertEqual(package.selection.selectedKind, .markdown)
        XCTAssertEqual(package.selection.selectedPath, "document.md")
    }

    func testPresentationBundleNameRejectsTraversal() throws {
        let paths = ASKProductWorkspacePaths(rootURL: URL(fileURLWithPath: "/tmp/ask-product-tests", isDirectory: true))
        XCTAssertThrowsError(try paths.presentationBundleRoot(named: "../escape")) { error in
            XCTAssertEqual(error as? ASKProductIntegrationError, .invalidPresentationBundleName("../escape"))
        }
    }

    func testPresentationBundleNameRejectsEmptyPathComponents() throws {
        let paths = ASKProductWorkspacePaths(rootURL: URL(fileURLWithPath: "/tmp/ask-product-tests", isDirectory: true))
        XCTAssertThrowsError(try paths.presentationBundleRoot(named: "algebra//intro")) { error in
            XCTAssertEqual(error as? ASKProductIntegrationError, .invalidPresentationBundleName("algebra//intro"))
        }
    }

}
