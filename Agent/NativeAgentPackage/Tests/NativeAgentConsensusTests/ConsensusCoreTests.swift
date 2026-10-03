import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentConsensus
import NativeAgentTestSupport

private struct ForwardingConsensusModelClient: ModelClient {
    let providerID: String
    let modelDescriptor: ModelDescriptor?
    let events: [ModelEvent]

    func generate(request: ModelRequest) async throws -> ModelTurn {
        ModelTurn(content: "generated")
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream<ModelEvent, any Error> { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}


private func makeProblemPacket() -> ProblemPacket {
    ProblemPacket(
        objective: "stabilize deploy",
        observedIssue: "health check is flaky",
        primaryClass: "environment-dependency-config"
    )
}

private func makeAcceptingTriad() -> Triad {
    ScriptedBundle(
        problem: makeProblemPacket(),
        constructor: [ProposalArtifact(summary: "proposal")],
        verifier: [ReviewArtifact(summary: "review", verdict: .pass)],
        challenger: [ChallengeArtifact(summary: "challenge", verdict: .clear)]
    ).triad
}

private struct StaticCaseRegistry: CaseRegistry {
    var cases: [CaseCard]

    func search(query: CaseQuery) async throws -> [CaseCard] {
        cases
    }
}

private actor RecordingConsensusObserver: ConsensusObserver {
    private var runStarts: [BACResult] = []

    func onRunStart(result: BACResult) async throws {
        runStarts.append(result)
    }

    func onRoundComplete(result: BACResult, round: BACRoundResult) async throws {}

    func onRunComplete(result: BACResult) async throws {}

    func recordedRunStarts() -> [BACResult] {
        runStarts
    }
}

private actor RoundSnapshotObserver: ConsensusObserver {
    private var rounds: [(BACResult, BACRoundResult)] = []
    private var completed: BACResult?

    func onRunStart(result: BACResult) async throws {}

    func onRoundComplete(result: BACResult, round: BACRoundResult) async throws {
        rounds.append((result, round))
    }

    func onRunComplete(result: BACResult) async throws {
        completed = result
    }

    func snapshots() -> ([(BACResult, BACRoundResult)], BACResult?) {
        (rounds, completed)
    }
}

private struct ReviseThenAcceptGate: Gate {
    func decide(input: GateInput) -> Consensus {
        Consensus(
            decision: input.round == 1 ? .revise : .accept,
            summary: "gate",
            sourceRound: input.round
        )
    }
}

private actor BlockingFirstRoundObserver: ConsensusObserver {
    private var firstRoundObserved = false
    private var firstRoundWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func onRunStart(result _: BACResult) async throws {}

    func onRoundComplete(result _: BACResult, round _: BACRoundResult) async throws {
        guard firstRoundObserved == false else { return }
        firstRoundObserved = true
        firstRoundWaiter?.resume()
        firstRoundWaiter = nil
        guard released == false else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func onRunComplete(result _: BACResult) async throws {}

    func waitUntilFirstRound() async {
        guard firstRoundObserved == false else { return }
        await withCheckedContinuation { continuation in
            firstRoundWaiter = continuation
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Test
func consensusMetadataExecutionPlanClampsOptionsAndSkipsRoleSessions() throws {
    let problem = makeProblemPacket()
    let metadata = try ConsensusMetadata.required(
        problem: problem,
        options: ConsensusRunOptions(
            maxRounds: 0,
            maxRequiredSteps: 0,
            registryQueryLimit: 0
        )
    )

    let plan = try #require(try ConsensusMetadata.executionPlan(from: metadata))
    #expect(plan.problem == problem)
    #expect(plan.options.maxRounds == 1)
    #expect(plan.options.maxRequiredSteps == 1)
    #expect(plan.options.registryQueryLimit == 1)

    var roleMetadata = metadata
    roleMetadata[ConsensusMetadataKeys.roleSession] = .bool(true)
    #expect(try ConsensusMetadata.executionPlan(from: roleMetadata) == nil)
}

@Test
func bacEnginePublicConfigKeepsNormalizedDefaults() throws {
    let engine = try BACEngine(
        config: BACConfig(
            maxRounds: 99,
            maxRequiredSteps: 0,
            registryQueryLimit: 0
        ),
        triad: makeAcceptingTriad()
    )

    #expect(engine.config.maxRounds == BACEngine.hardMaxRounds)
    #expect(engine.config.maxRequiredSteps == 1)
    #expect(engine.config.registryQueryLimit == 1)
    #expect(engine.config.gate != nil)
    #expect(engine.config.synthesizer != nil)
}

@Test
func runStartObserverReceivesSimilarCasesAfterRegistrySearch() async throws {
    let caseCard = CaseCard(
        id: "case-1",
        createdAt: .distantPast,
        runID: "previous-run",
        title: "stabilized health check",
        objective: "stabilize deploy",
        primaryClass: "environment-dependency-config",
        chosenResolution: "pin timeout",
        outcome: "passed",
        searchText: "health check timeout"
    )
    let observer = RecordingConsensusObserver()
    let engine = try BACEngine(
        config: BACConfig(
            registry: StaticCaseRegistry(cases: [caseCard]),
            observers: [observer],
            now: { .distantPast },
            runID: { "run-1" }
        ),
        triad: makeAcceptingTriad()
    )

    _ = try await engine.run(problem: makeProblemPacket())

    let starts = await observer.recordedRunStarts()
    #expect(starts.count == 1)
    let start = try #require(starts.first)
    #expect(start.similarCases == [caseCard])
    #expect(start.rounds.isEmpty)
}

@Test
func consensusObserversReceiveValueSnapshotsAcrossRoundAndCompletion() async throws {
    let observer = RoundSnapshotObserver()
    let engine = try BACEngine(
        config: BACConfig(
            observers: [observer],
            now: { .distantPast },
            runID: { "snapshot-run" }
        ),
        triad: makeAcceptingTriad()
    )

    let final = try await engine.run(problem: makeProblemPacket())
    let (roundSnapshots, completed) = await observer.snapshots()
    let roundSnapshot = try #require(roundSnapshots.first)
    let completion = try #require(completed)

    #expect(roundSnapshot.0.rounds == [roundSnapshot.1])
    #expect(roundSnapshot.0.final == Consensus(decision: .abort, summary: "", sourceRound: 0))
    #expect(roundSnapshot.1.consensus.decision == .accept)
    #expect(roundSnapshot.1.consensus.finalizedAt == .distantPast)
    #expect(completion == final)
    #expect(completion.final == roundSnapshot.1.consensus)
}

@Test
func consensusStopsAtRoundBoundaryAfterCancellation() async throws {
    let observer = BlockingFirstRoundObserver()
    let engine = try BACEngine(
        config: BACConfig(
            maxRounds: 2,
            gate: ReviseThenAcceptGate(),
            observers: [observer]
        ),
        triad: makeAcceptingTriad()
    )
    let task = Task {
        try await engine.run(problem: makeProblemPacket())
    }

    await observer.waitUntilFirstRound()
    task.cancel()
    await observer.release()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}

@Test
func invalidConsensusMetadataFailsBeforeBaseProviderSideEffects() async throws {
    let base = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "base")
    ])

    let routing = ConsensusRoutingModelClient(
        base: base,
        runner: ConsensusRunner(triad: makeAcceptingTriad())
    )

    await #expect(throws: ConsensusMetadataError.self) {
        _ = try await routing.generate(
            request: ModelRequest(
                sessionID: "s1",
                messages: [],
                tools: [],
                metadata: [ConsensusMetadataKeys.mode: .string(ConsensusMode.required.rawValue)]
            )
        )
    }

    let count = await base.callCount()
    #expect(count == 0)
}

@Test
func consensusRoutingClientForwardsDescriptorAndStream() async throws {
    let descriptor = ModelDescriptor(
        id: "model.consensus-forwarded",
        providerID: "provider.consensus-forwarded",
        capabilities: [.textInput, .textOutput, .streaming],
        contextWindowTokens: 16_384
    )
    let events: [ModelEvent] = [
        .started(descriptor: descriptor),
        .textDelta("forwarded"),
        .completed(ModelTurn(content: "forwarded")),
    ]
    let base = ForwardingConsensusModelClient(
        providerID: "provider.consensus-forwarded",
        modelDescriptor: descriptor,
        events: events
    )
    let routing = ConsensusRoutingModelClient(
        base: base,
        runner: ConsensusRunner(triad: makeAcceptingTriad())
    )

    #expect(routing.modelDescriptor == descriptor)
    #expect(routing.providerID == base.providerID)

    var observed: [ModelEvent] = []
    for try await event in routing.stream(
        request: ModelRequest(
            sessionID: "forwarding",
            messages: [.init(role: .user, content: "forward")],
            tools: []
        )
    ) {
        observed.append(event)
    }
    #expect(observed == events)
}

@Test
func defaultGateRevisesForPreciseBoundedActionsAndAbortsForRepeatedBlockersAtLimit() {
    let gate = DefaultGate(maxRequiredSteps: 2)

    let reviseArtifacts = RoundArtifacts(
        proposal: ProposalArtifact(
            summary: "apply a narrow config change",
            plan: [Action(label: "pin timeout", precise: true)]
        ),
        review: ReviewArtifact(
            summary: "one follow-up change is required",
            verdict: .revise,
            requiredActions: [Action(label: "pin timeout", precise: true)]
        ),
        challenge: ChallengeArtifact(
            summary: "risk is controlled after one action",
            verdict: .revise,
            requiredActions: [Action(label: "pin timeout", precise: true)]
        )
    )

    let revise = gate.decide(
        input: GateInput(
            round: 1,
            maxRounds: 2,
            previous: nil,
            artifacts: reviseArtifacts
        )
    )

    #expect(revise.decision == .revise)
    #expect(revise.reasons == ["bounded_revision_available"])

    let blocker = Blocker(label: "production health check is still unstable")
    let repeatedBlockerArtifacts = RoundArtifacts(
        proposal: ProposalArtifact(summary: "same candidate"),
        review: ReviewArtifact(
            summary: "same blocker still applies",
            verdict: .revise,
            requiredActions: [Action(label: "collect one more signal", precise: true)],
            blockers: [blocker]
        ),
        challenge: ChallengeArtifact(
            summary: "same concern remains",
            verdict: .revise,
            concerns: [blocker]
        )
    )

    let abort = gate.decide(
        input: GateInput(
            round: 2,
            maxRounds: 2,
            previous: Consensus(
                decision: .revise,
                blockers: [blocker],
                sourceRound: 1
            ),
            artifacts: repeatedBlockerArtifacts
        )
    )

    #expect(abort.decision == .abort)
    #expect(abort.reasons == ["same_blocker_repeated"])
}

@Test
func defaultGateRejectsWhitespacePaddedCriticalBlockers() {
    let gate = DefaultGate(maxRequiredSteps: 2)
    let artifacts = RoundArtifacts(
        proposal: ProposalArtifact(
            summary: "apply a narrow config change",
            plan: [Action(label: "pin timeout", precise: true)]
        ),
        review: ReviewArtifact(
            summary: "critical blocker remains",
            verdict: .revise,
            requiredActions: [Action(label: "pin timeout", precise: true)],
            blockers: [Blocker(label: "production health check is unsafe", severity: "critical ")]
        ),
        challenge: ChallengeArtifact(
            summary: "risk still needs a hold",
            verdict: .revise
        )
    )

    let result = gate.decide(
        input: GateInput(
            round: 1,
            maxRounds: 2,
            previous: nil,
            artifacts: artifacts
        )
    )

    #expect(result.decision == .abort)
    #expect(result.reasons == ["revision_not_viable"])
}

@Test
func conciseRendererIncludesOnlyNonEmptySections() {
    let result = BACResult(
        runID: "run-1",
        engine: BACEngine.engineName,
        startedAt: .distantPast,
        finishedAt: .distantFuture,
        problem: makeProblemPacket(),
        final: Consensus(
            decision: .accept,
            summary: "safe to proceed",
            requiredActions: [Action(label: "monitor canary", precise: true)],
            blockers: [Blocker(label: "none")],
            checks: [Check(label: "verify rollback")],
            selectedPlan: [Action(label: "pin timeout", precise: true)],
            saferOption: "delay rollout one hour",
            sourceRound: 1
        )
    )

    let rendered = ConsensusResponseRenderer.concise.render(result)

    #expect(rendered.contains("Decision: accept"))
    #expect(rendered.contains("Summary: safe to proceed"))
    #expect(rendered.contains("Plan:\n- pin timeout"))
    #expect(rendered.contains("Required actions:\n- monitor canary"))
    #expect(rendered.contains("Blockers:\n- none"))
    #expect(rendered.contains("Checks:\n- verify rollback"))
    #expect(rendered.contains("Safer option: delay rollout one hour"))
}
