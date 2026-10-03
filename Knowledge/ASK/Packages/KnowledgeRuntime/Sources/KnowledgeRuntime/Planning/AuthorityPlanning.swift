import Foundation
import KnowledgeCore

package func planAuthorityRegistrationRequest(
    _ request: RegisterAuthorityRequest,
    existingRecords: [AuthorityRecord]
) throws -> RegisterAuthorityOutcome {
    try request.validate()
    try existingRecords.forEach { try $0.validate() }

    let patchID = stableID(
        prefix: "patch",
        parts: [
            PatchKind.authorityRegister.rawValue,
            request.record.recordID,
            request.record.effectiveFrom,
            request.requestedAt,
        ]
    )

    let sameScope = existingRecords.filter { existing in
        existing.approvalState == .approved
        && existing.factScopeTuple() == request.record.factScopeTuple()
    }
    let overlaps = sameScope.filter { authorityIntervalsOverlap($0, request.record) }

    var authorityRecords: [AuthorityRecord] = []
    var reviewItems: [ReviewItem] = []
    var warnings: [String] = []
    var invalidations: [ProjectionInvalidation] = []

    if request.record.approvalState == .approved {
        if overlaps.isEmpty {
            authorityRecords.append(request.record)
            invalidations.append(contentsOf: defaultInvalidations(record: request.record, patchID: patchID, createdAt: request.requestedAt))
        } else if overlaps.count == 1, let old = overlaps.first {
            if ASKTimestamp.isAtOrBefore(request.record.effectiveFrom, old.effectiveFrom) {
                warnings.append("authority_non_monotonic_effective_from")
                reviewItems.append(
                    reviewItem(
                        reviewKind: .invalidAuthorityInterval,
                        severity: .high,
                        subjectKind: old.subjectKind,
                        subjectID: old.subjectID,
                        summary: "approved authority start must move forward when superseding current state",
                        createdAt: request.requestedAt,
                        details: [
                            "existing_record_id": old.recordID,
                            "new_record_id": request.record.recordID,
                        ]
                    )
                )
            } else {
                var superseded = old
                superseded.approvalState = .superseded
                superseded.effectiveTo = request.record.effectiveFrom
                superseded.supersedesID = request.record.recordID
                authorityRecords.append(superseded)
                authorityRecords.append(request.record)
                invalidations.append(contentsOf: defaultInvalidations(record: request.record, patchID: patchID, createdAt: request.requestedAt))
                if request.record.valueFields != old.valueFields {
                    warnings.append("ambiguous_authority_change")
                    reviewItems.append(
                        ambiguousAuthorityChoice(
                            existingRecord: old,
                            candidateRecord: request.record,
                            createdAt: request.requestedAt
                        )
                    )
                }
            }
        } else {
            warnings.append("authority_multiple_overlap_conflict")
            reviewItems.append(
                reviewItem(
                    reviewKind: .invalidAuthorityInterval,
                    severity: .high,
                    subjectKind: request.record.subjectKind,
                    subjectID: request.record.subjectID,
                    summary: "multiple overlapping approved authority intervals block auto registration",
                    createdAt: request.requestedAt,
                    details: ["overlap_count": String(overlaps.count)]
                )
            )
        }
    } else {
        authorityRecords.append(request.record)
    }

    var plan = KnowledgePatchPlan(
        version: knowledgePatchPlanVersion,
        patchID: patchID,
        patchKind: .authorityRegister,
        generatedAt: request.requestedAt,
        sourceReceipts: [],
        sourceFragments: [],
        authorityRecords: authorityRecords,
        projectionInvalidations: invalidations,
        projectionWrites: [],
        claims: [],
        evidence: [],
        claimEvidence: [],
        reviewItems: reviewItems,
        warnings: warnings,
        verification: emptyVerification(patchID: patchID),
        operations: [
            OperationLogEntry(
                logID: stableID(prefix: "log", parts: [patchID, "authority_register"]),
                occurredAt: request.requestedAt,
                opKind: "authority_register",
                summary: "authority registration planned for \(request.record.subjectKind):\(request.record.subjectID)"
            )
        ]
    )
    plan.verification = try verifyPatchPlan(plan)
    try plan.validate()
    return RegisterAuthorityOutcome(patch: plan)
}

package func planAuthorityRegistration(
    _ request: RegisterAuthorityRequest,
    existingRecords: [AuthorityRecord]
) throws -> RegisterAuthorityOutcome {
    try planAuthorityRegistrationRequest(request, existingRecords: existingRecords)
}

package func defaultInvalidations(record: AuthorityRecord, patchID: String, createdAt: String) -> [ProjectionInvalidation] {
    let currentSlug = "current/\(record.subjectKind)/\(record.subjectID)"
    let overviewSlug = "overview/\(record.subjectKind)/\(record.subjectID)"
    return [currentSlug, overviewSlug].map { slug in
        ProjectionInvalidation(
            invalidationID: stableID(prefix: "invalidate", parts: [patchID, slug]),
            slug: slug,
            reason: "authority_changed",
            triggeredByPatchID: patchID,
            createdAt: createdAt
        )
    }
}

package func authorityIntervalsOverlap(_ lhs: AuthorityRecord, _ rhs: AuthorityRecord) -> Bool {
    let lhsEnd = lhs.effectiveTo ?? ASKTimestamp.openEndedSentinel
    let rhsEnd = rhs.effectiveTo ?? ASKTimestamp.openEndedSentinel
    return ASKTimestamp.isBefore(lhs.effectiveFrom, rhsEnd) && ASKTimestamp.isBefore(rhs.effectiveFrom, lhsEnd)
}

