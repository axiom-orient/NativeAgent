import Foundation
import KnowledgeRuntime

enum ASKTutorASKMapper {
    static func stateSummary(_ snapshot: ASKStateSnapshot) -> TutorKnowledgeStateSummary {
        TutorKnowledgeStateSummary(
            approvedPatchCount: snapshot.approvedPatchIDs.count,
            rejectedPatchCount: snapshot.rejectedPatchIDs.count,
            pendingPatchCount: snapshot.pendingPatchIDs.count,
            authorityRecordCount: snapshot.authorityRecordCount,
            visibleProjectionCount: snapshot.visibleProjections.count,
            searchDocCount: snapshot.searchDocCount,
            fileCount: snapshot.fileCount
        )
    }

    static func projection(_ document: ProjectionDocument) -> TutorProjectionSnapshot {
        TutorProjectionSnapshot(
            slug: document.slug,
            title: document.title,
            bodyMD: document.bodyMD,
            subjectKind: document.metadata.subjectKind,
            subjectID: document.metadata.subjectID
        )
    }


    static func evidenceHits(_ hits: [SearchHitSummary]) -> [TutorEvidenceHit] {
        hits.map(TutorEvidenceHit.init)
    }

    static func grounding(_ result: QueryResult) -> TutorGrounding {
        TutorGrounding(
            question: result.question,
            answer: result.answer,
            citations: result.citations.map(TutorCitation.init),
            results: result.results.map(TutorEvidenceHit.init),
            knowledgeGap: result.fileBackPatch.map(TutorKnowledgeGap.init)
        )
    }

    static func knowledgeHealth(reviewQueue: ReviewQueueResult, lint: LintResult) -> TutorKnowledgeHealthSnapshot {
        var items = reviewQueue.items.map {
            TutorKnowledgeMaintenanceItem(kind: $0.reviewKind, summary: $0.summary)
        }
        items.append(contentsOf: lint.findings.map { finding in
            let summary = finding.items?.prefix(3).joined(separator: ", ") ?? "count=\(finding.count)"
            return TutorKnowledgeMaintenanceItem(kind: finding.kind, summary: summary)
        })
        return TutorKnowledgeHealthSnapshot(
            pendingReviewCount: reviewQueue.pendingCount,
            choiceRequiredCount: reviewQueue.choiceRequiredCount,
            lintFindingCount: lint.findingCount,
            maintenanceItems: items
        )
    }
}

extension TutorEvidenceHit {
    init(_ hit: SearchHitSummary) {
        self.init(
            docID: hit.docID,
            docKind: hit.docKind,
            title: hit.title,
            subjectKind: hit.subjectKind,
            subjectID: hit.subjectID,
            projectionSlug: hit.projectionSlug,
            score: hit.score,
            snippet: hit.snippet,
            metadata: hit.metadata
        )
    }
}

private extension TutorCitation {
    init(_ citation: QueryCitation) {
        self.init(docID: citation.docID, title: citation.title, projectionSlug: citation.projectionSlug)
    }
}

private extension TutorKnowledgeGap {
    init(_ patch: KnowledgePatchPlan) {
        self.init(
            patchID: patch.patchID,
            requiresHumanApproval: patch.verification.requiresHumanApproval,
            requiresHumanChoice: patch.verification.requiresHumanChoice,
            warnings: patch.warnings
        )
    }
}
