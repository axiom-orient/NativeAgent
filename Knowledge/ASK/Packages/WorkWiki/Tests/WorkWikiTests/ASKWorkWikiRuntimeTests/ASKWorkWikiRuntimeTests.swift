import Foundation
import XCTest
import KnowledgeRuntime
import KnowledgeCore
import EvidenceIndex
import PageIndex
@testable import WorkWiki

final class ASKWorkWikiRuntimeTests: XCTestCase, @unchecked Sendable {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMarkdown(_ content: String, named relativePath: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    private func indexMarkdown(_ url: URL, workspace: URL) async throws {
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()
        let artifact = try await builder.buildArtifact(from: url, options: options)
        let store = try SourceIndexStore(workspaceURL: workspace)
        _ = try await store.put(artifact)
    }

    func testStageReportCreatesDraftProjectionPatchFromFreshWorkEvidence() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: customer-a-onboarding
            status: active
            tags:
              - onboarding
            ---

            # Customer A Daily Work

            Customer A onboarding blocker was reproduced and fixed in staging.

            ## Result
            The retry path now completes onboarding.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let plan = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: "Customer A Weekly Report",
                queryText: "onboarding blocker fixed",
                requestedAt: "2026-04-20T00:00:00Z",
                slug: "work/reports/customer-a-weekly",
                subjectID: "customer-a-weekly",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["customer-a-onboarding"]),
                maxEvidenceBytes: 8_000
            )
        )

        XCTAssertEqual(plan.patch.patchKind, .projectionRefresh)
        XCTAssertEqual(plan.patch.projectionWrites.count, 1)
        XCTAssertEqual(plan.projectionWrite.slug, "work/reports/customer-a-weekly")
        XCTAssertEqual(plan.projectionWrite.state, .draft)
        XCTAssertEqual(plan.projectionWrite.document.metadata.projectionKind, .queryArtifact)
        XCTAssertEqual(plan.projectionWrite.document.metadata.subjectKind, "work_report")
        XCTAssertFalse(plan.projectionWrite.document.metadata.sourceIDs.isEmpty)
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("# Customer A Weekly Report"))
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("## Evidence Pack"))
        XCTAssertFalse(plan.evidencePack.hits.isEmpty)
        XCTAssertTrue(plan.evidencePack.hits.allSatisfy { $0.freshness == .ok })

        let stagedPatch = askRoot
            .appendingPathComponent(".ask/journal/patches", isDirectory: true)
            .appendingPathComponent(plan.patch.patchID, isDirectory: true)
            .appendingPathComponent("patch.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPatch.path))
    }

    func testPlanReportRejectsStaleEvidenceByDefault() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: stale-topic
            ---

            # Stale Work
            stale blocker evidence
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)
        try "# Stale Work\nchanged after indexing\n".data(using: .utf8)?.write(to: evidenceURL)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        do {
            _ = try await runtime.planReport(
                ASKWorkWikiReportRequest(
                    title: "Stale Report",
                    queryText: "stale blocker",
                    requestedAt: "2026-04-20T00:00:00Z",
                    filter: ASKEvidenceFilter(scopes: [.work], topics: ["stale-topic"])
                )
            )
            XCTFail("Expected stale-only evidence to be rejected")
        } catch let error as ASKWorkWikiError {
            XCTAssertEqual(error.code, .staleIndexedEvidence)
            XCTAssertEqual(
                error.message,
                "work-wiki report matched 1 evidence hit(s) but every source is stale or missing; re-index the sources or set includeStaleEvidence"
            )
            XCTAssertEqual(error.context["usable_hits"], "0")
            XCTAssertEqual(error.context["include_stale_evidence"], "false")
        }
    }

    /// An empty evidence pack has three independent causes. Reporting them as one
    /// error points the caller at the wrong fix, so each keeps its own code.
    func testPlanReportSeparatesEmptyEvidenceCauses() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: budget-topic
            ---

            # Budget Work

            The SQLite mirror rebuild cost was measured on a cold start.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let runtime = ASKWorkWikiRuntime(
            maintainer: ASKRuntimeKnowledgeMaintainer(root: askRoot),
            evidenceIndex: try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        )

        func planReport(queryText: String, maxEvidenceBytes: Int) async throws {
            _ = try await runtime.planReport(
                ASKWorkWikiReportRequest(
                    title: "Report",
                    queryText: queryText,
                    requestedAt: "2026-04-20T00:00:00Z",
                    maxEvidenceBytes: maxEvidenceBytes
                )
            )
        }

        do {
            try await planReport(queryText: "unmatched terminology", maxEvidenceBytes: 16_000)
            XCTFail("Expected an unmatched query to be rejected")
        } catch let error as ASKWorkWikiError {
            XCTAssertEqual(error.code, .noFreshEvidence)
            XCTAssertEqual(error.context["matched_hits"], "0")
        }

        do {
            try await planReport(queryText: "SQLite mirror", maxEvidenceBytes: 40)
            XCTFail("Expected an unusable byte budget to be rejected")
        } catch let error as ASKWorkWikiError {
            XCTAssertEqual(error.code, .evidenceBudgetTooSmall)
            XCTAssertEqual(error.context["max_evidence_bytes"], "40")
            XCTAssertNotEqual(error.context["usable_hits"], "0")
        }
    }


}

