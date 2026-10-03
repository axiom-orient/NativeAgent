import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

extension ASKWorkWikiQuickStartRunner {
    func validate(_ request: ASKWorkWikiQuickStartRequest) throws {
        guard !request.workspaceURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "quick-start workspace path must not be empty", context: ["field": "workspaceURL"])
        }
        try validateManagedPath(request.indexURL, workspaceURL: request.workspaceURL, field: "indexURL")
        try validateManagedPath(request.vaultURL, workspaceURL: request.workspaceURL, field: "vaultURL")
        try validateDecisionFields(requestedAt: request.requestedAt, decidedBy: request.decidedBy, reason: request.reason, prefix: "quick-start")
    }

    func validate(_ request: ASKWorkWikiFromExistingWorkspaceRequest) throws {
        guard !request.sourceRootURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "from-existing-workspace sourceRootURL must not be empty", context: ["field": "sourceRootURL"])
        }
        guard !request.workspaceURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "from-existing-workspace workspaceURL must not be empty", context: ["field": "workspaceURL"])
        }
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "from-existing-workspace title must not be empty", context: ["field": "title"])
        }
        guard !request.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "from-existing-workspace queryText must not be empty", context: ["field": "queryText"])
        }
        guard request.maxEvidenceBytes > 0 else {
            throw ASKWorkWikiError(.invalidRequest, "from-existing-workspace maxEvidenceBytes must be positive", context: ["field": "maxEvidenceBytes"])
        }
        try validateManagedPath(request.indexURL, workspaceURL: request.workspaceURL, field: "indexURL")
        try validateManagedPath(request.vaultURL, workspaceURL: request.workspaceURL, field: "vaultURL")
        try validateDecisionFields(requestedAt: request.requestedAt, decidedBy: request.decidedBy, reason: request.reason, prefix: "from-existing-workspace")
    }

    func validateManagedPath(_ value: URL?, workspaceURL: URL, field: String) throws {
        guard let value else { return }
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let managedPath = value.standardizedFileURL.resolvingSymlinksInPath().path
        guard managedPath.hasPrefix(workspacePath + "/") else {
            throw ASKWorkWikiError(
                .invalidRequest,
                "quick-start managed paths must be descendants of workspaceURL",
                context: ["field": field, "workspacePath": workspacePath, "path": managedPath]
            )
        }
    }

    func validateDecisionFields(requestedAt: String, decidedBy: String, reason: String, prefix: String) throws {
        guard ASKTimestamp.isValidRFC3339(requestedAt) else {
            throw ASKWorkWikiError(.invalidRequest, "\(prefix) requested_at must be valid RFC3339", context: ["field": "requestedAt"])
        }
        guard !decidedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "\(prefix) decided_by must not be empty", context: ["field": "decidedBy"])
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "\(prefix) reason must not be empty", context: ["field": "reason"])
        }
    }
}
