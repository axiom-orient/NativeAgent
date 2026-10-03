import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

extension ASKWorkWikiQuickStartRunner {
    func stageApproveAndReadProjection(
        title: String,
        queryText: String,
        requestedAt: String,
        decidedBy: String,
        reason: String,
        slug: String?,
        subjectID: String?,
        filter: ASKEvidenceFilter,
        maxEvidenceBytes: Int,
        includeStaleEvidence: Bool,
        vaultURL: URL,
        indexURL: URL
    ) async throws -> CompletedWorkWikiProjection {
        let maintainer = ASKRuntimeKnowledgeMaintainer(root: vaultURL)
        let evidenceIndex = try await ASKEvidenceIndex.open(workspaceURL: indexURL)
        let runtime = ASKWorkWikiRuntime(maintainer: maintainer, evidenceIndex: evidenceIndex)
        let reportPlan = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: title,
                queryText: queryText,
                requestedAt: requestedAt,
                slug: slug,
                subjectID: subjectID,
                filter: filter,
                maxEvidenceBytes: maxEvidenceBytes,
                includeStaleEvidence: includeStaleEvidence
            )
        )
        let doctorReport = try await runtime.doctor(ASKWorkWikiDoctorRequest(evidenceFilter: filter))
        let approval = try await runtime.approveReport(
            ASKWorkWikiReportApprovalRequest(
                patchID: reportPlan.patch.patchID,
                decidedBy: decidedBy,
                decidedAt: requestedAt,
                reason: reason
            )
        )

        guard let publishedDocument = try maintainer.projectionDocument(slug: reportPlan.projectionWrite.slug) else {
            throw ASKError.notFound("work-wiki projection `\(reportPlan.projectionWrite.slug)` was not materialized")
        }
        let projectionPath = try findMaterializedProjectionPath(slug: reportPlan.projectionWrite.slug, under: vaultURL)
        return CompletedWorkWikiProjection(
            patchID: reportPlan.patch.patchID,
            projectionSlug: reportPlan.projectionWrite.slug,
            evidenceHitCount: reportPlan.evidencePack.hits.count,
            doctorFindingCountBeforeApproval: doctorReport.findingCount,
            applyDecision: approval.applySummary.decision,
            remainingPendingPatchIDs: approval.applySummary.rebuild.pendingPatchIDs,
            publishedProjectionPath: projectionPath?.path,
            publishedProjectionTitle: publishedDocument.title,
            publishedProjectionPreview: previewText(from: publishedDocument.bodyMD)
        )
    }

    func findMaterializedProjectionPath(slug: String, under vaultURL: URL) throws -> URL? {
        let expectedSlugLine = "slug: \"\(slug)\""
        for fileURL in try markdownFiles(under: vaultURL) {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if content.contains(expectedSlugLine) {
                return fileURL
            }
        }
        return nil
    }

    func previewText(from markdown: String, maxCharacters: Int = 700) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    func followUpActions(indexURL: URL, vaultURL: URL, query: String, projectionPath: String?) -> [String] {
        [
            "read evidenceSearch for query '\(query)' using index \(indexURL.path)",
            "read storageHealth for vault \(vaultURL.path) and index \(indexURL.path)",
            "read published projection at \(projectionPath ?? vaultURL.path)"
        ]
    }
}

struct CompletedWorkWikiProjection: Sendable, Equatable {
    var patchID: String
    var projectionSlug: String
    var evidenceHitCount: Int
    var doctorFindingCountBeforeApproval: Int
    var applyDecision: String
    var remainingPendingPatchIDs: [String]
    var publishedProjectionPath: String?
    var publishedProjectionTitle: String
    var publishedProjectionPreview: String
}