extension ASKWorkWikiRuntimeTests {
    func testCaptureEvidenceImportsCollectedCaptureAndStagesEvidencePatch() async throws {
        let askRoot = try tempDirectory()
        let stagingRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
        }

        let sourceID = "src_work_capture"
        let observedAt = "2026-04-20T01:00:00Z"
        let rawRelpath = "raw/evidence/2026-04-20/src_work_capture.txt"
        let rawBytes = Data("Customer A onboarding evidence was captured from a work log.".utf8)
        let rawURL = stagingRoot.appendingPathComponent(rawRelpath)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawBytes.write(to: rawURL)

        let captureDir = stagingRoot
            .appendingPathComponent(".ask/collector/workwiki", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)

        let manifest = CollectedCaptureManifest(
            sourceID: sourceID,
            connector: "workwiki",
            transport: "file",
            originalURL: "file://work-log",
            finalURL: "file://work-log",
            title: "Work Capture",
            observedAt: observedAt,
            capturedAt: observedAt,
            rawRelpath: rawRelpath,
            noteRelpath: ".ask/collector/workwiki/src_work_capture/curated_note.md",
            contentHash: ASKSHA256.prefixedDigest(rawBytes),
            mimeType: "text/plain",
            language: "en",
            tags: ["work", "capture"],
            metadata: ["scope": "work"],
            fragments: [
                CollectedCaptureFragment(
                    fragmentID: "frag_work_capture",
                    ordinal: 0,
                    text: "Customer A onboarding evidence was captured from a work log.",
                    locator: ["line": "1"]
                )
            ]
        )
        try CanonicalJSON.data(for: manifest)
            .write(to: captureDir.appendingPathComponent("capture_manifest.json"))

        let collected = CollectedSource(
            sourceID: sourceID,
            connector: "workwiki",
            sourceKind: .text,
            title: "Work Capture",
            observedAt: observedAt,
            capturedAt: observedAt,
            rawRelpath: rawRelpath,
            contentHash: ASKSHA256.prefixedDigest(rawBytes),
            mimeType: "text/plain",
            language: "en",
            tags: ["work", "capture"],
            metadata: ["scope": "work"],
            fragments: [
                CollectedFragment(
                    fragmentID: "frag_work_capture",
                    ordinal: 0,
                    locator: ["line": "1"],
                    text: "Customer A onboarding evidence was captured from a work log.",
                    fingerprint: nil
                )
            ]
        )
        try CanonicalJSON.data(for: collected)
            .write(to: captureDir.appendingPathComponent("collected_source.json"))
        try Data("# Work Capture\nCaptured for work-wiki runtime.".utf8)
            .write(to: captureDir.appendingPathComponent("curated_note.md"))

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let plan = try await runtime.captureEvidence(
            ASKWorkWikiCaptureRequest(
                captureManifestPath: captureDir.appendingPathComponent("capture_manifest.json"),
                domain: "work/customer-a",
                requestedAt: "2026-04-20T01:01:00Z"
            )
        )

        XCTAssertEqual(plan.patch.patchKind, .evidenceIngest)
        XCTAssertEqual(plan.importedCapture.sourceID, sourceID)
        XCTAssertEqual(plan.ingestRequest.source.sourceID, sourceID)
        XCTAssertEqual(plan.ingestRequest.domain, "work/customer-a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: askRoot.appendingPathComponent(rawRelpath).path))

        let stagedPatch = askRoot
            .appendingPathComponent(".ask/journal/patches", isDirectory: true)
            .appendingPathComponent(plan.patch.patchID, isDirectory: true)
            .appendingPathComponent("patch.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPatch.path))
    }
}
extension ASKWorkWikiRuntimeTests {
    func testDoctorReportsStalePendingReportEvidence() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: doctor-topic
            status: active
            ---

