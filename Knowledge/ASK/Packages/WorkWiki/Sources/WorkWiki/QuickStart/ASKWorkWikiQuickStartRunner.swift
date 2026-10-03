import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

extension ASKWorkWikiQuickStartRunner {
    public func run(_ request: ASKWorkWikiQuickStartRequest) async throws -> ASKWorkWikiQuickStartResult {
        try validate(request)

        let workspaceURL = request.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        try prepareWorkspace(workspaceURL, reset: request.resetExistingWorkspace)

        let sourceRootURL = workspaceURL.appendingPathComponent("source", isDirectory: true)
        let sourceURL = sourceRootURL.appendingPathComponent("work/days/2026-04-20.md")
        let indexURL = (request.indexURL ?? workspaceURL.appendingPathComponent("index", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        let vaultURL = (request.vaultURL ?? workspaceURL.appendingPathComponent("vault", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()

        try writeQuickStartEvidence(to: sourceURL, updatedAt: request.requestedAt)
        let indexed = try await indexSourceFiles(sourceRootURL: sourceURL, indexURL: indexURL)

        let title = "Quick Start Work Report"
        let query = "onboarding quick-start"
        let completed = try await stageApproveAndReadProjection(
            title: title,
            queryText: query,
            requestedAt: request.requestedAt,
            decidedBy: request.decidedBy,
            reason: request.reason,
            slug: "work/reports/quick-start-work-report",
            subjectID: "quick-start-work-report",
            filter: ASKEvidenceFilter(scopes: [.work], kinds: [.worklog], topics: ["quickstart"]),
            maxEvidenceBytes: 262_144,
            includeStaleEvidence: false,
            vaultURL: vaultURL,
            indexURL: indexURL
        )

        return ASKWorkWikiQuickStartResult(
            operation: "quick-start",
            workspacePath: workspaceURL.path,
            sourceRootPath: sourceRootURL.path,
            indexPath: indexURL.path,
            vaultPath: vaultURL.path,
            sourcePath: sourceURL.path,
            indexedSourceIDs: indexed.sourceIDs.map(\.rawValue).sorted(),
            queryText: query,
            reportTitle: title,
            patchID: completed.patchID,
            projectionSlug: completed.projectionSlug,
            evidenceHitCount: completed.evidenceHitCount,
            doctorFindingCountBeforeApproval: completed.doctorFindingCountBeforeApproval,
            applyDecision: completed.applyDecision,
            remainingPendingPatchIDs: completed.remainingPendingPatchIDs,
            publishedProjectionPath: completed.publishedProjectionPath,
            publishedProjectionTitle: completed.publishedProjectionTitle,
            publishedProjectionPreview: completed.publishedProjectionPreview,
            followUpActions: followUpActions(indexURL: indexURL, vaultURL: vaultURL, query: query, projectionPath: completed.publishedProjectionPath)
        )
    }

    public func runFromExistingWorkspace(
        _ request: ASKWorkWikiFromExistingWorkspaceRequest
    ) async throws -> ASKWorkWikiFromExistingWorkspaceResult {
        try validate(request)

        let sourceRootURL = request.sourceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let workspaceURL = request.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        try prepareWorkspace(workspaceURL, reset: request.resetExistingWorkspace, preserving: sourceRootURL)

        let indexURL = (request.indexURL ?? workspaceURL.appendingPathComponent("index", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        let vaultURL = (request.vaultURL ?? workspaceURL.appendingPathComponent("vault", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        let indexed = try await indexSourceFiles(sourceRootURL: sourceRootURL, indexURL: indexURL)
        guard !indexed.sourceIDs.isEmpty else {
            let skippedSummary = indexed.skippedSources.isEmpty ? "no markdown or PDF source files found" : "all discovered source files were skipped"
            throw ASKWorkWikiError(.noIndexableSources, "from-existing-workspace requires at least one indexed markdown or PDF source; \(skippedSummary)")
        }

        let completed = try await stageApproveAndReadProjection(
            title: request.title,
            queryText: request.queryText,
            requestedAt: request.requestedAt,
            decidedBy: request.decidedBy,
            reason: request.reason,
            slug: request.slug,
            subjectID: request.subjectID,
            filter: request.filter,
            maxEvidenceBytes: request.maxEvidenceBytes,
            includeStaleEvidence: request.includeStaleEvidence,
            vaultURL: vaultURL,
            indexURL: indexURL
        )

        return ASKWorkWikiFromExistingWorkspaceResult(
            operation: "from-existing-workspace",
            workspacePath: workspaceURL.path,
            sourceRootPath: sourceRootURL.path,
            indexPath: indexURL.path,
            vaultPath: vaultURL.path,
            indexedSourceIDs: indexed.sourceIDs.map(\.rawValue).sorted(),
            indexedPaths: indexed.indexedPaths,
            skippedSources: indexed.skippedSources,
            queryText: request.queryText,
            reportTitle: request.title,
            patchID: completed.patchID,
            projectionSlug: completed.projectionSlug,
            evidenceHitCount: completed.evidenceHitCount,
            doctorFindingCountBeforeApproval: completed.doctorFindingCountBeforeApproval,
            applyDecision: completed.applyDecision,
            remainingPendingPatchIDs: completed.remainingPendingPatchIDs,
            publishedProjectionPath: completed.publishedProjectionPath,
            publishedProjectionTitle: completed.publishedProjectionTitle,
            publishedProjectionPreview: completed.publishedProjectionPreview,
            followUpActions: followUpActions(indexURL: indexURL, vaultURL: vaultURL, query: request.queryText, projectionPath: completed.publishedProjectionPath)
        )
    }
}
