import Foundation
import KnowledgeCore

package enum PatchLifecycleState: String, Codable, Sendable, Equatable {
    case pending
    case applied
    case rejected
}

/// What the replayed state needs to know about a patch plan.
///
/// The plan bodies stay in the journal, where the pending-patch API already
/// reads them from: keeping every full plan in the store meant every replay and
/// every cached snapshot carried the whole journal a second time.
package struct PatchPlanSummary: Codable, Sendable, Equatable {
    package var patchID: String
    package var version: String
    package var patchKind: PatchKind
    package var generatedAt: String
    package var verification: VerificationReport
    package var reviewIDs: [String]

    package init(_ plan: KnowledgePatchPlan) {
        self.patchID = plan.patchID
        self.version = plan.version
        self.patchKind = plan.patchKind
        self.generatedAt = plan.generatedAt
        self.verification = plan.verification
        self.reviewIDs = plan.reviewItems.map(\.reviewID)
    }
}

package struct PatchPlanRow: Codable, Sendable, Equatable {
    package var summary: PatchPlanSummary
    package var status: PatchLifecycleState

    package init(summary: PatchPlanSummary, status: PatchLifecycleState) {
        self.summary = summary
        self.status = status
    }
}

package struct KnowledgeStore: Sendable, Equatable {
    package private(set) var schemaApplied: Bool = false
    package private(set) var patchPlans: [String: PatchPlanRow] = [:]
    package private(set) var sources: [String: SourceReceipt] = [:]
    package private(set) var sourceFragments: [String: SourceFragment] = [:]
    package private(set) var authorityRecords: [String: AuthorityRecord] = [:]
    package private(set) var projectionInvalidations: [String: ProjectionInvalidation] = [:]
    package private(set) var projections: [String: [ProjectionWrite]] = [:]
    package private(set) var claims: [String: ClaimRecord] = [:]
    package private(set) var evidence: [String: EvidenceRecord] = [:]
    package private(set) var claimEvidence: [ClaimEvidence] = []
    package private(set) var reviewItems: [String: ReviewItem] = [:]
    package private(set) var operationLogs: [String: OperationLogEntry] = [:]
    package private(set) var searchDocs: [String: SearchDocRow] = [:]

    package init() {}

    package static func openInMemory() -> KnowledgeStore {
        var store = KnowledgeStore()
        store.applySchema()
        return store
    }

    package func iterSearchDocs() -> [SearchDocRow] {
        searchDocs.values.sorted { $0.docID < $1.docID }
    }

    package func visibleProjectionWrites() -> [ProjectionWrite] {
        projections.keys.sorted().compactMap { slug in
            guard let writes = projections[slug], let latest = writes.last else { return nil }
            if latest.state == .stale || latest.state == .superseded { return nil }
            return latest
        }
    }

    package func projectionStates(slug: String) -> [ProjectionState] {
        projections[slug]?.map(\.state) ?? []
    }

    package func patchStatus(_ patchID: String) -> PatchLifecycleState? {
        patchPlans[patchID]?.status
    }

    package func pendingReviewCount(_ patchID: String) -> Int? {
        guard let row = patchPlans[patchID] else { return nil }
        return row.summary.reviewIDs.filter { reviewID in
            reviewItems[reviewID]?.status == .pending
        }.count
    }

    package func searchDocCount() -> Int {
        searchDocs.count
    }

    package func searchDoc(_ docID: String) -> SearchDocRow? {
        searchDocs[docID]
    }

    package mutating func putOperationLog(_ entry: OperationLogEntry) throws {
        if let existing = operationLogs[entry.logID], existing != entry {
            throw ASKError.journalConflict("operation log conflict for `\(entry.logID)`")
        }
        operationLogs[entry.logID] = entry
    }

    package mutating func replaceProjectionWrites(slug: String, writes: [ProjectionWrite]) {
        projections[slug] = writes
    }
}

private struct ClaimEvidenceKey: Hashable {
    let claimID: String
    let evidenceID: String
}

extension KnowledgeStore {
    package mutating func applySchema() {
        schemaApplied = true
    }

    package func requireSchema() throws {
        if !schemaApplied {
            throw ASKError.database("schema must be applied before use")
        }
    }

    package mutating func putPatchPlan(_ plan: KnowledgePatchPlan) throws {
        try requireSchema()
        try plan.validate()
        patchPlans[plan.patchID] = PatchPlanRow(
            summary: PatchPlanSummary(plan),
            status: .pending
        )
        for review in plan.reviewItems {
            reviewItems[review.reviewID] = review
        }
    }

    package func validateChoiceAlignment(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) throws {
        let choiceReviews = plan.reviewItems.filter { $0.status == .pending && $0.requiresChoice }
        if choiceReviews.isEmpty {
            if receipt.selectedOptionID != nil {
                throw ASKError.validation("selected_option_id is only allowed for choice-gated patches")
            }
            return
        }
        if receipt.selectedOptionID == nil {
            throw ASKError.validation("choice-gated patch requires selected_option_id")
        }
        let selectedChoice = try receipt.selectedOptionID.map { try PatchChoiceID(validating: $0, field: "selected_option_id") }
        if selectedChoice == .approve && receipt.decision != .approved {
            throw ASKError.validation("selected option A must align with approved receipt")
        }
        if selectedChoice == .reject && receipt.decision != .rejected {
            throw ASKError.validation("selected option B must align with rejected receipt")
        }
    }

