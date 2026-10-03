import KnowledgeRuntime
import Foundation

struct ASKKnowledgeProposalBuilder: Sendable {
    let maintainer: any ASKKnowledgeMaintainer

    func buildProposal(for candidate: TutorInsightCandidate) throws -> TutorInsightProposal {
        let targetProjectionSlug = candidate.preferredProjectionSlug ?? fallbackProjectionSlug(for: candidate)
        let existing = try maintainer.projectionDocument(slug: targetProjectionSlug)
        let write = try projectionWrite(
            for: candidate,
            targetProjectionSlug: targetProjectionSlug,
            existing: existing
        )
        let request = RefreshProjectionRequest(
            version: refreshProjectionRequestVersion,
            requestedAt: candidate.createdAt,
            trigger: "tutor_insight/\(candidate.candidateID)",
            proposedWrites: [write]
        )
        let outcome = try maintainer.planProjectionRefresh(request)
        return TutorInsightProposal(
            candidate: candidate,
            targetProjectionSlug: targetProjectionSlug,
            patch: outcome.patch
        )
    }

    private func projectionWrite(
        for candidate: TutorInsightCandidate,
        targetProjectionSlug: String,
        existing: ProjectionDocument?
    ) throws -> ProjectionWrite {
        if let existing {
            return ProjectionWrite(
                slug: targetProjectionSlug,
                state: .accepted,
                document: updatedProjectionDocument(existing, with: candidate)
            )
        }

        return ProjectionWrite(
            slug: targetProjectionSlug,
            state: .accepted,
            document: newProjectionDocument(for: candidate, targetProjectionSlug: targetProjectionSlug)
        )
    }

    private func updatedProjectionDocument(
        _ existing: ProjectionDocument,
        with candidate: TutorInsightCandidate
    ) -> ProjectionDocument {
        let metadata = ProjectionMetadata(
            projectionKind: existing.metadata.projectionKind,
            projectionSpace: existing.metadata.projectionSpace,
            subjectKind: existing.metadata.subjectKind,
            subjectID: existing.metadata.subjectID,
            authorityIDs: existing.metadata.authorityIDs,
            sourceIDs: TutorInsightCaptureResolver.uniqueStrings(existing.metadata.sourceIDs + candidate.sourceIDs),
            claimIDs: existing.metadata.claimIDs,
            historical: existing.metadata.historical,
            approvalRequired: existing.metadata.approvalRequired
        )
        var updated = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: existing.slug,
            title: existing.title,
            bodyMD: mergedBody(existingBody: existing.bodyMD, candidate: candidate),
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: candidate.createdAt
        )
        updated.generatedFromHash = projectionDocumentHash(updated)
        return updated
    }

    private func newProjectionDocument(
        for candidate: TutorInsightCandidate,
        targetProjectionSlug: String
    ) -> ProjectionDocument {
        let subject = projectionSubject(for: candidate)
        let metadata = ProjectionMetadata(
            projectionKind: .queryArtifact,
            projectionSpace: .wiki,
            subjectKind: subject.kind,
            subjectID: subject.id,
            authorityIDs: [],
            sourceIDs: candidate.sourceIDs,
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: targetProjectionSlug,
            title: candidate.title,
            bodyMD: initialBody(for: candidate),
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: candidate.createdAt
        )
        document.generatedFromHash = projectionDocumentHash(document)
        return document
    }

    private func projectionSubject(for candidate: TutorInsightCandidate) -> (kind: String, id: String) {
        if let sessionID = candidate.sessionID {
            return (kind: "tutor_session", id: sessionID)
        }
        return (kind: "learner", id: candidate.learnerID)
    }

    private func initialBody(for candidate: TutorInsightCandidate) -> String {
        [
            "<!-- tutor-insight:\(candidate.candidateID) -->",
            candidate.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
            ""
        ].joined(separator: "\n\n")
    }

    private func mergedBody(existingBody: String, candidate: TutorInsightCandidate) -> String {
        let anchor = "<!-- tutor-insight:\(candidate.candidateID) -->"
        if existingBody.contains(anchor) {
            return existingBody
        }
        let trimmed = existingBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let addition = [anchor, candidate.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n\n")
        guard !trimmed.isEmpty else {
            return addition + "\n"
        }
        return [trimmed, addition, ""].joined(separator: "\n\n")
    }

    private func fallbackProjectionSlug(for candidate: TutorInsightCandidate) -> String {
        let owner = candidate.sessionID ?? candidate.learnerID
        return "queries/tutor-insights/\(owner)/\(candidate.candidateID)"
    }

}
