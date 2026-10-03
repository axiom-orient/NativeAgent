import Foundation
import KnowledgeCore
import EvidenceIndex
import PageIndex

public enum ASKWorkWikiDiagnosticCode: String, Codable, Sendable, Equatable {
    case helpRequested = "help_requested"
    case missingArgument = "missing_argument"
    case invalidArgument = "invalid_argument"
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
    case resourceNotFound = "resource_not_found"
    case applyFailed = "apply_failed"
    case journalConflict = "journal_conflict"
    case operationFailed = "operation_failed"
}

public enum ASKWorkWikiHostError: Error, CustomStringConvertible, Sendable, Equatable {
    case helpRequested
    case missingArgument(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .helpRequested:
            return "help requested"
        case .missingArgument(let flag):
            return "missing required argument \(flag)"
        case .invalidArgument(let message):
            return message
        }
    }
}

public struct ASKWorkWikiDiagnostic: Codable, Sendable, Equatable {
    public var ok: Bool
    public var operation: String?
    public var code: ASKWorkWikiDiagnosticCode
    public var problem: String
    public var cause: String
    public var suggestedActions: [String]

    public init(ok: Bool = false, operation: String?, code: ASKWorkWikiDiagnosticCode, problem: String, cause: String, suggestedActions: [String]) {
        self.ok = ok
        self.operation = operation
        self.code = code
        self.problem = problem
        self.cause = cause
        self.suggestedActions = suggestedActions
    }

    public var summary: String {
        "\(problem): \(cause)"
    }

    public static func make(operation: String?, error: Error) -> ASKWorkWikiDiagnostic {
        if let error = error as? ASKWorkWikiHostError {
            switch error {
            case .helpRequested:
                return ASKWorkWikiDiagnostic(operation: operation, code: .helpRequested, problem: "Help requested", cause: "No host operation was executed.", suggestedActions: ["choose a supported ASKCommand and create a plan before applying it"])
            case .missingArgument(let flag):
                if flag == "--vault" { return missingVaultDiagnostic(operation: operation) }
                return ASKWorkWikiDiagnostic(operation: operation, code: .missingArgument, problem: "Missing required argument", cause: "The host operation requires \(flag), but it was not provided.", suggestedActions: suggestedActions(for: operation, missingFlag: flag))
            case .invalidArgument(let message):
                return ASKWorkWikiDiagnostic(operation: operation, code: .invalidArgument, problem: "Invalid argument", cause: message, suggestedActions: suggestedActions(for: operation, missingFlag: nil))
            }
        }

        if let error = error as? ASKWorkWikiError { return workWikiErrorDiagnostic(operation: operation, error: error) }
        if let error = error as? ASKError { return askErrorDiagnostic(operation: operation, error: error) }

        return ASKWorkWikiDiagnostic(operation: operation, code: .operationFailed, problem: "Operation failed", cause: String(describing: error), suggestedActions: suggestedActions(for: operation, missingFlag: nil))
    }