            # Doctor Worklog
            doctor pending report evidence is fresh before staging.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        _ = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: "Doctor Pending Report",
                queryText: "pending report evidence",
                requestedAt: "2026-04-20T02:00:00Z",
                slug: "work/reports/doctor-pending-report",
                subjectID: "doctor-pending-report",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["doctor-topic"])
            )
        )

        try "# Doctor Worklog\nchanged after report staging\n".data(using: .utf8)?.write(to: evidenceURL)

        let report = try await runtime.doctor(
            ASKWorkWikiDoctorRequest(
                includeASKLint: false,
                checkPendingPatches: true,
                checkEvidenceFreshness: true,
                checkIndexedReports: false
            )
        )
        let kinds = Set(report.findings.map(\.kind))
        XCTAssertTrue(kinds.contains("pending_patch"))
        XCTAssertTrue(kinds.contains("evidence_source_stale"))
        XCTAssertTrue(kinds.contains("pending_work_report_source_stale"))
    }

    func testDoctorReportsIndexedReportWithoutSourceRefs() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let reportURL = try writeMarkdown(
            """
            ---
            scope: work
            type: report
            topic: doctor-report
            status: draft
            ---

            # Report without source refs
            This indexed report has no source_refs.
            """,
            named: "work-wiki/reports/2026-W17.md",
            under: sourceRoot
        )
        try await indexMarkdown(reportURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let report = try await runtime.doctor(
            ASKWorkWikiDoctorRequest(
                includeASKLint: false,
                checkPendingPatches: false,
                checkEvidenceFreshness: false,
                checkIndexedReports: true
            )
        )

        XCTAssertTrue(report.findings.contains { $0.kind == "indexed_report_missing_source_refs" && $0.severity == "error" })
    }
}

extension ASKWorkWikiRuntimeTests {
    func testCloseDayStagesDeterministicDailyReportFromExplicitWorklogMarkers() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let worklogURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: customer-a-onboarding
            status: active
            tags:
              - daily
            ---

            # 2026-04-20 Worklog

            ## Done
            - Customer A onboarding retry path fixed in staging.

            ## Blockers
            - Legal review remains blocked on API terms.

            ## Decisions
            - Decision: Do not auto-enable retry for expired sessions.

