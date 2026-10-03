import Foundation
import Testing
import KnowledgeRuntime
import PageIndex
import EvidenceIndex
@testable import WorkWiki

struct WorkWikiRevisionWorkflowTests {
    private struct Fixture {
        let root: URL
        let file: URL
        let sourceRoot: URL
        let store: SourceIndexStore
        let evidence: ASKEvidenceIndex
        let maintainer: ASKRuntimeKnowledgeMaintainer
        let runtime: ASKWorkWikiRuntime

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            sourceRoot = root.appendingPathComponent("sources")
            file = sourceRoot.appendingPathComponent("2026-09-06.md")
            store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
            evidence = try ASKEvidenceIndex(workspaceURL: root.appendingPathComponent("index"))
            maintainer = ASKRuntimeKnowledgeMaintainer(root: root.appendingPathComponent("vault"))
            runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidence)
            _ = try await index("Done: recovery validated")
        }

        @discardableResult func index(_ text: String) async throws -> SourceIndexArtifact {
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let data = Data(text.utf8); try data.write(to: file)
            let id = SourceIdentityFactory.makeID(forFileAt: file)
            let range = try SourceRange(space: .line, start: 1, end: 1)
            let metadata = ASKEvidenceMetadata(sourceID: id, sourcePath: file.path,
                documentTitle: "2026-09-06", scope: .work, kind: .worklog, updatedAt: "2026-09-06T00:00:00Z")
            let artifact = SourceIndexArtifact(document: SourceIndexDocument(sourceID: id, type: .md,
                title: "2026-09-06", coordinateSpace: .line, extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "Recovery", range: range, snippet: text)]),
                excerpts: [SourceExcerpt(index: 1, content: text)], version: SourceIdentityFactory.makeVersion(data: data),
                sourcePath: file.path, evidenceMetadata: metadata, extractionQuality: .digitalText)
            _ = try await store.reconcile([artifact], sourceRootURL: sourceRoot, discoveredSourceURLs: [file])
            return artifact
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func report(_ time: String = "2026-09-06T00:00:00Z") -> ASKWorkWikiReportRequest {
        ASKWorkWikiReportRequest(title: "Recovery", queryText: "recovery", requestedAt: time,
            slug: "work/reports/recovery")
    }
    private func approval(_ id: String, at: String = "2026-09-06T01:00:00Z", fresh: Bool = true) -> ASKWorkWikiReportApprovalRequest {
        ASKWorkWikiReportApprovalRequest(patchID: id, decidedBy: "reviewer", decidedAt: at,
            reason: "reviewed exact evidence", requireFreshEvidence: fresh)
    }

    @Test func normalStageApproveAndRejectUseRealJournal() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let plan = try await f.runtime.stageReport(report())
        #expect(plan.projectionWrite.document.metadata.sourceVersionChecksums.count == 1)
        _ = try await f.runtime.approveReport(approval(plan.patch.patchID))
        let committed = try #require(try f.maintainer.projectionDocument(slug: plan.projectionWrite.slug))
        #expect(committed.generatedFromHash == plan.projectionWrite.document.generatedFromHash)
        let next = try await f.runtime.stageReport(report("2026-09-06T02:00:00Z"))
        #expect(next.projectionWrite.precondition?.expectedBaseRevision == committed.generatedFromHash)
        _ = try await f.runtime.rejectReport(ASKWorkWikiReportRejectionRequest(patchID: next.patch.patchID,
            decidedBy: "reviewer", decidedAt: "2026-09-06T03:00:00Z", reason: "not approved"))
        #expect(try f.maintainer.projectionDocument(slug: plan.projectionWrite.slug) == committed)
        #expect(try f.maintainer.pendingPatchPlans().isEmpty)
    }

    @Test func closeDayStageApproveAndConcurrentDraftCAS() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        func request(_ time: String) -> ASKWorkWikiCloseDayRequest {
            ASKWorkWikiCloseDayRequest(date: "2026-09-06", queryText: "recovery", requestedAt: time)
        }
        let first = try await f.runtime.closeDay(request("2026-09-06T00:00:00Z"))
        #expect(first.projectionWrite.document.metadata.sourceVersionChecksums.count == 1)
        _ = try await f.runtime.approveReport(approval(first.patch.patchID))
        let base = try #require(try f.maintainer.projectionDocument(slug: first.projectionWrite.slug))
        var replacementRequest = request("2026-09-06T02:00:00Z")
        replacementRequest.queryText = "recovery validated"
        let a = try await f.runtime.closeDay(replacementRequest)
        let b = try await f.runtime.closeDay(request("2026-09-06T03:00:00Z"))
        #expect(a.projectionWrite.precondition?.expectedBaseRevision == base.generatedFromHash)
        #expect(a.projectionWrite.document.generatedFromHash != base.generatedFromHash)
        #expect(b.projectionWrite.precondition?.expectedBaseRevision == base.generatedFromHash)
        _ = try await f.runtime.approveReport(approval(a.patch.patchID, at: "2026-09-06T04:00:00Z"))
        let accepted = try f.maintainer.projectionDocument(slug: first.projectionWrite.slug)
        await #expect(throws: (any Error).self) {
            try await f.runtime.approveReport(approval(b.patch.patchID, at: "2026-09-06T05:00:00Z"))
        }
        #expect(try f.maintainer.projectionDocument(slug: first.projectionWrite.slug) == accepted)
    }

    @Test(arguments: [false, true]) func changedOrRetiredSourceCannotBypassRevisionCheck(retired: Bool) async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let plan = try await f.runtime.stageReport(report())
        if retired {
            try FileManager.default.removeItem(at: f.file)
            _ = try await f.store.reconcile([], sourceRootURL: f.sourceRoot, discoveredSourceURLs: [])
        } else {
            _ = try await f.index("Done: recovery changed")
        }
        await #expect(throws: ASKWorkWikiError.self) {
            try await f.runtime.approveReport(approval(plan.patch.patchID, fresh: false))
        }
        #expect(try f.maintainer.projectionDocument(slug: plan.projectionWrite.slug) == nil)
        #expect(try f.maintainer.pendingPatchPlans().count == 1)
    }

    @Test func missingOrConflictingRevisionFailsBothProducers() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let plan = try await f.runtime.planReport(report())
        var pack = plan.evidencePack
        pack.hits[0].sourceVersionChecksum = nil
        #expect(throws: ASKError.self) {
            try ASKWorkWikiReportProjection.makeProjectionWrite(request: report(), evidencePack: pack, expectedBaseRevision: nil)
        }
        let close = ASKWorkWikiCloseDayRequest(date: "2026-09-06", requestedAt: "2026-09-06T00:00:00Z")
        #expect(throws: ASKError.self) {
            try ASKWorkWikiCloseDay.makeProjectionWrite(request: close, evidencePack: pack,
                documents: [pack.hits[0].metadata], summary: .init(), expectedBaseRevision: nil)
        }
        var duplicate = plan.evidencePack.hits[0]
        duplicate.sourceVersionChecksum = String(repeating: "f", count: 64)
        pack = plan.evidencePack; pack.hits.append(duplicate)
        #expect(throws: ASKError.self) {
            try ASKWorkWikiReportProjection.makeProjectionWrite(request: report(), evidencePack: pack, expectedBaseRevision: nil)
        }
    }

    @Test func reportWithoutSourceRevisionsIsRejectedByApproval() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let plan = try await f.runtime.planReport(report())
        var write = plan.projectionWrite
        write.document.metadata.sourceVersionChecksums = [:]
        write.document.generatedFromHash = projectionDocumentHash(write.document)
        let unsupported = try f.maintainer.planProjectionRefresh(RefreshProjectionRequest(
            version: refreshProjectionRequestVersion, requestedAt: "2026-09-06T00:00:00Z",
            trigger: "workwiki_report", proposedWrites: [write]))
        try f.maintainer.ensureKnowledgeBase(); try f.maintainer.stage(unsupported.patch)
        await #expect(throws: ASKWorkWikiError.self) {
            try await f.runtime.approveReport(approval(unsupported.patch.patchID, fresh: false))
        }
        #expect(try f.maintainer.projectionDocument(slug: write.slug) == nil)
    }
}