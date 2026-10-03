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

final class ASKProductIntegrationTests: XCTestCase, @unchecked Sendable {}

extension ASKProductIntegrationTests {
    func makeTemporaryDirectory(suffix: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func seedProjectionKnowledge(
        rootURL: URL,
        slug: String,
        title: String,
        body: String,
        sourceIDs: [String]
    ) throws {
        let runtime = ASKRuntime(root: rootURL)
        _ = try runtime.ensureVault()
        let metadata = ProjectionMetadata(
            projectionKind: .sourceSummary,
            projectionSpace: .wiki,
            subjectKind: "topic",
            subjectID: slug.replacingOccurrences(of: "/", with: "_"),
            authorityIDs: [],
            sourceIDs: sourceIDs,
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: slug,
            title: title,
            bodyMD: body,
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-13T08:59:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        let request = RefreshProjectionRequest(
            version: refreshProjectionRequestVersion,
            requestedAt: "2026-04-13T08:59:00Z",
            trigger: "seed/\(slug)",
            proposedWrites: [ProjectionWrite(slug: slug, state: .accepted, document: document)]
        )
        let patch = try runtime.planProjectionRefresh(request).patch
        let receipt = try runtime.buildReceipt(
            for: patch,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-13T08:59:01Z"
        )
        _ = try runtime.apply(patch, receipt)
    }

    func seedPageIndex(
        workspace: ASKProductWorkspacePaths,
        askSourceID: String,
        projectionSlug: String
    ) async throws {
        try seedASKSourceEvidence(
            rootURL: workspace.askRoot,
            sourceID: askSourceID,
            title: "ASK source",
            body: """
# ASK source

ASK remains the truth owner.

## Tutoring

Tutor teaches from grounded ASK projections.
"""
        )
        let result = try await ASKProjectionPageIndexBuilder().build(
            slug: projectionSlug,
            reader: ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot),
            workspace: workspace.knowledgeWorkspace
        )
        XCTAssertEqual(result.unboundASKSourceIDs, [])
        XCTAssertEqual(result.bindings.map(\.askSourceID), [askSourceID])
        XCTAssertGreaterThan(result.backlinkAudit.resolved.count, 0)
    }

    func seedASKSourceEvidence(
        rootURL: URL,
        sourceID: String,
        title: String,
        body: String
    ) throws {
        let rawRelpath = "raw/evidence/2026-04-13/\(sourceID).md"
        let rawURL = rootURL.appendingPathComponent(rawRelpath, isDirectory: false)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: rawURL, atomically: true, encoding: .utf8)

        let runtime = ASKRuntime(root: rootURL)
        _ = try runtime.ensureVault()
        let request = IngestEvidenceRequest(
            version: ingestEvidenceRequestVersion,
            source: SourceReceipt(
                version: sourceReceiptVersion,
                sourceID: sourceID,
                connector: "test",
                sourceKind: .file,
                title: title,
                observedAt: "2026-04-13T08:58:00Z",
                capturedAt: "2026-04-13T08:58:01Z",
                canonicalURI: sourceURI(sourceID),
                contentHash: ASKSHA256.prefixedDigest(Data(body.utf8)),
                rawRelpath: rawRelpath,
                mimeType: "text/markdown",
                language: "en",
                tags: []
            ),
            fragments: [
                SourceFragment(
                    version: sourceFragmentVersion,
                    fragmentID: "\(sourceID)-frag-0",
                    sourceID: sourceID,
                    ordinal: 0,
                    locator: [:],
                    text: body,
                    fingerprint: nil
                )
            ],
            domain: "test/evidence",
            requestedAt: "2026-04-13T08:58:02Z",
            focusPrompt: nil
        )
        try request.validate()

        let patch = try runtime.planEvidenceIngest(request).patch
        let receipt = try runtime.buildReceipt(
            for: patch,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-13T08:58:03Z"
        )
        _ = try runtime.apply(patch, receipt)
    }

}

enum TestFailure: Error {
    case unexpectedCall(String)
}

actor OneShotMissingManifestPageRuntimeLoader: ASKPageRuntimePackageLoader {
    private let delegate = ASKPageFileSystemRuntimeLoader()
    private var invocationCount = 0

    func loadPackage(from location: ASKPageDocumentLocation) async throws -> ASKPageRuntimePackage {
        invocationCount += 1
        if invocationCount == 1 {
            let manifestURL = location.rootURL.appendingPathComponent(
                ASKPageRuntimeManifest.defaultFilename,
                isDirectory: false
            )
            throw ASKPageRuntimeError.missingManifest(manifestURL.path(percentEncoded: false))
        }
        return try await delegate.loadPackage(from: location)
    }

    func loadCount() -> Int {
        invocationCount
    }
}

struct ProductScriptedModelClient: TutorModelClient, Sendable {
    let explainHandler: @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft
    let solveHandler: @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft
    let practiceHandler: @Sendable (TutorPracticeModelRequest) async throws -> TutorPracticeDraft
    let gradeHandler: @Sendable (TutorGradeModelRequest) async throws -> TutorGradeDraft
    let planHandler: @Sendable (TutorPlanModelRequest) async throws -> TutorPlanDraft

    init(
        explainHandler: @escaping @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft,
        solveHandler: @escaping @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft = { _ in throw TestFailure.unexpectedCall("solve") },
        practiceHandler: @escaping @Sendable (TutorPracticeModelRequest) async throws -> TutorPracticeDraft = { _ in throw TestFailure.unexpectedCall("makePracticeSet") },
        gradeHandler: @escaping @Sendable (TutorGradeModelRequest) async throws -> TutorGradeDraft = { _ in throw TestFailure.unexpectedCall("grade") },
        planHandler: @escaping @Sendable (TutorPlanModelRequest) async throws -> TutorPlanDraft = { _ in throw TestFailure.unexpectedCall("plan") }
    ) {
        self.explainHandler = explainHandler
        self.solveHandler = solveHandler
        self.practiceHandler = practiceHandler
        self.gradeHandler = gradeHandler
        self.planHandler = planHandler
    }

    func explain(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
        try await explainHandler(request)
    }

    func solve(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
        try await solveHandler(request)
    }

    func makePracticeSet(_ request: TutorPracticeModelRequest) async throws -> TutorPracticeDraft {
        try await practiceHandler(request)
    }

    func grade(_ request: TutorGradeModelRequest) async throws -> TutorGradeDraft {
        try await gradeHandler(request)
    }

    func plan(_ request: TutorPlanModelRequest) async throws -> TutorPlanDraft {
        try await planHandler(request)
    }
}
