import Foundation
import NativeAgentDomain

public struct DeterministicMobilePromptCandidateGenerator: EvolutionCandidateGenerator {
    public init() {}

    public func generateCandidates(
        source: EvolutionArtifact,
        dataset: EvolutionDataset,
        config: EvolutionConfig
    ) async throws -> [EvolutionCandidate] {
        let base = source.content.trimmedForNativeAgentEvolution
        guard !base.isEmpty else { throw EvolutionError.emptySource }
        let limit = config.maxCandidates
        var candidates: [EvolutionCandidate] = []

        let mobileGuardrails = """

        Mobile execution guardrails:
        - Use only tools exposed by the host app.
        - Ask for explicit approval before mutating files, contacts, calendars, app state, or external services.
        - Treat approval, signal, and time waits as normal resumable states.
        - Keep changes small, reversible, and supported by evidence.
        """
        candidates.append(
            EvolutionCandidate(
                id: "mobile-guardrails",
                title: "Add mobile execution guardrails",
                content: appendBlock(mobileGuardrails, to: base),
                rationale: "Ports ASA's safety/approval emphasis to NativeAgent's mobile host-owned surface.",
                metadata: ["generator": .string("deterministic-mobile")]
            )
        )

        if candidates.count < limit {
            let goalStatus = """

            Goal loop response contract:
            End goal-oriented work with:
            GOAL_EVIDENCE:
            - <specific evidence checked>
            GOAL_STATUS: <complete|continue|blocked>
            GOAL_REASON: <short reason>
            """
            candidates.append(
                EvolutionCandidate(
                    id: "goal-status-contract",
                    title: "Require goal status evidence footer",
                    content: appendBlock(goalStatus, to: base),
                    rationale: "Ports ASA /goal evaluator contract into NativeAgent prompts.",
                    metadata: ["generator": .string("deterministic-mobile")]
                )
            )
        }

        if candidates.count < limit {
            let selfReview = """

            Self-review discipline:
            Before declaring completion, check whether the answer is supported by artifacts, tool results, or host-visible state. If not, continue or report the blocker.
            """
            candidates.append(
                EvolutionCandidate(
                    id: "evidence-self-review",
                    title: "Add evidence-backed self-review",
                    content: appendBlock(selfReview, to: base),
                    rationale: "Ports ASA's evaluator-gated completion discipline without desktop-only assumptions.",
                    metadata: ["generator": .string("deterministic-mobile")]
                )
            )
        }

        return Array(candidates.prefix(limit))
    }

    private func appendBlock(_ block: String, to base: String) -> String {
        if base.localizedCaseInsensitiveContains(block.trimmedForNativeAgentEvolution.components(separatedBy: .newlines).first ?? "") {
            return base
        }
        return base + block
    }
}