    private static func workWikiErrorDiagnostic(operation: String?, error: ASKWorkWikiError) -> ASKWorkWikiDiagnostic {
        switch error.code {
        case .missingVaultPath:
            return missingVaultDiagnostic(operation: operation)
        case .sourceWorkspaceOverlap:
            return ASKWorkWikiDiagnostic(operation: operation, code: .sourceWorkspaceOverlap, problem: "Source and generated workspace overlap", cause: error.message, suggestedActions: ["provide sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace when importing an existing workspace"])
        case .sourcePathNotFound:
            return ASKWorkWikiDiagnostic(operation: operation, code: .sourcePathNotFound, problem: "Source path not found", cause: error.message, suggestedActions: ["provide an existing markdown or PDF sourceRootURL before importing an existing workspace"])
        case .workspaceAlreadyExists:
            return ASKWorkWikiDiagnostic(operation: operation, code: .workspaceAlreadyExists, problem: "Workspace already exists", cause: error.message, suggestedActions: workspaceResetActions(for: operation))
        case .noIndexableSources:
            return ASKWorkWikiDiagnostic(operation: operation, code: .noIndexableSources, problem: "No indexable sources found", cause: error.message, suggestedActions: ["find <source-root> -type f \\( -name '*.md' -o -name '*.markdown' -o -name '*.pdf' \\)", "provide a markdown/PDF sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace for import"])
        case .noFreshEvidence:
            return ASKWorkWikiDiagnostic(operation: operation, code: .noFreshEvidence, problem: "No indexed evidence matched the query", cause: error.message, suggestedActions: ["read evidenceSearch with the same query to confirm what the index contains", "index the source root before staging the report", "widen the query: every term must appear in the same catalog entry"])
        case .evidenceBudgetTooSmall:
            return ASKWorkWikiDiagnostic(operation: operation, code: .evidenceBudgetTooSmall, problem: "Evidence byte budget excludes every matching hit", cause: error.message, suggestedActions: ["raise maxEvidenceBytes until at least one hit fits", "narrow the query so the top hit is smaller"])
        case .freshnessCheckFailed:
            return ASKWorkWikiDiagnostic(operation: operation, code: .freshnessCheckFailed, problem: "Freshness check failed", cause: error.message, suggestedActions: ["run the storage health read path for the vault and evidence index", "inspect evidence freshness and rebuild stale or missing index entries"])
        case .staleIndexedEvidence:
            return ASKWorkWikiDiagnostic(operation: operation, code: .staleIndexedEvidence, problem: "Stale or missing evidence blocks approval", cause: error.message, suggestedActions: ["run storage/freshness diagnostics for stale or missing evidence", "inspect evidence freshness and rebuild stale or missing index entries", "approve with requireFreshEvidence=false only after explicit review"])
        case .sourceIndexFailed:
            return ASKWorkWikiDiagnostic(operation: operation, code: .sourceIndexFailed, problem: "Source indexing failed", cause: error.message, suggestedActions: ["rebuild the evidence index from the markdown or PDF source root", "provide a markdown/PDF sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace for import"])
        case .archiveImportFailed:
            return ASKWorkWikiDiagnostic(operation: operation, code: .archiveImportFailed, problem: "Archive import failed", cause: error.message, suggestedActions: ["verify archiveURL exists and is readable", "run the storage health read path for the vault"])
        case .archiveExportFailed:
            return ASKWorkWikiDiagnostic(operation: operation, code: .archiveExportFailed, problem: "Archive export failed", cause: error.message, suggestedActions: ["create the archive output parent directory before exporting", "run the storage health read path for the vault"])
        case .benchmarkRegressionFailed:
            return ASKWorkWikiDiagnostic(operation: operation, code: .benchmarkRegressionFailed, problem: "Benchmark regression threshold failed", cause: error.message, suggestedActions: ["run the large-workspace benchmark in the developer harness and compare it with the baseline"])
        case .pendingPatchNotFound:
            return ASKWorkWikiDiagnostic(operation: operation, code: .pendingPatchNotFound, problem: "Pending patch not found", cause: error.message, suggestedActions: ["run the storage health read path for the vault", "stage a new report after confirming vault and index paths"])
        case .unsupportedPatch:
            return ASKWorkWikiDiagnostic(operation: operation, code: .unsupportedPatch, problem: "Unsupported work-wiki patch", cause: error.message, suggestedActions: ["run the storage health read path for the vault"])
        case .invalidRequest:
            return ASKWorkWikiDiagnostic(operation: operation, code: .invalidArgument, problem: "Invalid request", cause: error.message, suggestedActions: suggestedActions(for: operation, missingFlag: nil))
        }
    }

    private static func askErrorDiagnostic(operation: String?, error: ASKError) -> ASKWorkWikiDiagnostic {
        switch error {
        case .validation(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .invalidArgument, problem: "Invalid argument", cause: message, suggestedActions: suggestedActions(for: operation, missingFlag: nil))
        case .notFound(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .resourceNotFound, problem: "Resource not found", cause: message, suggestedActions: suggestedActions(for: operation, missingFlag: nil))
        case .apply(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .applyFailed, problem: "Apply failed", cause: message, suggestedActions: suggestedActions(for: operation, missingFlag: nil))
        case .journalConflict(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .journalConflict, problem: "Journal conflict", cause: message, suggestedActions: ["run the storage health read path for the vault"])
        case .database(let message), .unimplemented(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .operationFailed, problem: "Operation failed", cause: message, suggestedActions: suggestedActions(for: operation, missingFlag: nil))
        case .importIntegrity(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .archiveImportFailed, problem: "Archive integrity check failed", cause: message, suggestedActions: ["verify archiveURL exists and is readable", "run the storage health read path for the vault"])
        case .platformUnavailable(let message):
            return ASKWorkWikiDiagnostic(operation: operation, code: .operationFailed, problem: "Platform unavailable", cause: message, suggestedActions: ["run this operation on macOS, where the archive adapter is available"])
        }
    }

