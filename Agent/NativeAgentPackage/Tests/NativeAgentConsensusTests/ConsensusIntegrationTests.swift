import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
@testable import NativeAgentTools
import NativeAgentTestSupport
@testable import NativeAgentConsensus

private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private extension SessionCoordinator {
    nonisolated func testConsensusRoleDriver(
        name: String,
        defaultModelID: String? = nil
    ) -> SessionConsensusRoleDriver {
        SessionConsensusRoleDriver(
            name: name,
            defaultModelID: defaultModelID
        ) { [self] input in
            try await startSession(
                userPrompt: input.userPrompt,
                systemPrompt: input.systemPrompt,
                title: input.title,
                metadata: input.metadata,
                requestMetadata: input.requestMetadata
            )
        }
    }
}

@Test
func bacEngineAcceptsOnFirstRound() async throws {
    let bundle = ScriptedBundle(
        problem: ProblemPacket(
            objective: "fix failing job",
            observedIssue: "job exits 1",
            primaryClass: "logic-algorithm"
        ),
        constructor: [
            ProposalArtifact(
                summary: "apply the known patch",
                plan: [.init(label: "apply patch", precise: true)]
            )
        ],
        verifier: [
            ReviewArtifact(
                summary: "patch matches the observed failure",
                verdict: .pass,
                checks: [.init(label: "run regression suite")]
            )
        ],
        challenger: [
            ChallengeArtifact(
                summary: "no unresolved counterexample remains",
                verdict: .clear
            )
        ]
    )

    let result = try await BACEngine(triad: bundle.triad).run(problem: bundle.problem)

    #expect(result.final.decision == .accept)
    #expect(result.rounds.count == 1)
}

@Test
func routingClientDelegatesToBaseWhenConsensusMetadataIsAbsent() async throws {
    let base = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "base answer")
    ])

    let triad = RoleBackedTriad(
        constructor: try SessionCoordinator(
            modelClient: ScriptedModelClient(scriptedTurns: []),
            approvalRouter: AllowAllApprovalRouter(),
            runtimeStore: ApplicationSupportSessionStore(rootURL: makeTempDirectory()),
            toolPacks: []
        ).testConsensusRoleDriver(name: "constructor"),
        verifier: try SessionCoordinator(
            modelClient: ScriptedModelClient(scriptedTurns: []),
            approvalRouter: AllowAllApprovalRouter(),
            runtimeStore: ApplicationSupportSessionStore(rootURL: makeTempDirectory()),
            toolPacks: []
        ).testConsensusRoleDriver(name: "verifier"),
        challenger: try SessionCoordinator(
            modelClient: ScriptedModelClient(scriptedTurns: []),
            approvalRouter: AllowAllApprovalRouter(),
            runtimeStore: ApplicationSupportSessionStore(rootURL: makeTempDirectory()),
            toolPacks: []
        ).testConsensusRoleDriver(name: "challenger")
    )

    let routing = ConsensusRoutingModelClient(
        base: base,
        runner: ConsensusRunner(triad: triad)
    )

    let turn = try await routing.generate(
        request: ModelRequest(
            sessionID: "s1",
            messages: [.init(role: .user, content: "answer")],
            tools: []
        )
    )

    #expect(turn.content == "base answer")
    let count = await base.callCount()
    #expect(count == 1)
}

@Test
func importantTurnUsesConsensusAndNormalTurnsStayOnBaseProvider() async throws {
    let mainRoot = makeTempDirectory()
    let constructorRoot = makeTempDirectory()
    let verifierRoot = makeTempDirectory()
    let challengerRoot = makeTempDirectory()
    let toolRoot = makeTempDirectory()

    let mainBase = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "normal answer"),
        ModelTurn(content: "back to normal")
    ])

    let constructorBase = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "I'll stage evidence first.",
            toolCalls: [
                ToolCall(
                    id: "call-1",
                    name: "files.writeText",
                    arguments: [
                        "path": "notes/context.txt",
                        "content": "pin timeout"
                    ]
                )
            ]
        ),
        ModelTurn(content: #"{"summary":"pin timeout after writing context","plan":[{"label":"pin timeout","precise":true}],"assumptions":[],"evidenceRefs":[]}"#)
    ])

    let verifierBase = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: #"{"summary":"verification is concrete","verdict":"pass","requiredActions":[],"blockers":[],"checks":[{"label":"confirm canary healthy"}],"evidenceRefs":[]}"#)
    ])

    let challengerBase = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: #"{"summary":"no blocker remains","verdict":"clear","concerns":[],"requiredActions":[],"saferOption":"","evidenceRefs":[]}"#)
    ])

    let constructorCoordinator = try SessionCoordinator(
        modelClient: constructorBase,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: ApplicationSupportSessionStore(rootURL: constructorRoot),
        toolPacks: [FilesToolPack(rootURL: toolRoot)]
    )
    let verifierCoordinator = try SessionCoordinator(
        modelClient: verifierBase,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: ApplicationSupportSessionStore(rootURL: verifierRoot),
        toolPacks: []
    )
    let challengerCoordinator = try SessionCoordinator(
        modelClient: challengerBase,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: ApplicationSupportSessionStore(rootURL: challengerRoot),
        toolPacks: []
    )

    let triad = RoleBackedTriad(
        constructor: constructorCoordinator.testConsensusRoleDriver(name: "native-agent.constructor"),
        verifier: verifierCoordinator.testConsensusRoleDriver(name: "native-agent.verifier"),
        challenger: challengerCoordinator.testConsensusRoleDriver(name: "native-agent.challenger")
    )

    let routing = ConsensusRoutingModelClient(
        base: mainBase,
        runner: ConsensusRunner(triad: triad)
    )

    let coordinator = try SessionCoordinator(
        modelClient: routing,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: ApplicationSupportSessionStore(rootURL: mainRoot),
        toolPacks: []
    )

    let started = try await coordinator.startSession(userPrompt: "say hi")
    #expect(started.messages.last?.content == "normal answer")

    let consensusMetadata = try ConsensusMetadata.required(
        problem: ProblemPacket(
            objective: "stabilize deploy",
            observedIssue: "health check is flaky",
            primaryClass: "environment-dependency-config"
        )
    )

    let consensusTurn = try await coordinator.continueSession(
        sessionID: started.sessionID,
        userPrompt: "Should we cut over now?",
        requestMetadata: consensusMetadata
    )

    let consensusAssistant = try #require(consensusTurn.messages.last(where: { $0.role == .assistant }))
    #expect(consensusAssistant.content.contains("Decision: accept"))
    #expect(consensusAssistant.metadata[ConsensusMetadataKeys.decision]?.stringValue == "accept")
    #expect(FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("notes/context.txt").path))
    #expect(try String(contentsOf: toolRoot.appendingPathComponent("notes/context.txt"), encoding: .utf8) == "pin timeout")

    let resumed = try await coordinator.continueSession(
        sessionID: started.sessionID,
        userPrompt: "and now continue normally"
    )
    #expect(resumed.messages.last?.content == "back to normal")

    let mainCalls = await mainBase.callCount()
    let constructorCalls = await constructorBase.callCount()
    let verifierCalls = await verifierBase.callCount()
    let challengerCalls = await challengerBase.callCount()

    #expect(mainCalls == 2)
    #expect(constructorCalls == 2)
    #expect(verifierCalls == 1)
    #expect(challengerCalls == 1)
}
