import Foundation

public enum ASKWorkWikiErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case missingVaultPath = "missing_vault_path"
    case sourceWorkspaceOverlap = "source_workspace_overlap"
    case sourcePathNotFound = "source_path_not_found"
    case workspaceAlreadyExists = "workspace_already_exists"
    case noIndexableSources = "no_indexable_sources"
    case noFreshEvidence = "no_fresh_evidence"
    case freshnessCheckFailed = "freshness_check_failed"
    case staleIndexedEvidence = "stale_indexed_evidence"
    case evidenceBudgetTooSmall = "evidence_budget_too_small"
    case sourceIndexFailed = "source_index_failed"
    case archiveImportFailed = "archive_import_failed"
    case archiveExportFailed = "archive_export_failed"
    case benchmarkRegressionFailed = "benchmark_regression_failed"
    case pendingPatchNotFound = "pending_patch_not_found"
    case unsupportedPatch = "unsupported_patch"
}

public struct ASKWorkWikiError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    public var code: ASKWorkWikiErrorCode
    public var message: String
    public var context: [String: String]

    public init(_ code: ASKWorkWikiErrorCode, _ message: String, context: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.context = context
    }

    public var description: String {
        if context.isEmpty { return "\(code.rawValue): \(message)" }
        let rendered = context.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        return "\(code.rawValue): \(message) (\(rendered))"
    }

    public var errorDescription: String? { message }
}