    private static func missingVaultDiagnostic(operation: String?) -> ASKWorkWikiDiagnostic {
        ASKWorkWikiDiagnostic(operation: operation, code: .missingVaultPath, problem: "Missing vault path", cause: "The host operation requires --vault, but it was not provided.", suggestedActions: ["run quickStart with resetExistingWorkspace to create a fresh sample workspace", "provide vaultURL before running \(operation ?? "the operation")"])
    }

    private static func suggestedActions(for operation: String?, missingFlag: String?) -> [String] {
        switch operation {
        case "index": return ["provide sourceRootURL and indexURL before rebuilding the evidence index"]
        case "search": return ["read evidenceSearch with indexURL and queryText"]
        case "freshness": return ["inspect evidence freshness using the configured indexURL"]
        case "capture": return ["stage capture with captureManifestURL, domain, and requestedAt"]
        case "report": return ["stage report with vaultURL, title, queryText, and requestedAt"]
        case "close-day": return ["stage closeDay with vaultURL, date, queryText, and requestedAt"]
        case "doctor": return ["run the storage health read path for the vault"]
        case "storage-health": return ["read storageHealth for the configured vaultURL", "repair or rebuild stale search storage before retrying"]
        case "repair-storage": return ["read storageHealth for the configured vaultURL"]
        case "approve": return ["approve report with patchID, decidedBy, decidedAt, and reason"]
        case "reject": return ["reject report with patchID, decidedBy, decidedAt, and reason"]
        case "quick-start": return ["run quickStart with resetExistingWorkspace to create a fresh sample workspace"]
        case "from-existing-workspace": return ["provide a markdown/PDF sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace for import"]
        case "benchmark-large-workspace": return ["run the large-workspace benchmark with generated documents", "run the benchmark smoke pass with a stored baseline"]
        default:
            if let missingFlag { return ["choose a supported ASKCommand and create a plan before applying it # required: \(missingFlag)"] }
            return ["choose a supported ASKCommand and create a plan before applying it"]
        }
    }

    private static func workspaceResetActions(for operation: String?) -> [String] {
        switch operation {
        case "quick-start": return ["run quickStart with resetExistingWorkspace for the selected workspace"]
        case "from-existing-workspace": return ["provide sourceRootURL, workspaceURL, title, queryText, and resetExistingWorkspace for import"]
        case "benchmark-large-workspace": return ["run the large-workspace benchmark with generated documents", "run the benchmark smoke pass with a stored baseline"]
        default: return suggestedActions(for: operation, missingFlag: nil)
        }
    }
}

public struct ASKWorkWikiDiagnosticResponse: Codable, Sendable {
    public var ok: Bool
    public var operation: String
    public var patchID: String?
    public var sourceID: String?
    public var importedRawPath: String?
    public var evidenceHitCount: Int?
    public var evidenceTruncated: Bool?
    public var projectionSlug: String?
    public var summary: ASKWorkWikiCloseDaySummary?
    public var findingCount: Int?
    public var findings: [ASKWorkWikiDoctorFinding]?
    public var applyDecision: String?
    public var remainingPendingPatchIDs: [String]?
    public var sourceStatuses: [ASKWorkWikiReportApprovalSourceStatus]?
    public var indexedCount: Int?
    public var skippedCount: Int?
    public var skippedPaths: [String]?
    public var skippedSources: [ASKWorkWikiSkippedSource]?
    public var indexedSourceIDs: [SourceID]?
    public var indexedPaths: [String]?
    public var documentCount: Int?
    public var documents: [ASKEvidenceMetadata]?
    public var evidenceHits: [ASKEvidenceHit]?
    public var freshnessCount: Int?
    public var freshnessStatuses: [ASKEvidenceDocumentStatus]?
    public var storageHealthy: Bool?
    public var storageComponents: [String]?
    public var suggestedActions: [String]?

