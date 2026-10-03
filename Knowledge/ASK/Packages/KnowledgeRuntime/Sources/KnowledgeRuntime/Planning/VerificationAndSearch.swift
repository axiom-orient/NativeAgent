import Foundation
import KnowledgeCore

package func verifyPatchPlan(_ plan: KnowledgePatchPlan) throws -> VerificationReport {
    let hasAuthority = !plan.authorityRecords.isEmpty
    let hasHighReviews = plan.reviewItems.contains { review in
        review.status == .pending && review.severity == .high
    }
    let choiceReviews = plan.reviewItems.filter { review in
        review.status == .pending && review.requiresChoice
    }
    let requiresChoice = !choiceReviews.isEmpty
    let hasPlaybook = plan.projectionWrites.contains {
        $0.document.metadata.projectionSpace == .playbook
    }
    let hasProjections = !plan.projectionWrites.isEmpty
    let allProjectionsSafe = hasProjections && plan.projectionWrites.allSatisfy { write in
        !write.document.metadata.historical
        && !write.document.metadata.approvalRequired
        && write.document.metadata.projectionSpace == .wiki
        && [
            ProjectionKind.currentSnapshot,
            .entityOverview,
            .sourceSummary,
        ].contains(write.document.metadata.projectionKind)
    }

    let reasons: [String]
    let riskLevel: RiskLevel
    let disposition: PublishDisposition

    if requiresChoice {
        reasons = Array(Set(choiceReviews.map { $0.reviewKind.rawValue })).sorted()
        riskLevel = .high
        disposition = .needsReview
    } else if hasAuthority {
        reasons = ["authority_change"]
        riskLevel = .high
        disposition = .needsReview
    } else if hasHighReviews {
        reasons = ["high_severity_review"]
        riskLevel = .high
        disposition = .needsReview
    } else if hasPlaybook {
        reasons = ["playbook_requires_approval"]
        riskLevel = .high
        disposition = .needsReview
    } else if hasProjections && allProjectionsSafe {
        reasons = ["safe_projection_refresh"]
        riskLevel = .low
        disposition = .autoPublish
    } else if hasProjections {
        reasons = ["narrative_projection"]
        riskLevel = .medium
        disposition = .draftOnly
    } else if !plan.reviewItems.isEmpty {
        reasons = ["pending_review"]
        riskLevel = .medium
        disposition = .needsReview
    } else {
        reasons = ["low_risk_append_only"]
        riskLevel = .low
        disposition = .autoPublish
    }

    return VerificationReport(
        patchID: plan.patchID,
        riskLevel: riskLevel,
        disposition: disposition,
        reasons: reasons,
        requiresHumanApproval: disposition == .needsReview,
        requiresHumanChoice: requiresChoice
    )
}

