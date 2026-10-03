import Foundation
import KnowledgeCore

public protocol DecisionMemoryTokenCounting: Sendable {
    func countTokens(in text: String) -> Int
}

/// A model-independent accounting approximation. Production hosts may replace
/// it with a tokenizer for their fixed model, but selection remains deterministic
/// because the counter is explicit input rather than an implicit model call.
public struct WhitespaceDecisionMemoryTokenCounter: DecisionMemoryTokenCounting, Sendable {
    public init() {}

    public func countTokens(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

public enum DecisionMemoryContextError: Error, Equatable, Sendable {
    case budgetUnsatisfied(recordIDs: [String], requiredTokens: Int, availableTokens: Int)
}

public struct DeterministicContextCompiler: Sendable {
    private let tokenCounter: any DecisionMemoryTokenCounting

    public init(tokenCounter: any DecisionMemoryTokenCounting = WhitespaceDecisionMemoryTokenCounter()) {
        self.tokenCounter = tokenCounter
    }

    public func compile(
        snapshot: MemoryLifecycleSnapshot,
        frame: TaskFrame,
        generation: String,
        budget: ContextBudget = ContextBudget(),
        evidenceOmissions: [OmissionDiagnostic] = []
    ) throws -> ContextBundle {
        try frame.validate()
        try budget.validate()

        let header = "# Task context\n\n- task: \(frame.taskID)\n- generation: \(generation)\n"
        let headerTokens = tokenCounter.countTokens(in: header)
        guard headerTokens <= budget.totalTokens else {
            throw DecisionMemoryContextError.budgetUnsatisfied(
                recordIDs: [],
                requiredTokens: headerTokens,
                availableTokens: budget.totalTokens
            )
        }

        let excluded = Set(evidenceOmissions.map(\.recordID))
        let candidates = makeCandidates(snapshot: snapshot, frame: frame).filter { !excluded.contains($0.state.record.recordID) }
        var remainingTotal = budget.totalTokens - headerTokens
        var selected: [Candidate] = []
        var omitted = evidenceOmissions

        let blockingLTSM = candidates.filter {
            $0.state.tier == .ltsm && $0.state.record.blocking && $0.state.verification == .verified
        }
        let mandatoryCost = blockingLTSM.reduce(0) { $0 + tokenCounter.countTokens(in: render($1)) }
        guard mandatoryCost <= budget.blockingLTSMTokens, mandatoryCost <= remainingTotal else {
            throw DecisionMemoryContextError.budgetUnsatisfied(
                recordIDs: blockingLTSM.map { $0.state.record.recordID },
                requiredTokens: mandatoryCost,
                availableTokens: min(budget.blockingLTSMTokens, remainingTotal)
            )
        }
        selected += blockingLTSM
        remainingTotal -= mandatoryCost

        let ltsmOptional = candidates.filter {
            $0.state.tier == .ltsm && !($0.state.record.blocking && $0.state.verification == .verified)
        }
        let ltsmUsed = try select(
            ltsmOptional,
            segmentCap: budget.ltsmTokens - mandatoryCost,
            remainingTotal: &remainingTotal,
            selected: &selected,
            omitted: &omitted
        )
        _ = ltsmUsed
        _ = try select(
            candidates.filter { $0.state.tier == .mtem && $0.state.verification == .verified },
            segmentCap: budget.mtemTokens,
            remainingTotal: &remainingTotal,
            selected: &selected,
            omitted: &omitted
        )
        _ = try select(
            candidates.filter { $0.state.tier == .stim && $0.state.verification == .verified },
            segmentCap: budget.stimTokens,
            remainingTotal: &remainingTotal,
            selected: &selected,
            omitted: &omitted
        )
        _ = try select(
            candidates.filter { $0.state.tier == .stim && $0.state.verification == .proposed },
            segmentCap: budget.uncertaintyTokens,
            remainingTotal: &remainingTotal,
            selected: &selected,
            omitted: &omitted
        )

        let ordered = selected.sorted(by: candidateOrder)
        let records = ordered.map(contextRecord)
        let markdown = header + ordered.map(render).joined(separator: "\n\n") + (ordered.isEmpty ? "" : "\n")
        let tokenCount = tokenCounter.countTokens(in: markdown)
        guard tokenCount <= budget.totalTokens else {
            throw DecisionMemoryContextError.budgetUnsatisfied(
                recordIDs: ordered.map { $0.state.record.recordID },
                requiredTokens: tokenCount,
                availableTokens: budget.totalTokens
            )
        }
        return ContextBundle(
            taskID: frame.taskID,
            records: records,
            markdown: markdown,
            tokenCount: tokenCount,
            omitted: omitted.sorted { lhs, rhs in
                if lhs.recordID != rhs.recordID { return lhs.recordID < rhs.recordID }
                if lhs.reason != rhs.reason { return lhs.reason.rawValue < rhs.reason.rawValue }
                if lhs.evidenceID != rhs.evidenceID { return (lhs.evidenceID ?? "") < (rhs.evidenceID ?? "") }
                return (lhs.detail ?? "") < (rhs.detail ?? "")
            },
            generation: generation
        )
    }

    /// Shared routing used before any external evidence probe or budget choice.
    public func scopedStates(snapshot: MemoryLifecycleSnapshot, frame: TaskFrame) -> [MemoryRecordState] {
        snapshot.states.compactMap { state in
            guard state.isActive else { return nil }
            guard state.record.scope.workspaceID == frame.workspaceID else { return nil }
            guard scopeMatches(state.record.scope, frame: frame) else { return nil }
            if state.tier == .stim, state.record.taskID != frame.taskID {
                return nil
            }
            return state
        }
    }

    private func makeCandidates(snapshot: MemoryLifecycleSnapshot, frame: TaskFrame) -> [Candidate] {
        scopedStates(snapshot: snapshot, frame: frame).compactMap { state in
            if state.verification == .verified,
               state.evidenceRefs.contains(where: { $0.freshness == .stale }) {
                return nil
            }
            return Candidate(state: state, specificity: specificity(of: state.record.scope))
        }.sorted(by: candidateOrder)
    }

    private func select(
        _ candidates: [Candidate],
        segmentCap: Int,
        remainingTotal: inout Int,
        selected: inout [Candidate],
        omitted: inout [OmissionDiagnostic]
    ) throws -> Int {
        var used = 0
        for candidate in candidates.sorted(by: candidateOrder) {
            let cost = tokenCounter.countTokens(in: render(candidate))
            if used + cost <= segmentCap, cost <= remainingTotal {
                selected.append(candidate)
                used += cost
                remainingTotal -= cost
            } else {
                omitted.append(OmissionDiagnostic(recordID: candidate.state.record.recordID, reason: .budget))
            }
        }
        return used
    }

    private func scopeMatches(_ scope: MemoryScope, frame: TaskFrame) -> Bool {
        intersectsOrUnrestricted(scope.projectIDs, frame.projectIDs)
            && pathsMatchOrUnrestricted(scope.pathPrefixes, frame.paths)
            && intersectsOrUnrestricted(scope.capabilityTags, frame.capabilityTags)
            && intersectsOrUnrestricted(scope.riskTags, frame.riskTags)
            && intersectsOrUnrestricted(scope.consequenceTags, frame.consequenceTags)
    }

    private func intersectsOrUnrestricted(_ restriction: [String], _ values: [String]) -> Bool {
        restriction.isEmpty || !Set(restriction).isDisjoint(with: Set(values))
    }

    private func pathsMatchOrUnrestricted(_ prefixes: [String], _ paths: [String]) -> Bool {
        prefixes.isEmpty || prefixes.contains { prefix in
            paths.contains { path in path == prefix || path.hasPrefix(prefix + "/") }
        }
    }

    private func specificity(of scope: MemoryScope) -> Int {
        scope.projectIDs.count
            + scope.pathPrefixes.count
            + scope.capabilityTags.count
            + scope.riskTags.count
            + scope.consequenceTags.count
    }

    private func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.state.record.blocking != rhs.state.record.blocking { return lhs.state.record.blocking }
        if lhs.state.record.priority != rhs.state.record.priority {
            return lhs.state.record.priority > rhs.state.record.priority
        }
        if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
        let left = ASKTimestamp.OrderKey(lhs.state.effectiveFrom)
        let right = ASKTimestamp.OrderKey(rhs.state.effectiveFrom)
        if left != right { return right < left }
        return lhs.state.record.recordID < rhs.state.record.recordID
    }

    private func contextRecord(_ candidate: Candidate) -> ContextRecord {
        let state = candidate.state
        return ContextRecord(
            recordID: state.record.recordID,
            tier: state.tier,
            kind: state.record.kind,
            verification: state.verification,
            statement: state.record.statement,
            priority: state.record.priority,
            blocking: state.record.blocking,
            evidenceRefs: state.evidenceRefs
        )
    }

    private func render(_ candidate: Candidate) -> String {
        let state = candidate.state
        let record = state.record
        let evidence = state.evidenceRefs.map(\.evidenceID).sorted().joined(separator: ", ")
        return """
        - [\(state.tier.rawValue)/\(state.verification.rawValue)/\(record.recordID)] \(record.statement)
          evidence: \(evidence.isEmpty ? "none" : evidence)
          blocking: \(record.blocking ? "true" : "false")
        """
    }
}

/// Pure policy output only. The runtime that receives this value chooses whether
/// to pause, request a human decision, or continue after showing a reminder.
public enum DecisionMemoryIntervention {
    public static func decide(bundle: ContextBundle, frame: TaskFrame) -> InterventionDecision {
        let proposedConstraints = bundle.records.filter {
            $0.verification == .proposed && $0.kind == .constraint
        }
        if !proposedConstraints.isEmpty {
            return InterventionDecision(
                kind: .requireVerification,
                recordIDs: proposedConstraints.map(\.recordID).sorted(),
                reason: "proposed constraints cannot be treated as verified facts"
            )
        }

        let blockingConstraints = bundle.records.filter {
            $0.tier == .ltsm && $0.verification == .verified && $0.blocking
        }
        guard !blockingConstraints.isEmpty else {
            return InterventionDecision(kind: .silence)
        }
        let IDs = blockingConstraints.map(\.recordID).sorted()
        if frame.riskTags.contains("irreversible") {
            return InterventionDecision(
                kind: .block,
                recordIDs: IDs,
                reason: "verified blocking long-term constraints apply to an irreversible task"
            )
        }
        return InterventionDecision(
            kind: .remind,
            recordIDs: IDs,
            reason: "verified blocking long-term constraints apply"
        )
    }
}

private struct Candidate: Sendable {
    let state: MemoryRecordState
    let specificity: Int
}
