import Foundation
import Testing
@testable import KnowledgeCore

struct ASKPathSafetyValidationTests {
    @Test
    func pathSafeIDAcceptsLowercaseHyphenUnderscore() throws {
        try requirePathSafeID("id", "ask-runtime_1")
    }

    @Test
    func authorityAndReviewContractsRejectUnsafePathBackedIdentifiers() {
        #expect(throws: ASKError.self) {
            try AuthorityRecord(
                version: "1",
                recordID: "bad/id",
                recordType: "runtime",
                subjectKind: "runtime",
                subjectID: "ask-runtime",
                factScopeKey: "runtime_state",
                approvalState: .approved,
                valueFields: ["name": "ASK Runtime"],
                effectiveFrom: "2026-04-10T00:00:00Z",
                effectiveTo: nil,
                approvedBy: "reviewer",
                supersedesID: nil
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try ReviewItem(
                reviewID: "bad/id",
                reviewKind: .lowConfidence,
                status: .pending,
                severity: .medium,
                subjectKind: "runtime",
                subjectID: "ask-runtime",
                summary: "review",
                createdAt: "2026-04-10T00:00:00Z"
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try ProjectionInvalidation(
                invalidationID: "bad/id",
                slug: "current/ask-runtime",
                reason: "stale",
                triggeredByPatchID: "patch_1234",
                createdAt: "2026-04-10T00:00:00Z"
            ).validate()
        }
    }

    @Test
    func sourceClaimEvidenceAndPatchContractsRejectUnsafePathBackedIdentifiers() {
        #expect(throws: ASKError.self) {
            try SourceReceipt(
                version: "1",
                sourceID: "bad/id",
                connector: "web",
                sourceKind: .url,
                title: "Source",
                observedAt: "2026-04-10T00:00:00Z",
                capturedAt: nil,
                canonicalURI: "https://example.com",
                contentHash: "sha256:test",
                rawRelpath: "raw/evidence/2026-04-10/source.txt",
                mimeType: "text/plain",
                language: "en",
                tags: ["demo"]
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try SourceFragment(
                version: "1",
                fragmentID: "bad/id",
                sourceID: "src_demo",
                ordinal: 0,
                locator: [:],
                text: "fragment",
                fingerprint: nil
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try ClaimRecord(
                claimID: "bad/id",
                claimKind: .extracted,
                claimMode: .nondeterministic,
                status: .supported,
                subjectKind: "runtime",
                subjectID: "ask-runtime",
                text: "claim",
                authorityRecordID: nil,
                sourceFragmentIDs: ["frag_1"],
                confidence: .medium
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try EvidenceRecord(
                evidenceID: "bad/id",
                sourceID: "src_demo",
                fragmentID: "frag_1",
                excerpt: "excerpt"
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try ClaimEvidence(
                claimID: "claim_1",
                evidenceID: "bad/id",
                supportKind: .supports
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try PatchDecisionReceipt(
                version: "1",
                patchID: "bad/id",
                decision: .approved,
                decidedBy: "reviewer",
                decidedAt: "2026-04-10T00:00:00Z",
                reason: "approve"
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try OperationLogEntry(
                logID: "bad/id",
                occurredAt: "2026-04-10T00:00:00Z",
                opKind: "query",
                summary: "logged"
            ).validate()
        }
    }

    @Test
    func representationContractsRejectUnsafePathBackedSourceIDs() {
        #expect(throws: ASKError.self) {
            try RepresentationRecord(
                sourceID: "bad/id",
                kind: .ocrText,
                sourceContentHash: "sha256:test",
                generatedAt: "2026-04-10T00:00:00Z",
                generator: "ocr.demo",
                bodyMD: "representation"
            ).validate()
        }

        #expect(throws: ASKError.self) {
            try RepresentationTrailRequest(
                sourceID: "../../escape",
                sourceContentHash: "sha256:test",
                requiredKinds: [.ocrText]
            ).validate()
        }
    }

}
