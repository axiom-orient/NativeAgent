import Foundation

enum ArtifactNormalization {
    static func normalize(problem: ProblemPacket) -> ProblemPacket {
        ProblemPacket(
            id: normalizeOptional(problem.id),
            objective: normalizeLine(problem.objective),
            observedIssue: normalizeLine(problem.observedIssue),
            candidate: normalizeOptional(problem.candidate),
            constraints: normalizeLines(problem.constraints),
            evidence: normalizeEvidence(problem.evidence),
            primaryClass: normalizeOptional(problem.primaryClass),
            tags: normalizeLines(problem.tags),
            facets: normalizeFacets(problem.facets),
            metadata: normalizeFacets(problem.metadata)
        )
    }

    static func normalize(_ artifacts: RoundArtifacts) -> RoundArtifacts {
        RoundArtifacts(
            proposal: normalize(artifacts.proposal),
            review: normalize(artifacts.review),
            challenge: normalize(artifacts.challenge)
        )
    }

    static func normalize(_ artifact: ProposalArtifact) -> ProposalArtifact {
        ProposalArtifact(
            summary: normalizeLine(artifact.summary),
            plan: normalizeActions(artifact.plan),
            assumptions: normalizeLines(artifact.assumptions),
            evidenceRefs: normalizeLines(artifact.evidenceRefs)
        )
    }

    static func normalize(_ artifact: ReviewArtifact) -> ReviewArtifact {
        ReviewArtifact(
            summary: normalizeLine(artifact.summary),
            verdict: artifact.verdict,
            requiredActions: normalizeActions(artifact.requiredActions),
            blockers: normalizeBlockers(artifact.blockers),
            checks: normalizeChecks(artifact.checks),
            evidenceRefs: normalizeLines(artifact.evidenceRefs)
        )
    }

    static func normalize(_ artifact: ChallengeArtifact) -> ChallengeArtifact {
        ChallengeArtifact(
            summary: normalizeLine(artifact.summary),
            verdict: artifact.verdict,
            concerns: normalizeBlockers(artifact.concerns),
            requiredActions: normalizeActions(artifact.requiredActions),
            saferOption: normalizeLine(artifact.saferOption),
            evidenceRefs: normalizeLines(artifact.evidenceRefs)
        )
    }

    static func invalidReasons(for artifacts: RoundArtifacts) -> [String] {
        let proposal = artifacts.proposal
        let review = artifacts.review
        let challenge = artifacts.challenge

        var reasons: [String] = []

        if proposal.summary.isEmpty && proposal.plan.isEmpty {
            reasons.append("proposal_empty")
        }
        if review.summary.isEmpty {
            reasons.append("review_empty")
        }
        if challenge.summary.isEmpty {
            reasons.append("challenge_empty")
        }
        if review.verdict == .pass && (!review.requiredActions.isEmpty || !review.blockers.isEmpty) {
            reasons.append("review_pass_inconsistent")
        }
        if challenge.verdict == .clear && (!challenge.requiredActions.isEmpty || !challenge.concerns.isEmpty) {
            reasons.append("challenge_clear_inconsistent")
        }
        if review.verdict == .abort && review.blockers.isEmpty {
            reasons.append("review_abort_without_blocker")
        }
        if challenge.verdict == .abort && challenge.concerns.isEmpty {
            reasons.append("challenge_abort_without_concern")
        }

        return TextUtil.dedupeStable(reasons)
    }

    private static func normalizeActions(_ actions: [Action]) -> [Action] {
        TextUtil.dedupeStable(actions) { action in
            let label = normalizeLine(action.label)
            guard !label.isEmpty else { return nil }
            return Action(
                label: label,
                reason: normalizeOptional(action.reason),
                owner: normalizeOptional(action.owner),
                ref: normalizeOptional(action.ref),
                precise: action.precise
            )
        }
    }

    private static func normalizeBlockers(_ blockers: [Blocker]) -> [Blocker] {
        TextUtil.dedupeStable(blockers) { blocker in
            let label = normalizeLine(blocker.label)
            guard !label.isEmpty else { return nil }
            return Blocker(
                label: label,
                severity: normalizeOptional(blocker.severity),
                reason: normalizeOptional(blocker.reason),
                ref: normalizeOptional(blocker.ref)
            )
        }
    }

    private static func normalizeChecks(_ checks: [Check]) -> [Check] {
        TextUtil.dedupeStable(checks) { check in
            let label = normalizeLine(check.label)
            guard !label.isEmpty else { return nil }
            return Check(
                label: label,
                how: normalizeOptional(check.how),
                ref: normalizeOptional(check.ref)
            )
        }
    }

    private static func normalizeEvidence(_ evidence: [EvidenceRef]) -> [EvidenceRef] {
        TextUtil.dedupeStable(evidence) { value in
            let ref = normalizeLine(value.ref)
            guard !ref.isEmpty else { return nil }
            return EvidenceRef(
                id: normalizeOptional(value.id),
                kind: normalizeOptional(value.kind),
                ref: ref,
                note: normalizeOptional(value.note),
                check: normalizeOptional(value.check)
            )
        }
    }

    private static func normalizeLines(_ values: [String]) -> [String] {
        TextUtil.dedupeStable(values.map(normalizeLine))
    }

    private static func normalizeFacets(_ values: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawKey, rawValue) in values {
            let key = normalizeLine(rawKey)
            let value = normalizeLine(rawValue)
            guard !key.isEmpty, !value.isEmpty else { continue }
            normalized[key] = value
        }
        return normalized
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        let normalized = normalizeLine(value ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeLine(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