    public init(ok: Bool, operation: String, patchID: String? = nil, sourceID: String? = nil, importedRawPath: String? = nil, evidenceHitCount: Int? = nil, evidenceTruncated: Bool? = nil, projectionSlug: String? = nil, summary: ASKWorkWikiCloseDaySummary? = nil, findingCount: Int? = nil, findings: [ASKWorkWikiDoctorFinding]? = nil, applyDecision: String? = nil, remainingPendingPatchIDs: [String]? = nil, sourceStatuses: [ASKWorkWikiReportApprovalSourceStatus]? = nil, indexedCount: Int? = nil, skippedCount: Int? = nil, skippedPaths: [String]? = nil, skippedSources: [ASKWorkWikiSkippedSource]? = nil, indexedSourceIDs: [SourceID]? = nil, indexedPaths: [String]? = nil, documentCount: Int? = nil, documents: [ASKEvidenceMetadata]? = nil, evidenceHits: [ASKEvidenceHit]? = nil, freshnessCount: Int? = nil, freshnessStatuses: [ASKEvidenceDocumentStatus]? = nil, storageHealthy: Bool? = nil, storageComponents: [String]? = nil, suggestedActions: [String]? = nil) {
        self.ok = ok
        self.operation = operation
        self.patchID = patchID
        self.sourceID = sourceID
        self.importedRawPath = importedRawPath
        self.evidenceHitCount = evidenceHitCount
        self.evidenceTruncated = evidenceTruncated
        self.projectionSlug = projectionSlug
        self.summary = summary
        self.findingCount = findingCount
        self.findings = findings
        self.applyDecision = applyDecision
        self.remainingPendingPatchIDs = remainingPendingPatchIDs
        self.sourceStatuses = sourceStatuses
        self.indexedCount = indexedCount
        self.skippedCount = skippedCount
        self.skippedPaths = skippedPaths
        self.skippedSources = skippedSources
        self.indexedSourceIDs = indexedSourceIDs
        self.indexedPaths = indexedPaths
        self.documentCount = documentCount
        self.documents = documents
        self.evidenceHits = evidenceHits
        self.freshnessCount = freshnessCount
        self.freshnessStatuses = freshnessStatuses
        self.storageHealthy = storageHealthy
        self.storageComponents = storageComponents
        self.suggestedActions = suggestedActions
    }
}

public enum ASKWorkWikiDiagnosticRenderer {
    public static func render(_ response: ASKWorkWikiDiagnosticResponse) -> String {
        var lines: [String] = ["workwiki \(response.operation): ok"]
        switch response.operation {
        case "index":
            lines.append("Indexed: \(response.indexedCount ?? 0)")
            lines.append("Skipped: \(response.skippedCount ?? 0)")
            appendList(response.indexedPaths, title: "Indexed paths", to: &lines, limit: 5)
            appendSkippedSources(response.skippedSources, fallbackPaths: response.skippedPaths, to: &lines, limit: 5)
        case "list-docs":
            lines.append("Documents: \(response.documentCount ?? 0)")
            let items = response.documents?.prefix(5).map {
                "\($0.sourceID.rawValue) — \($0.documentTitle) — \($0.sourcePath ?? $0.sourceID.rawValue)"
            } ?? []
            appendList(Array(items), title: "First documents", to: &lines, limit: 5)
        case "search":
            lines.append("Evidence hits: \(response.evidenceHitCount ?? 0)")
            let items = response.evidenceHits?.prefix(5).map { "\($0.sourceID.rawValue) — \($0.title)" } ?? []
            appendList(Array(items), title: "Top hits", to: &lines, limit: 5)
        case "freshness":
            lines.append("Freshness statuses: \(response.freshnessCount ?? 0)")
            let items = response.freshnessStatuses?.prefix(8).map {
                "\($0.freshness.rawValue): \($0.sourcePath ?? $0.sourceID.rawValue)"
            } ?? []
            appendList(Array(items), title: "Statuses", to: &lines, limit: 8)
        case "storage-health", "repair-storage":
            if let storageHealthy = response.storageHealthy { lines.append("Storage healthy: \(storageHealthy)") }
            appendList(response.storageComponents, title: "Storage components", to: &lines, limit: 8)
            appendList(response.suggestedActions, title: "Next", to: &lines, limit: 4)
        case "capture":
            appendValue(response.patchID, title: "Patch ID", to: &lines)
            appendValue(response.sourceID, title: "Source ID", to: &lines)
            appendValue(response.importedRawPath, title: "Imported raw path", to: &lines)
            appendList(response.suggestedActions, title: "Next", to: &lines, limit: 4)
        case "report", "close-day":
            lines.append("Status: staged")
            appendValue(response.patchID, title: "Patch ID", to: &lines)
            appendValue(response.projectionSlug, title: "Projection slug", to: &lines)
            lines.append("Evidence hits: \(response.evidenceHitCount ?? 0)")
            if response.evidenceTruncated == true { lines.append("Evidence: truncated") }
            appendList(response.suggestedActions, title: "Next", to: &lines, limit: 4)
        case "doctor":
            lines.append("Findings: \(response.findingCount ?? 0)")
            let items = response.findings?.prefix(8).map { "\($0.severity): \($0.kind) (\($0.count))" } ?? []
            appendList(Array(items), title: "Findings", to: &lines, limit: 8)
            appendList(response.suggestedActions, title: "Next", to: &lines, limit: 6)
        case "approve", "reject":
            appendValue(response.patchID, title: "Patch ID", to: &lines)
            appendValue(response.applyDecision, title: "Decision", to: &lines)
            lines.append("Remaining pending patches: \(response.remainingPendingPatchIDs?.count ?? 0)")
            appendList(response.suggestedActions, title: "Next", to: &lines, limit: 4)
        default:
            appendValue(response.patchID, title: "Patch ID", to: &lines)
            appendList(response.suggestedActions, title: "Next", to: &lines, limit: 4)
        }
        return lines.joined(separator: "\n")
    }

