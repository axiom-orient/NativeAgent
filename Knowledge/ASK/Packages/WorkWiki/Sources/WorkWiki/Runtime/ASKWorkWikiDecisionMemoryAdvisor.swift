import DecisionMemory
import Foundation
import KnowledgeCore

/// Read-only memory advice supplied to a workflow before it chooses its own
/// action. This value intentionally contains no closure, command, or mutation
/// capability: `InterventionDecision` is advice, never an implicit act.
public struct ASKWorkWikiDecisionMemoryAdvice: Codable, Sendable, Equatable {
    public let context: ContextBundle
    public let intervention: InterventionDecision

    public init(context: ContextBundle, intervention: InterventionDecision) {
        self.context = context
        self.intervention = intervention
    }
}

/// Composition boundary between decision-memory lifecycle state and work
/// workflows. It performs no PageIndex retrieval and no work mutation; a
/// caller that needs source evidence must explicitly invoke PageIndex first.
public struct ASKWorkWikiDecisionMemoryAdvisor: Sendable {
    private let store: DecisionMemoryStore

    public init(decisionMemoryRootURL: URL) {
        self.store = DecisionMemoryStore(root: decisionMemoryRootURL)
    }

    public init(store: DecisionMemoryStore) {
        self.store = store
    }

    public func advise(
        for frame: TaskFrame,
        budget: ContextBudget = ContextBudget(),
        validateEvidence: (@Sendable (MemoryRecordState) async throws -> [OmissionDiagnostic])? = nil
    ) async throws -> ASKWorkWikiDecisionMemoryAdvice {
        try frame.validate()
        try budget.validate()
        let replay = try await store.replay(asOf: frame.requestedAt)
        let compiler = DeterministicContextCompiler()
        var omissions: [OmissionDiagnostic] = []
        if let validateEvidence {
            for state in compiler.scopedStates(snapshot: replay.snapshot, frame: frame) where state.verification == .verified {
                try Task.checkCancellation()
                omissions += try await validateEvidence(state)
            }
        }
        let context = try compiler.compile(snapshot: replay.snapshot, frame: frame,
            generation: replay.generation, budget: budget, evidenceOmissions: omissions)
        return ASKWorkWikiDecisionMemoryAdvice(
            context: context,
            intervention: DecisionMemoryIntervention.decide(bundle: context, frame: frame)
        )
    }
}

/// A narrow write adapter for explicitly authorized memory lifecycle facts.
/// It never derives a transition from workflow output; callers submit the
/// immutable record or transition that has already been reviewed.
public struct ASKWorkWikiDecisionMemoryJournal: Sendable {
    private let store: DecisionMemoryStore

    public init(decisionMemoryRootURL: URL) {
        self.store = DecisionMemoryStore(root: decisionMemoryRootURL)
    }

    public init(store: DecisionMemoryStore) {
        self.store = store
    }

    /// Read-only lifecycle input for a host's evidence admission boundary.
    public func snapshot(asOf: String) async throws -> MemoryLifecycleSnapshot {
        try await store.replay(asOf: asOf).snapshot
    }

    public func containsIdenticalTransition(_ transition: MemoryTransition) async throws -> Bool {
        try await store.containsIdenticalTransition(transition)
    }

    public func append(_ record: MemoryRecord) async throws -> ASKWorkWikiDecisionMemoryState {
        let replay = try await store.append(record)
        return ASKWorkWikiDecisionMemoryState(replay: replay)
    }

    public func append(_ records: [MemoryRecord]) async throws -> ASKWorkWikiDecisionMemoryState {
        let replay = try await store.append(records)
        return ASKWorkWikiDecisionMemoryState(replay: replay)
    }

    public func append(_ transition: MemoryTransition) async throws -> ASKWorkWikiDecisionMemoryState {
        let replay = try await store.append(transition)
        return ASKWorkWikiDecisionMemoryState(replay: replay)
    }

    public func consolidate(asOf: String) async throws -> ASKWorkWikiDecisionMemoryConsolidation {
        let materialization = try await store.materialize(asOf: asOf)
        return ASKWorkWikiDecisionMemoryConsolidation(
            state: ASKWorkWikiDecisionMemoryState(replay: materialization.replay),
            files: materialization.files
        )
    }
}

public struct ASKWorkWikiDecisionMemoryState: Codable, Sendable, Equatable {
    public let generation: String
    public let recordCount: Int
    public let transitionCount: Int

    init(replay: DecisionMemoryReplay) {
        generation = replay.generation
        recordCount = replay.recordCount
        transitionCount = replay.transitionCount
    }
}

public struct ASKWorkWikiDecisionMemoryConsolidation: Codable, Sendable, Equatable {
    public let state: ASKWorkWikiDecisionMemoryState
    public let files: [String]

    public init(state: ASKWorkWikiDecisionMemoryState, files: [String]) {
        self.state = state
        self.files = files
    }
}