    package mutating func applyPatchReceipt(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) throws {
        try requireSchema()
        try plan.validate()
        try receipt.validate()
        if plan.patchID != receipt.patchID {
            throw ASKError.validation("patch receipt does not match plan")
        }

        var draft = self

        if draft.patchPlans[plan.patchID] == nil {
            try draft.putPatchPlan(plan)
        } else if draft.patchPlans[plan.patchID]?.status != .pending {
            throw ASKError.validation("patch already decided: \(plan.patchID)")
        }

        try draft.validateChoiceAlignment(plan: plan, receipt: receipt)
        guard var row = draft.patchPlans[plan.patchID] else {
            throw ASKError.validation("patch plan not found after insert: \(plan.patchID)")
        }

        if receipt.decision == .approved {
            for write in plan.projectionWrites {
                guard let precondition = write.precondition else { continue }
                let current = draft.projections[write.slug]?.last
                let currentVisible = current.flatMap { value in
                    value.state == .stale || value.state == .superseded ? nil : value
                }
                switch (precondition.expectedBaseRevision, currentVisible) {
                case (nil, nil):
                    break
                case (let expected?, let current?):
                    guard current.document.generatedFromHash == expected else {
                        throw ASKError.journalConflict(
                            "projection `\(write.slug)` changed since planning; expected revision \(expected), found \(current.document.generatedFromHash)"
                        )
                    }
                case (nil, .some):
                    throw ASKError.journalConflict(
                        "projection `\(write.slug)` was created after planning"
                    )
                case (.some(let expected), nil):
                    throw ASKError.journalConflict(
                        "projection `\(write.slug)` disappeared since planning; expected revision \(expected)"
                    )
                }
            }
            for value in plan.sourceReceipts { draft.sources[value.sourceID] = value }
            for value in plan.sourceFragments { draft.sourceFragments[value.fragmentID] = value }
            for value in plan.authorityRecords { draft.authorityRecords[value.recordID] = value }
            for value in plan.projectionInvalidations { draft.projectionInvalidations[value.invalidationID] = value }
            draft.markMatchingProjectionsStale(plan.projectionInvalidations)
            for value in plan.projectionWrites { draft.projections[value.slug, default: []].append(value) }
            for value in plan.claims { draft.claims[value.claimID] = value }
            for value in plan.evidence { draft.evidence[value.evidenceID] = value }

            var existingPairs = Set(draft.claimEvidence.map { ClaimEvidenceKey(claimID: $0.claimID, evidenceID: $0.evidenceID) })
            for value in plan.claimEvidence {
                let pair = ClaimEvidenceKey(claimID: value.claimID, evidenceID: value.evidenceID)
                if existingPairs.insert(pair).inserted {
                    draft.claimEvidence.append(value)
                }
            }

            for review in plan.reviewItems {
                var approved = review
                approved.status = .approved
                draft.reviewItems[review.reviewID] = approved
            }
            for value in plan.operations { draft.operationLogs[value.logID] = value }

            let decisionLog = OperationLogEntry(
                logID: stableID(prefix: "log", parts: [plan.patchID, "decision"]),
                occurredAt: receipt.decidedAt,
                opKind: "patch_decision",
                summary: "patch \(plan.patchID) approved by \(receipt.decidedBy)" + (receipt.selectedOptionID.map { " with choice \($0)" } ?? "")
            )
            draft.operationLogs[decisionLog.logID] = decisionLog
            row.status = .applied
        } else {
            for review in plan.reviewItems {
                var rejected = review
                rejected.status = .rejected
                draft.reviewItems[review.reviewID] = rejected
            }
            let decisionLog = OperationLogEntry(
                logID: stableID(prefix: "log", parts: [plan.patchID, "decision"]),
                occurredAt: receipt.decidedAt,
                opKind: "patch_decision",
                summary: "patch \(plan.patchID) rejected by \(receipt.decidedBy)" + (receipt.selectedOptionID.map { " with choice \($0)" } ?? "")
            )
            draft.operationLogs[decisionLog.logID] = decisionLog
            row.status = .rejected
        }

        row.summary = PatchPlanSummary(plan)
        draft.patchPlans[plan.patchID] = row
        self = draft
    }

    package mutating func markMatchingProjectionsStale(_ invalidations: [ProjectionInvalidation]) {
        for invalidation in invalidations {
            guard let writes = projections[invalidation.slug] else { continue }
            projections[invalidation.slug] = writes.map { write in
                var stale = write
                stale.state = .stale
                return stale
            }
        }
    }


    package mutating func rebuildSearchIndex() throws {
        try requireSchema()
        searchDocs.removeAll()
        let docs = try buildSearchDocsFromState(
            sourceReceipts: sources.values.sorted { $0.sourceID < $1.sourceID },
            sourceFragments: sourceFragments.values.sorted {
                if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.fragmentID < $1.fragmentID
            },
            authorityRecords: authorityRecords.values.sorted { $0.recordID < $1.recordID },
            claims: claims.values.sorted { $0.claimID < $1.claimID },
            projectionWrites: visibleProjectionWrites()
        )
        for doc in docs { searchDocs[doc.docID] = doc }
    }
}