    public static func render(_ result: ASKWorkWikiQuickStartResult) -> String {
        var lines = [
            "workwiki quick-start: applied",
            "Workspace: \(result.workspacePath)",
            "Source: \(result.sourcePath)",
            "Indexed evidence: \(result.indexedCount)",
            "Evidence hits: \(result.evidenceHitCount)",
            "Patch ID: \(result.patchID)",
            "Projection slug: \(result.projectionSlug)",
        ]
        if let path = result.publishedProjectionPath { lines.append("Published projection: \(path)") }
        lines.append("Preview:")
        lines.append(indent(result.publishedProjectionPreview, by: "  "))
        appendList(result.followUpActions, title: "Next", to: &lines, limit: 6)
        return lines.joined(separator: "\n")
    }

    public static func render(_ result: ASKWorkWikiFromExistingWorkspaceResult) -> String {
        var lines = [
            "workwiki from-existing-workspace: applied",
            "Workspace: \(result.workspacePath)",
            "Source root: \(result.sourceRootPath)",
            "Indexed evidence: \(result.indexedCount)",
            "Skipped: \(result.skippedCount)",
            "Evidence hits: \(result.evidenceHitCount)",
            "Patch ID: \(result.patchID)",
            "Projection slug: \(result.projectionSlug)",
        ]
        if let path = result.publishedProjectionPath { lines.append("Published projection: \(path)") }
        appendList(result.indexedPaths, title: "Indexed paths", to: &lines, limit: 5)
        appendSkippedSources(result.skippedSources, fallbackPaths: nil, to: &lines, limit: 5)
        lines.append("Preview:")
        lines.append(indent(result.publishedProjectionPreview, by: "  "))
        appendList(result.followUpActions, title: "Next", to: &lines, limit: 6)
        return lines.joined(separator: "\n")
    }

    public static func render(_ diagnostic: ASKWorkWikiDiagnostic) -> String {
        var lines = ["workwiki diagnostic"]
        if let operation = diagnostic.operation { lines.append("Operation: \(operation)") }
        lines.append("Code: \(diagnostic.code.rawValue)")
        lines.append("Problem: \(diagnostic.problem)")
        lines.append("Cause: \(diagnostic.cause)")
        appendList(diagnostic.suggestedActions, title: "Next", to: &lines, limit: 6)
        return lines.joined(separator: "\n")
    }

    private static func appendValue(_ value: String?, title: String, to lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        lines.append("\(title): \(value)")
    }

    private static func appendList(_ values: [String]?, title: String, to lines: inout [String], limit: Int) {
        guard let values, !values.isEmpty else { return }
        lines.append("\(title):")
        for value in values.prefix(limit) {
            lines.append("  - \(value)")
        }
        let hidden = values.count - min(values.count, limit)
        if hidden > 0 {
            lines.append("  - … +\(hidden) more")
        }
    }

    private static func appendSkippedSources(
        _ skippedSources: [ASKWorkWikiSkippedSource]?,
        fallbackPaths: [String]?,
        to lines: inout [String],
        limit: Int
    ) {
        if let skippedSources, !skippedSources.isEmpty {
            appendList(
                skippedSources.map { "\($0.path) — \($0.reason)" },
                title: "Skipped sources",
                to: &lines,
                limit: limit
            )
            return
        }
        appendList(fallbackPaths, title: "Skipped paths", to: &lines, limit: limit)
    }

    private static func indent(_ value: String, by prefix: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : prefix + $0 }
            .joined(separator: "\n")
    }
}
