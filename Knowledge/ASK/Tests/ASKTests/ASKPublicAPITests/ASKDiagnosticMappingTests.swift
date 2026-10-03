import Foundation
import Testing
import KnowledgeCore
import WorkWiki
import PageIndex
@testable import ASK

struct ASKDiagnosticMappingTests {
    @Test func validationAndIntegrityDoNotBecomeRetryableGenericFailures() {
        let invalid = mapASKDiagnostic(KnowledgeCore.ASKError.validation("bad source"), operation: .apply)
        #expect(invalid.code == .invalidRequest)
        #expect(invalid.recovery == .correctInput)
        let integrity = mapASKDiagnostic(KnowledgeCore.ASKError.importIntegrity("hash mismatch"), operation: .apply)
        #expect(integrity.code == .integrityViolation)
        #expect(integrity.recovery == .inspectStorage)
        let conflict = mapASKDiagnostic(KnowledgeCore.ASKError.journalConflict("revision"), operation: .apply)
        #expect(conflict.code == .conflict)
        #expect(conflict.recovery != .retry)
    }

    @Test func workflowContextAndCauseArePreserved() {
        let result = mapASKDiagnostic(ASKWorkWikiError(.staleIndexedEvidence, "stale",
            context: ["sourceID": "source-1"]), operation: .apply)
        #expect(result.code == .conflict)
        #expect(result.context["sourceID"] == "source-1")
        #expect(result.context["causeCode"] == "stale_indexed_evidence")
        #expect(result.recovery == .correctInput)
    }

    @Test func unknownMutationFailureRequiresObservationBeforeReplay() {
        struct Unexpected: Error {}
        #expect(mapASKDiagnostic(Unexpected(), operation: .apply).recovery == .inspectOperation)
        #expect(mapASKDiagnostic(Unexpected(), operation: .repair).recovery == .inspectOperation)
        #expect(mapASKDiagnostic(Unexpected(), operation: .query).recovery == .retry)
        let cancelled = mapASKDiagnostic(CancellationError(), operation: .apply)
        #expect(cancelled.context["reason"] == "cancelled")
        #expect(cancelled.recovery == .inspectOperation)
        #expect(mapASKDiagnostic(CancellationError(), operation: .query).recovery == .none)
    }

    @Test func unsupportedAndMissingRemainDistinguishable() {
        let unsupported = mapASKDiagnostic(KnowledgeCore.ASKError.platformUnavailable("platform"), operation: .apply)
        #expect(unsupported.code == .unsupported)
        #expect(unsupported.recovery == .none)
        let missing = mapASKDiagnostic(ASKWorkWikiError(.pendingPatchNotFound, "missing"), operation: .apply)
        #expect(missing.code == .notFound)
        #expect(missing.recovery == .correctInput)
    }

    @Test func interruptedIndexReadsRequireRecoveryInsteadOfBlindQueryRetry() {
        let result = mapASKDiagnostic(ASKPageIndexError.processFailure(
            command: "source index transaction", exitCode: 1, stderr: "interrupted"), operation: .query)
        #expect(result.code == .storageFailure)
        #expect(result.recovery == .inspectStorage)
    }
}
