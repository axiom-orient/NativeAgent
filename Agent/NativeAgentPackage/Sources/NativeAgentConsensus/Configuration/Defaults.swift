import Foundation

public struct DefaultSynthesizer: Synthesizer {
    public init() {}

    public func summarize(input: SynthesisInput) -> String {
        let decision = input.consensus.decision.rawValue.uppercased()
        let proposal = TextUtil.normalizeOptional(input.artifacts.proposal.summary) ?? ""
        let review = TextUtil.normalizeOptional(input.artifacts.review.summary) ?? ""
        let challenge = TextUtil.normalizeOptional(input.artifacts.challenge.summary) ?? ""

        switch input.consensus.decision {
        case .accept:
            if !proposal.isEmpty {
                return "\(decision): \(proposal)"
            }
        case .revise:
            let parts = [review, challenge].filter { !$0.isEmpty }
            if !parts.isEmpty {
                return "\(decision): \(parts.joined(separator: " / "))"
            }
        case .abort:
            if !review.isEmpty {
                return "\(decision): \(review)"
            }
            if !challenge.isEmpty {
                return "\(decision): \(challenge)"
            }
        }
        return decision
    }
}

public struct DefaultGate: Gate {
    public let maxRequiredSteps: Int

    public init(maxRequiredSteps: Int = 3) {
        self.maxRequiredSteps = max(1, maxRequiredSteps)
    }

    public func decide(input: GateInput) -> Consensus {
        let requiredActions = mergeActions(input.artifacts.review.requiredActions, input.artifacts.challenge.requiredActions)
        let blockers = mergeBlockers(input.artifacts.review.blockers, input.artifacts.challenge.concerns)
        let selectedPlan = input.artifacts.proposal.plan
        let saferOption = input.artifacts.challenge.saferOption

        let invalidReasons = ArtifactNormalization.invalidReasons(for: input.artifacts)
        if !invalidReasons.isEmpty {
            return consensus(
                decision: fallbackDecision(round: input.round, maxRounds: input.maxRounds),
                reasons: invalidReasons,
                requiredActions: requiredActions,
                blockers: blockers,
                checks: input.artifacts.review.checks,
                selectedPlan: selectedPlan,
                saferOption: saferOption,
                round: input.round
            )
        }

        if input.artifacts.review.verdict == .abort {
            return consensus(decision: .abort, reasons: ["verifier_abort"], requiredActions: requiredActions, blockers: blockers, checks: input.artifacts.review.checks, selectedPlan: selectedPlan, saferOption: saferOption, round: input.round)
        }

        if input.artifacts.challenge.verdict == .abort {
            return consensus(decision: .abort, reasons: ["challenger_abort"], requiredActions: requiredActions, blockers: blockers, checks: input.artifacts.review.checks, selectedPlan: selectedPlan, saferOption: saferOption, round: input.round)
        }

        if repeatedBlockers(previous: input.previous, current: blockers) && input.round >= input.maxRounds {
            return consensus(decision: .abort, reasons: ["same_blocker_repeated"], requiredActions: requiredActions, blockers: blockers, checks: input.artifacts.review.checks, selectedPlan: selectedPlan, saferOption: saferOption, round: input.round)
        }

        if input.artifacts.review.verdict == .pass && input.artifacts.challenge.verdict == .clear {
            return consensus(decision: .accept, reasons: ["verifier_pass", "challenger_clear"], requiredActions: requiredActions, blockers: blockers, checks: input.artifacts.review.checks, selectedPlan: selectedPlan, saferOption: saferOption, round: input.round)
        }

        if input.round < input.maxRounds && reviseAllowed(actions: requiredActions, blockers: blockers) {
            return consensus(decision: .revise, reasons: ["bounded_revision_available"], requiredActions: requiredActions, blockers: blockers, checks: input.artifacts.review.checks, selectedPlan: selectedPlan, saferOption: saferOption, round: input.round)
        }

        return consensus(decision: .abort, reasons: ["revision_not_viable"], requiredActions: requiredActions, blockers: blockers, checks: input.artifacts.review.checks, selectedPlan: selectedPlan, saferOption: saferOption, round: input.round)
    }

    private func consensus(
        decision: Decision,
        reasons: [String],
        requiredActions: [Action],
        blockers: [Blocker],
        checks: [Check],
        selectedPlan: [Action],
        saferOption: String,
        round: Int
    ) -> Consensus {
        Consensus(
            decision: decision,
            reasons: reasons,
            requiredActions: requiredActions,
            blockers: blockers,
            checks: checks,
            selectedPlan: selectedPlan,
            saferOption: saferOption,
            sourceRound: round
        )
    }

    private func fallbackDecision(round: Int, maxRounds: Int) -> Decision {
        round < maxRounds ? .revise : .abort
    }

    private func reviseAllowed(actions: [Action], blockers: [Blocker]) -> Bool {
        guard !actions.isEmpty, actions.count <= maxRequiredSteps else { return false }

        guard actions.allSatisfy({ !$0.label.isEmpty && $0.precise }) else { return false }
        guard !blockers.contains(where: { TextUtil.normalizeOptional($0.severity)?.lowercased() == "critical" }) else { return false }
        return true
    }

    private func repeatedBlockers(previous: Consensus?, current: [Blocker]) -> Bool {
        guard let previous, !previous.blockers.isEmpty, !current.isEmpty else { return false }

        let currentSet = Set(current.map { $0.label.lowercased() })
        let matches = previous.blockers
            .map { $0.label.lowercased() }
            .filter { currentSet.contains($0) }
            .count
        return matches == min(previous.blockers.count, current.count)
    }
}

private func mergeByLabel<T>(_ chunks: [[T]], label: KeyPath<T, String>) -> [T] {
    var seen = Set<String>()
    var output: [T] = []
    for chunk in chunks {
        for item in chunk {
            let key = item[keyPath: label].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(item)
        }
    }
    return output
}

private func mergeActions(_ chunks: [Action]...) -> [Action] {
    mergeByLabel(chunks, label: \.label)
}

private func mergeBlockers(_ chunks: [Blocker]...) -> [Blocker] {
    mergeByLabel(chunks, label: \.label)
}