package func changedValueFields(existingRecord: AuthorityRecord, candidateRecord: AuthorityRecord) -> [String] {
    Array(Set(existingRecord.valueFields.keys).union(candidateRecord.valueFields.keys)).sorted().filter { key in
        existingRecord.valueFields[key] != candidateRecord.valueFields[key]
    }
}

package func authorityDeltaProfile(existingRecord: AuthorityRecord, candidateRecord: AuthorityRecord) -> (ReviewKind, String, [String]) {
    let changedFields = changedValueFields(existingRecord: existingRecord, candidateRecord: candidateRecord)
    let signatureParts = [
        existingRecord.recordType,
        candidateRecord.recordType,
        existingRecord.factScopeKey,
        candidateRecord.factScopeKey,
        existingRecord.subjectKind,
        candidateRecord.subjectKind,
    ] + changedFields
    let signature = signatureParts
        .filter { !$0.isEmpty }
        .map { $0.lowercased() }
        .joined(separator: " ")

    let compatibilityTokens = ["compat", "support", "minimum", "requirement", "platform", "xcode", "os", "ios", "macos"]
    let versionTokens = ["version", "release", "sdk", "cli", "server", "toolchain"]
    let guidanceTokens = ["practice", "guidance", "recommend", "pattern", "approach", "layout"]

    if existingRecord.recordType == "compatibility_rule" || candidateRecord.recordType == "compatibility_rule" {
        return (.ambiguousCompatibilityUpdate, "compatibility_update", changedFields)
    }
    if compatibilityTokens.contains(where: { signature.contains($0) }) {
        return (.ambiguousCompatibilityUpdate, "compatibility_update", changedFields)
    }
    if versionTokens.contains(where: { signature.contains($0) }) {
        return (.ambiguousVersionUpdate, "version_update", changedFields)
    }
    if guidanceTokens.contains(where: { signature.contains($0) }) {
        return (.ambiguousGuidanceUpdate, "guidance_update", changedFields)
    }
    return (.ambiguousAuthorityChange, "current_state_update", changedFields)
}

package func choiceSummary(for reviewKind: ReviewKind) -> String {
    switch reviewKind {
    case .ambiguousVersionUpdate:
        return "system cannot determine whether the reported version delta is a real release update or a bad scrape"
    case .ambiguousCompatibilityUpdate:
        return "system cannot determine whether the compatibility delta is a real support change or an extraction error"
    case .ambiguousGuidanceUpdate:
        return "system cannot determine whether the guidance delta is a real recommendation change or a synthesis error"
    default:
        return "system cannot determine whether the authority delta is a correction or an error"
    }
}

package func reviewItem(
    reviewKind: ReviewKind,
    severity: Severity,
    subjectKind: String,
    subjectID: String,
    summary: String,
    createdAt: String,
    details: ASKFields,
    requiresChoice: Bool = false,
    options: [ReviewOption] = []
) -> ReviewItem {
    ReviewItem(
        reviewID: stableID(prefix: "review", parts: [reviewKind.rawValue, subjectKind, subjectID, summary, createdAt]),
        reviewKind: reviewKind,
        status: .pending,
        severity: severity,
        subjectKind: subjectKind,
        subjectID: subjectID,
        summary: summary,
        createdAt: createdAt,
        details: details,
        requiresChoice: requiresChoice,
        options: options
    )
}

package func ambiguousAuthorityChoice(
    existingRecord: AuthorityRecord,
    candidateRecord: AuthorityRecord,
    createdAt: String
) -> ReviewItem {
    let (reviewKind, deltaClass, changedFields) = authorityDeltaProfile(existingRecord: existingRecord, candidateRecord: candidateRecord)
    let details: ASKFields = [
        "existing_record_id": existingRecord.recordID,
        "candidate_record_id": candidateRecord.recordID,
        "fact_scope_key": candidateRecord.factScopeKey,
        "existing_value_hash": stableHashMap(existingRecord.valueFields),
        "candidate_value_hash": stableHashMap(candidateRecord.valueFields),
        "delta_class": deltaClass,
        "changed_fields": changedFields.joined(separator: ","),
        "changed_field_count": String(changedFields.count),
    ]
    let optionA = ReviewOption(
        optionID: "A",
        label: "채택",
        summary: "새 authority를 수정으로 채택하고 현재 상태를 갱신한다",
        effect: "approve_patch",
        details: [
            "kept_record_id": candidateRecord.recordID,
            "superseded_record_id": existingRecord.recordID,
            "delta_class": deltaClass,
        ]
    )
    let optionB = ReviewOption(
        optionID: "B",
        label: "기각",
        summary: "새 authority를 오류로 보고 기존 현재 상태를 유지한다",
        effect: "reject_patch",
        details: [
            "kept_record_id": existingRecord.recordID,
            "rejected_record_id": candidateRecord.recordID,
            "delta_class": deltaClass,
        ]
    )
    return reviewItem(
        reviewKind: reviewKind,
        severity: .high,
        subjectKind: candidateRecord.subjectKind,
        subjectID: candidateRecord.subjectID,
        summary: choiceSummary(for: reviewKind),
        createdAt: createdAt,
        details: details,
        requiresChoice: true,
        options: [optionA, optionB]
    )
}
