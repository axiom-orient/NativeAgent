import Foundation
import KnowledgeCore

package func planEvidenceIngestRequest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome {
    try request.validate()
    let patchID = stableID(
        prefix: "patch",
        parts: [
            PatchKind.evidenceIngest.rawValue,
            request.source.sourceID,
            request.source.contentHash,
            request.requestedAt,
        ]
    )
    var warnings: [String] = []
    var reviewItems: [ReviewItem] = []

    if request.fragments.isEmpty {
        warnings.append("missing_fragments")
        reviewItems.append(
            reviewItem(
                reviewKind: .missingEvidence,
                severity: .high,
                subjectKind: "source",
                subjectID: request.source.sourceID,
                summary: "evidence ingest arrived without fragments",
                createdAt: request.requestedAt,
                details: ["connector": request.source.connector]
            )
        )
    } else if request.fragments.count < 2 {
        warnings.append("low_fragment_coverage")
        reviewItems.append(
            reviewItem(
                reviewKind: .lowConfidence,
                severity: .medium,
                subjectKind: "source",
                subjectID: request.source.sourceID,
                summary: "evidence ingest has low fragment coverage",
                createdAt: request.requestedAt,
                details: ["fragment_count": String(request.fragments.count)]
            )
        )
    }

    let evidence = request.fragments.map { fragment in
        EvidenceRecord(
            evidenceID: stableID(prefix: "evidence", parts: [request.source.sourceID, fragment.fragmentID]),
            sourceID: request.source.sourceID,
            fragmentID: fragment.fragmentID,
            excerpt: firstSentence(fragment.text, maxLen: 96)
        )
    }

    let claims = extractSeedClaimsFromFragments(
        sourceID: request.source.sourceID,
        subjectKind: "source",
        subjectID: request.source.sourceID,
        fragments: request.fragments
    )

    var claimEvidence: [ClaimEvidence] = []
    for claim in claims {
        for fragmentID in claim.sourceFragmentIDs {
            claimEvidence.append(
                ClaimEvidence(
                    claimID: claim.claimID,
                    evidenceID: stableID(prefix: "evidence", parts: [request.source.sourceID, fragmentID]),
                    supportKind: .context
                )
            )
        }
    }

    var plan = KnowledgePatchPlan(
        version: knowledgePatchPlanVersion,
        patchID: patchID,
        patchKind: .evidenceIngest,
        generatedAt: request.requestedAt,
        sourceReceipts: [request.source],
        sourceFragments: request.fragments,
        authorityRecords: [],
        projectionInvalidations: [],
        projectionWrites: [],
        claims: claims,
        evidence: evidence,
        claimEvidence: claimEvidence,
        reviewItems: reviewItems,
        warnings: warnings,
        verification: emptyVerification(patchID: patchID),
        operations: [
            OperationLogEntry(
                logID: stableID(prefix: "log", parts: [patchID, "evidence_ingest"]),
                occurredAt: request.requestedAt,
                opKind: "evidence_ingest",
                summary: "ingested source \(request.source.sourceID) with \(request.fragments.count) fragments"
            )
        ]
    )
    plan.verification = try verifyPatchPlan(plan)
    try plan.validate()
    return IngestEvidenceOutcome(patch: plan)
}

package func planEvidenceIngest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome {
    try planEvidenceIngestRequest(request)
}

package func extractSeedClaimsFromFragments(
    sourceID: String,
    subjectKind: String,
    subjectID: String,
    fragments: [SourceFragment]
) -> [ClaimRecord] {
    fragments.map { fragment in
        ClaimRecord(
            claimID: stableID(prefix: "claim", parts: [sourceID, fragment.fragmentID]),
            claimKind: .extracted,
            claimMode: .nondeterministic,
            status: .provisional,
            subjectKind: subjectKind,
            subjectID: subjectID,
            text: firstSentence(fragment.text, maxLen: 96),
            authorityRecordID: nil,
            sourceFragmentIDs: [fragment.fragmentID],
            confidence: fragment.text.count > 40 ? .medium : .low
        )
    }
}

package func firstSentence(_ value: String, maxLen: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let endIndex: String.Index
    if let idx = trimmed.firstIndex(where: { ".!?\n".contains($0) }) {
        endIndex = trimmed.index(after: idx)
    } else {
        endIndex = trimmed.endIndex
    }
    var output = String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    if output.count > maxLen {
        output = String(output.prefix(maxLen)) + "…"
    }
    return output
}