            ## Next
            - [ ] Send staging verification note to Customer A.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(worklogURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let plan = try await runtime.closeDay(
            ASKWorkWikiCloseDayRequest(
                date: "2026-04-20",
                queryText: "2026-04-20 onboarding legal retry staging",
                requestedAt: "2026-04-20T09:00:00Z",
                filter: ASKEvidenceFilter(scopes: [.work], kinds: [.worklog], topics: ["customer-a-onboarding"]),
                maxEvidenceBytes: 8_000
            )
        )

        XCTAssertEqual(plan.patch.patchKind, .projectionRefresh)
        XCTAssertEqual(plan.projectionWrite.slug, "work/reports/daily/2026-04-20")
        XCTAssertEqual(plan.projectionWrite.document.metadata.subjectKind, "work_report")
        XCTAssertFalse(plan.projectionWrite.document.metadata.sourceIDs.isEmpty)
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("## Deterministic Candidates"))
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("Customer A onboarding retry path fixed"))
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("Legal review remains blocked"))
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("Do not auto-enable retry"))
        XCTAssertTrue(plan.projectionWrite.document.bodyMD.contains("Send staging verification note"))
        XCTAssertEqual(plan.summary.done.count, 1)
        XCTAssertEqual(plan.summary.blockers.count, 1)
        XCTAssertEqual(plan.summary.decisions.count, 1)
        XCTAssertEqual(plan.summary.next.count, 1)

        let stagedPatch = askRoot
            .appendingPathComponent(".ask/journal/patches", isDirectory: true)
            .appendingPathComponent(plan.patch.patchID, isDirectory: true)
            .appendingPathComponent("patch.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPatch.path))
        XCTAssertNotNil(plan.projectionWrite.precondition)
        XCTAssertEqual(plan.projectionWrite.document.metadata.sourceVersionChecksums.count,
                       plan.projectionWrite.document.metadata.sourceIDs.count)
        let approved = try await runtime.approveReport(ASKWorkWikiReportApprovalRequest(
            patchID: plan.patch.patchID, decidedBy: "ax", decidedAt: "2026-04-20T09:05:00Z",
            reason: "approve the close-day producer through the same report consumer"
        ))
        XCTAssertEqual(approved.receipt.decision, .approved)
        XCTAssertEqual(try maintainer.projectionDocument(slug: plan.projectionWrite.slug)?.generatedFromHash,
                       plan.projectionWrite.document.generatedFromHash)

        // Two reviews see the same content revision. A changed body invalidates the other.
        let nextRequest = ASKWorkWikiCloseDayRequest(
            date: "2026-04-20", queryText: "onboarding retry",
            requestedAt: "2026-04-20T10:00:00Z", maxEvidenceBytes: 8_000
        )
        let next = try await runtime.closeDay(nextRequest)
        let competing = try await runtime.closeDay(ASKWorkWikiCloseDayRequest(
            date: "2026-04-20", queryText: nextRequest.queryText,
            requestedAt: "2026-04-20T10:01:00Z", maxEvidenceBytes: 8_000
        ))
        XCTAssertEqual(next.projectionWrite.precondition?.expectedBaseRevision,
                       plan.projectionWrite.document.generatedFromHash)
        _ = try await runtime.approveReport(ASKWorkWikiReportApprovalRequest(
            patchID: next.patch.patchID, decidedBy: "ax", decidedAt: "2026-04-20T10:05:00Z",
            reason: "replace the reviewed revision"
        ))
        do {
            _ = try await runtime.approveReport(ASKWorkWikiReportApprovalRequest(
                patchID: competing.patch.patchID, decidedBy: "ax", decidedAt: "2026-04-20T10:06:00Z",
                reason: "must not overwrite a newer projection"
            ))
            XCTFail("Expected stale projection CAS rejection")
        } catch {
            XCTAssertEqual(try maintainer.projectionDocument(slug: next.projectionWrite.slug)?.generatedFromHash,
                           next.projectionWrite.document.generatedFromHash)
        }
    }
}

extension ASKWorkWikiRuntimeTests {
    func testApproveReportAppliesPendingWorkReportPatchWithExplicitReceipt() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: approval-topic
            status: active
            ---

            # Approval Worklog
            approval evidence remains fresh before explicit report approval.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let staged = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: "Approval Report",
                queryText: "approval evidence fresh",
                requestedAt: "2026-04-20T03:00:00Z",
                slug: "work/reports/approval-report",
                subjectID: "approval-report",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["approval-topic"])
            )
        )

        let approved = try await runtime.approveReport(
            ASKWorkWikiReportApprovalRequest(
                patchID: staged.patch.patchID,
                decidedBy: "ax",
                decidedAt: "2026-04-20T03:05:00Z",
                reason: "explicitly approved work report after evidence review"
            )
        )

        XCTAssertEqual(approved.patch.patchID, staged.patch.patchID)
        XCTAssertEqual(approved.receipt.decision, .approved)
        XCTAssertEqual(approved.applySummary.patchID, staged.patch.patchID)
        XCTAssertEqual(approved.applySummary.decision, "approved")
        XCTAssertTrue(approved.sourceStatuses.allSatisfy { $0.freshness == "ok" })

        let visible = try maintainer.projectionDocument(slug: "work/reports/approval-report")
        XCTAssertEqual(visible?.metadata.subjectKind, "work_report")
        XCTAssertTrue(try maintainer.snapshot().approvedPatchIDs.contains(staged.patch.patchID))
    }

    func testApproveReportRejectsStaleEvidenceByDefault() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: stale-approval-topic
            status: active
            ---

            # Stale Approval Worklog
            stale approval evidence is fresh before staging.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let staged = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: "Stale Approval Report",
                queryText: "stale approval evidence",
                requestedAt: "2026-04-20T04:00:00Z",
                slug: "work/reports/stale-approval-report",
                subjectID: "stale-approval-report",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["stale-approval-topic"])
            )
        )

        try "# Stale Approval Worklog\nchanged after report staging\n".data(using: .utf8)?.write(to: evidenceURL)

        do {
            _ = try await runtime.approveReport(
                ASKWorkWikiReportApprovalRequest(
                    patchID: staged.patch.patchID,
                    decidedBy: "ax",
                    decidedAt: "2026-04-20T04:05:00Z",
                    reason: "attempt stale approval"
                )
            )
            XCTFail("Expected stale evidence approval to be rejected")
        } catch let error as ASKWorkWikiError {
            XCTAssertEqual(error.code, .staleIndexedEvidence)
            XCTAssertTrue(error.message.contains("requires fresh indexed evidence"))
        }
    }
}

