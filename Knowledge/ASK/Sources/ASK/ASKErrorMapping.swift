import Foundation
import ASKApplication
import KnowledgeCore
import WorkWiki
import PageIndex

func mapASKDiagnostic(_ error: Error, operation: ASKOperation) -> ASKDiagnostic {
    if let diagnostic = error as? ASKDiagnostic {
        if diagnostic.operation == operation { return diagnostic }
        return ASKDiagnostic(
            code: diagnostic.code,
            operation: operation,
            message: diagnostic.message,
            context: diagnostic.context,
            recovery: diagnostic.recovery
        )
    }
    if let applicationError = error as? ASKApplicationError {
        switch applicationError {
        case .missingEvidenceIndexPath:
            return ASKDiagnostic(
                code: .missingField,
                operation: operation,
                message: "The evidence index path is required for this operation",
                context: ["field": "evidenceIndexURL"],
                recovery: .correctInput
            )
        case .mutationInProgress(let actionID):
            return ASKDiagnostic(
                code: .conflict,
                operation: operation,
                message: "Another mutation is already active for this workspace",
                context: ["activeActionID": actionID],
                recovery: .retry
            )
        case .invalidMutationTransition:
            return ASKDiagnostic(
                code: .integrityViolation,
                operation: operation,
                message: "The application mutation lane rejected an impossible state transition",
                recovery: .inspectStorage
            )
        }
    }
    if let domain = error as? KnowledgeCore.ASKError {
        let code: ASKErrorCode
        let recovery: ASKRecoveryAction
        let message: String
        switch domain {
        case .validation(let value):
            (code, recovery, message) = (.invalidRequest, .correctInput, value)
        case .notFound(let value):
            (code, recovery, message) = (.notFound, .correctInput, value)
        case .journalConflict(let value):
            (code, recovery, message) = (.conflict, .inspectStorage, value)
        case .importIntegrity(let value):
            (code, recovery, message) = (.integrityViolation, .inspectStorage, value)
        case .database(let value), .apply(let value):
            (code, recovery, message) = (.storageFailure, .inspectStorage, value)
        case .platformUnavailable(let value), .unimplemented(let value):
            (code, recovery, message) = (.unsupported, .none, value)
        }
        return ASKDiagnostic(code: code, operation: operation, message: message, recovery: recovery)
    }
    if let workflow = error as? ASKWorkWikiError {
        let code: ASKErrorCode
        let recovery: ASKRecoveryAction
        switch workflow.code {
        case .invalidRequest, .sourceWorkspaceOverlap, .noIndexableSources, .evidenceBudgetTooSmall:
            (code, recovery) = (.invalidRequest, .correctInput)
        case .missingVaultPath:
            (code, recovery) = (.missingField, .correctInput)
        case .sourcePathNotFound, .pendingPatchNotFound:
            (code, recovery) = (.notFound, .correctInput)
        case .workspaceAlreadyExists, .noFreshEvidence, .freshnessCheckFailed, .staleIndexedEvidence:
            (code, recovery) = (.conflict, .correctInput)
        case .unsupportedPatch:
            (code, recovery) = (.unsupported, .none)
        case .benchmarkRegressionFailed:
            (code, recovery) = (.integrityViolation, .inspectStorage)
        case .sourceIndexFailed, .archiveImportFailed, .archiveExportFailed:
            (code, recovery) = (.storageFailure, .inspectStorage)
        }
        var context = workflow.context
        context["causeCode"] = workflow.code.rawValue
        return ASKDiagnostic(code: code, operation: operation, message: workflow.message,
            context: context, recovery: recovery)
    }
    if let index = error as? ASKPageIndexError {
        let code: ASKErrorCode
        let recovery: ASKRecoveryAction
        switch index {
        case .fileNotFound, .unresolvedSourceAnchor:
            (code, recovery) = (.notFound, .correctInput)
        case .unsupportedFileFormat, .dependencyUnavailable, .unsupportedOperation, .ocrRequired:
            (code, recovery) = (.unsupported, .none)
        case .processFailure, .decodeFailure:
            (code, recovery) = (.storageFailure, .inspectStorage)
        case .unknownConfigKeys, .invalidArguments, .invalidPagesFormat, .invalidSourceRange:
            (code, recovery) = (.invalidRequest, .correctInput)
        }
        return ASKDiagnostic(code: code, operation: operation,
            message: index.errorDescription ?? String(describing: index), recovery: recovery)
    }
    // Unknown failures do not prove that no effects happened. Never tell an
    // agent to replay a mutation simply because it did not receive a receipt.
    let isMutation = operation == .apply || operation == .repair
    return ASKDiagnostic(
        code: .underlying,
        operation: operation,
        message: error is CancellationError ? "Operation was cancelled" : String(describing: error),
        context: error is CancellationError ? ["reason": "cancelled"] : [:],
        recovery: isMutation ? .inspectOperation : (error is CancellationError ? .none : .retry)
    )
}