package func buildSearchDocsFromState(
    sourceReceipts: [SourceReceipt],
    sourceFragments: [SourceFragment],
    authorityRecords: [AuthorityRecord],
    claims: [ClaimRecord],
    projectionWrites: [ProjectionWrite]
) throws -> [SearchDocRow] {
    var docs: [SearchDocRow] = []
    let fragmentsBySourceID = Dictionary(grouping: sourceFragments, by: \.sourceID)
    let sourceByID = Dictionary(uniqueKeysWithValues: sourceReceipts.map { ($0.sourceID, $0) })
    let authorityByID = Dictionary(uniqueKeysWithValues: authorityRecords.map { ($0.recordID, $0) })
    let fragmentByID = Dictionary(uniqueKeysWithValues: sourceFragments.map { ($0.fragmentID, $0) })

    for source in sourceReceipts {
        let fragmentText = searchableSourceFragmentText(fragmentsBySourceID[source.sourceID] ?? [])
        let curatedExcerpt = source.metadata["curated_note_excerpt"] ?? ""
        let body = normalizedSearchableBody(
            source.metadata["searchable_text"]
                ?? [
                    source.title,
                    source.metadata["description"] ?? "",
                    source.metadata["canonical_url"] ?? "",
                    source.metadata["final_url"] ?? "",
                    curatedExcerpt,
                    fragmentText,
                    source.metadata["site_name"] ?? "",
                ]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        )
        docs.append(
            SearchDocRow(
                docID: stableID(prefix: "search", parts: ["source", source.sourceID]),
                docKind: "source",
                subjectKind: "source",
                subjectID: source.sourceID,
                projectionSlug: nil,
                title: source.title,
                body: body,
                metadata: [
                    "source_id": source.sourceID,
                    "connector": source.connector,
                    "source_kind": source.sourceKind.rawValue,
                    "content_hash": source.contentHash,
                    "raw_relpath": source.rawRelpath,
                    "canonical_url": source.metadata["canonical_url"] ?? "",
                    "final_url": source.metadata["final_url"] ?? "",
                    "description": source.metadata["description"] ?? "",
                    "curated_note_excerpt": curatedExcerpt,
                    "searchable_text_version": source.metadata["searchable_text_version"] ?? "",
                    "searchable_text_length": source.metadata["searchable_text_length"] ?? String(body.count),
                    "fragment_count": String((fragmentsBySourceID[source.sourceID] ?? []).count),
                    "observed_at": source.observedAt,
                    "captured_at": source.capturedAt ?? "",
                    "projection_family": ProjectionFamily.source.rawValue,
                    "is_canonical": "1",
                    "source_count": "1",
                    "link_count": "0",
                    "authority_state": AuthorityState.approved.rawValue,
                    "last_confirmed_at": source.observedAt,
                ]
            )
        )
    }

    for record in authorityRecords {
        let metadata: ASKFields = [
            "record_id": record.recordID,
            "fact_scope_key": record.factScopeKey,
            "approval_state": record.approvalState.rawValue,
            "value_hash": stableHashMap(record.valueFields),
            "authority_state": record.approvalState.rawValue,
            "last_confirmed_at": record.effectiveTo ?? record.effectiveFrom,
            "is_canonical": record.approvalState == .approved ? "1" : "0",
            "projection_family": ProjectionFamily.other.rawValue,
            "link_count": "0",
            "source_count": "0",
        ]
        docs.append(
            SearchDocRow(
                docID: stableID(prefix: "search", parts: [record.recordID]),
                docKind: "authority",
                subjectKind: record.subjectKind,
                subjectID: record.subjectID,
                projectionSlug: nil,
                title: "\(record.subjectKind) \(record.recordType)",
                body: "Authority \(record.recordID) \(record.factScopeKey) " + record.valueFields.keys.sorted().map { "\($0)=\(record.valueFields[$0] ?? "")" }.joined(separator: ", "),
                metadata: metadata
            )
        )
    }

    for claim in claims {
        let claimSourceIDs = Set(claim.sourceFragmentIDs.compactMap { fragmentByID[$0]?.sourceID })
        let authorityState = claim.authorityRecordID.flatMap { authorityByID[$0]?.approvalState.rawValue } ?? ""
        let lastConfirmedAt = maxTimestamp([
            claim.authorityRecordID.flatMap { authorityByID[$0]?.effectiveTo ?? authorityByID[$0]?.effectiveFrom },
            latestSourceTimestamp(Array(claimSourceIDs).sorted(), sourceByID: sourceByID),
        ]) ?? ""
        var metadata: ASKFields = [
            "claim_id": claim.claimID,
            "claim_mode": claim.claimMode.rawValue,
            "claim_kind": claim.claimKind.rawValue,
            "source_fragment_ids": claim.sourceFragmentIDs.joined(separator: ","),
            "source_count": String(claimSourceIDs.count),
            "link_count": "0",
            "projection_family": ProjectionFamily.other.rawValue,
            "authority_state": authorityState,
            "last_confirmed_at": lastConfirmedAt,
            "is_canonical": "0",
        ]
        if let authorityRecordID = claim.authorityRecordID {
            metadata["authority_record_id"] = authorityRecordID
        }
        docs.append(
            SearchDocRow(
                docID: stableID(prefix: "search", parts: [claim.claimID]),
                docKind: "claim",
                subjectKind: claim.subjectKind,
                subjectID: claim.subjectID,
                projectionSlug: nil,
                title: "Claim \(claim.claimID)",
                body: claim.text,
                metadata: metadata
            )
        )
    }

    for write in projectionWrites {
        let family = projectionFamily(for: write.document.metadata, slug: write.slug)
        let links = extractWikiLinkRows(from: write.document.bodyMD, fromSlug: normalizeProjectionSlugPath(write.slug), createdAt: write.document.generatedAt)
        let strongestAuthority = strongestAuthorityState(for: write.document.metadata.authorityIDs, authorityByID: authorityByID)
        let observedAt = latestSourceTimestamp(write.document.metadata.sourceIDs, sourceByID: sourceByID) ?? ""
        let lastConfirmedAt = maxTimestamp([
            observedAt.isEmpty ? nil : observedAt,
            latestAuthorityTimestamp(write.document.metadata.authorityIDs, authorityByID: authorityByID),
        ]) ?? write.document.generatedAt
        let metadata: ASKFields = [
            "projection_space": write.document.metadata.projectionSpace.rawValue,
            "projection_kind": write.document.metadata.projectionKind.rawValue,
            "projection_family": family.rawValue,
            "authority_ids": write.document.metadata.authorityIDs.joined(separator: ","),
            "source_ids": write.document.metadata.sourceIDs.joined(separator: ","),
            "claim_ids": write.document.metadata.claimIDs.joined(separator: ","),
            "generated_at": write.document.generatedAt,
            "observed_at": observedAt,
            "last_confirmed_at": lastConfirmedAt,
            "authority_state": strongestAuthority?.rawValue ?? "",
            "source_count": String(write.document.metadata.sourceIDs.count),
            "claim_count": String(write.document.metadata.claimIDs.count),
            "link_count": String(links.count),
            "historical": write.document.metadata.historical ? "1" : "0",
            "approval_required": write.document.metadata.approvalRequired ? "1" : "0",
            "is_canonical": isCanonicalProjectionFamily(family) ? "1" : "0",
        ]
        docs.append(
            SearchDocRow(
                docID: stableID(prefix: "search", parts: [write.slug, write.document.generatedFromHash]),
                docKind: "projection",
                subjectKind: write.document.metadata.subjectKind,
                subjectID: write.document.metadata.subjectID,
                projectionSlug: write.slug,
                title: write.document.title,
                body: write.document.bodyMD,
                metadata: metadata
            )
        )
    }

    docs.sort { lhs, rhs in lhs.docID < rhs.docID }
    try docs.forEach { try $0.validate() }
    return docs
}