extension ASKWorkWikiRuntimeTests {
    func testRejectReportRejectsPendingWorkReportPatchWithExplicitReceipt() async throws {
        let askRoot = try tempDirectory()
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: askRoot)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: rejection-topic
            status: active
            ---

            # Rejection Worklog
            rejection evidence supports a draft that should not be accepted.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: askRoot)
        let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)

        let staged = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: "Rejected Report",
                queryText: "draft should not be accepted",
                requestedAt: "2026-04-20T05:00:00Z",
                slug: "work/reports/rejected-report",
                subjectID: "rejected-report",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["rejection-topic"])
            )
        )

        let rejected = try await runtime.rejectReport(
            ASKWorkWikiReportRejectionRequest(
                patchID: staged.patch.patchID,
                decidedBy: "ax",
                decidedAt: "2026-04-20T05:05:00Z",
                reason: "draft report was reviewed and intentionally rejected"
            )
        )

        XCTAssertEqual(rejected.patch.patchID, staged.patch.patchID)
        XCTAssertEqual(rejected.receipt.decision, .rejected)
        XCTAssertEqual(rejected.applySummary.patchID, staged.patch.patchID)
        XCTAssertEqual(rejected.applySummary.decision, "rejected")
        XCTAssertNil(try maintainer.projectionDocument(slug: "work/reports/rejected-report"))
        let snapshot = try maintainer.snapshot()
        XCTAssertTrue(snapshot.rejectedPatchIDs.contains(staged.patch.patchID))
        XCTAssertFalse(snapshot.pendingPatchIDs.contains(staged.patch.patchID))
    }
}

extension ASKWorkWikiRuntimeTests {
    func testPlanReportDoesNotCreateKnowledgeVaultOrStagePatch() async throws {
        let container = try tempDirectory()
        let askRoot = container.appendingPathComponent("not-created-vault", isDirectory: true)
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: pure-plan
            ---

            # Pure planning
            Planning must not create or stage vault artifacts.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let runtime = ASKWorkWikiRuntime(
            maintainer: ASKRuntimeKnowledgeMaintainer(root: askRoot),
            evidenceIndex: try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        )

        let plan = try await runtime.planReport(
            ASKWorkWikiReportRequest(
                title: "Pure Plan",
                queryText: "planning vault artifacts",
                requestedAt: "2026-04-20T00:00:00Z",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["pure-plan"])
            )
        )

        XCTAssertEqual(plan.patch.patchKind, .projectionRefresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: askRoot.path))
    }

    func testPlanCloseDayDoesNotCreateKnowledgeVaultOrStagePatch() async throws {
        let container = try tempDirectory()
        let askRoot = container.appendingPathComponent("not-created-vault", isDirectory: true)
        let indexWorkspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: indexWorkspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let evidenceURL = try writeMarkdown(
            """
            ---
            scope: work
            type: worklog
            topic: pure-close-day
            ---

            # 2026-04-20
            ## Done
            - Pure close-day planning completed.
            """,
            named: "work-wiki/days/2026-04-20.md",
            under: sourceRoot
        )
        try await indexMarkdown(evidenceURL, workspace: indexWorkspace)

        let runtime = ASKWorkWikiRuntime(
            maintainer: ASKRuntimeKnowledgeMaintainer(root: askRoot),
            evidenceIndex: try ASKEvidenceIndex(workspaceURL: indexWorkspace)
        )

        let plan = try await runtime.planCloseDay(
            ASKWorkWikiCloseDayRequest(
                date: "2026-04-20",
                queryText: "pure close-day planning completed",
                requestedAt: "2026-04-20T00:00:00Z",
                filter: ASKEvidenceFilter(scopes: [.work], kinds: [.worklog], topics: ["pure-close-day"])
            )
        )

        XCTAssertEqual(plan.patch.patchKind, .projectionRefresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: askRoot.path))
    }
}