private func searchableSourceFragmentText(_ fragments: [SourceFragment], maxFragments: Int = 6, maxLength: Int = 2400) -> String {
    let joined = fragments
        .sorted { lhs, rhs in
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            return lhs.fragmentID < rhs.fragmentID
        }
        .prefix(maxFragments)
        .map(\.text)
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard joined.count <= maxLength else { return String(joined.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
    return joined
}

private func normalizedSearchableBody(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "missing searchable text" : trimmed
}

private func strongestAuthorityState(
    for authorityIDs: [String],
    authorityByID: [String: AuthorityRecord]
) -> AuthorityState? {
    authorityIDs
        .compactMap { authorityByID[$0]?.approvalState }
        .sorted { authorityPriority($0) > authorityPriority($1) }
        .first
}

private func authorityPriority(_ state: AuthorityState) -> Int {
    switch state {
    case .approved: return 4
    case .draft: return 3
    case .superseded: return 2
    case .rejected: return 1
    }
}

private func latestSourceTimestamp(_ sourceIDs: [String], sourceByID: [String: SourceReceipt]) -> String? {
    sourceIDs.compactMap { sourceByID[$0]?.observedAt }.max()
}

private func latestAuthorityTimestamp(_ authorityIDs: [String], authorityByID: [String: AuthorityRecord]) -> String? {
    authorityIDs.compactMap { authorityID in
        guard let record = authorityByID[authorityID] else { return nil }
        return record.effectiveTo ?? record.effectiveFrom
    }.max()
}

private func maxTimestamp(_ values: [String?]) -> String? {
    values.compactMap { value in
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }.max()
}

package func emptyVerification(patchID: String) -> VerificationReport {
    VerificationReport(
        patchID: patchID,
        riskLevel: .low,
        disposition: .autoPublish,
        reasons: ["empty_patch"],
        requiresHumanApproval: false,
        requiresHumanChoice: false
    )
}
