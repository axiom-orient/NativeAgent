import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeConsistencyTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor ConsistencyExecutionCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private actor FailureInjectingStore:
    SessionRuntimeStore,
    SessionEventStore,
    EffectLedgerStore,
    SessionExecutionClaimStore
{
    let base: ApplicationSupportSessionStore
    private var remainingAssistantTurnEventFailures: Int
    private var remainingSuccessfulToolSnapshotFailures: Int
    private var remainingSuccessfulToolPostCommitFailures: Int
    private var remainingCompletedEffectFailures: Int
    private var remainingEffectLoadFailures: Int

    init(
        base: ApplicationSupportSessionStore,
        assistantTurnEventFailures: Int = 0,
        successfulToolSnapshotFailures: Int = 0,
        successfulToolPostCommitFailures: Int = 0,
        completedEffectFailures: Int = 0,
        effectLoadFailures: Int = 0
    ) {
        self.base = base
        self.remainingAssistantTurnEventFailures = assistantTurnEventFailures
        self.remainingSuccessfulToolSnapshotFailures = successfulToolSnapshotFailures
        self.remainingSuccessfulToolPostCommitFailures = successfulToolPostCommitFailures
        self.remainingCompletedEffectFailures = completedEffectFailures
        self.remainingEffectLoadFailures = effectLoadFailures
    }

    func prepare() async throws { try await base.prepare() }
    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? { try await base.loadSessionRuntimeAdmission(sessionID: sessionID) }
    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? { try await base.loadSnapshot(sessionID: sessionID) }
    func persistArtifact(sessionID: String, artifact: ArtifactWriteRequest, createdAt: Date) async throws -> ArtifactRecord {
        try await base.persistArtifact(sessionID: sessionID, artifact: artifact, createdAt: createdAt)
    }
    func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws {
        try await base.discardUnreferencedArtifact(artifact)
    }
    func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        try await base.loadArtifact(sessionID: sessionID, artifactID: artifactID)
    }
    func sandboxRootURL() async throws -> URL { try await base.sandboxRootURL() }
    func sessionDirectoryURL(sessionID: String) async throws -> URL { try await base.sessionDirectoryURL(sessionID: sessionID) }

    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {
        try await base.createSession(snapshot, events: events, effects: effects)
    }

    func commit(_ transaction: SessionPersistenceTransaction) async throws {
        if transaction.events.contains(where: { $0.kind == .assistantTurnAppended }),
           remainingAssistantTurnEventFailures > 0 {
            remainingAssistantTurnEventFailures -= 1
            throw AgentError.persistenceFailure("Injected assistant turn journal append failure")
        }
        let lastMessage = transaction.snapshot.messages.last
        let isSuccessfulToolSave =
            lastMessage?.role == .tool
            && lastMessage?.metadata["isError"]?.boolValue == false
        if isSuccessfulToolSave && remainingSuccessfulToolSnapshotFailures > 0 {
            remainingSuccessfulToolSnapshotFailures -= 1
            throw AgentError.persistenceFailure("Injected successful tool snapshot save failure")
        }
        if isSuccessfulToolSave && remainingSuccessfulToolPostCommitFailures > 0 {
            remainingSuccessfulToolPostCommitFailures -= 1
            try await base.commit(transaction)
            throw AgentError.persistenceFailure("Injected post-commit acknowledgement failure")
        }
        if transaction.effects.contains(where: {
            $0.scope == .toolCall && $0.status == .completed
        }), remainingCompletedEffectFailures > 0 {
            remainingCompletedEffectFailures -= 1
            throw AgentError.persistenceFailure("Injected completed tool effect save failure")
        }
        try await base.commit(transaction)
    }

    func loadEvents(sessionID: String) async throws -> [SessionEvent] { try await base.loadEvents(sessionID: sessionID) }

    func saveEffect(_ record: EffectRecord) async throws {
        try await base.saveEffect(record)
    }

    func loadEffect(sessionID: String, scope: EffectScope, key: String) async throws -> EffectRecord? {
        if scope == .toolCall, remainingEffectLoadFailures > 0 {
            remainingEffectLoadFailures -= 1
            throw AgentError.persistenceFailure("Injected tool effect ledger read failure")
        }
        return try await base.loadEffect(sessionID: sessionID, scope: scope, key: key)
    }

    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        try await base.acquireExecutionClaim(sessionID: sessionID)
    }

    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        try await base.releaseExecutionClaim(claim)
    }
}

private struct ConsistencyToolPack: ToolPack {
    let packID = "toolpack.consistency"
    let definition: ToolDefinition
    let counter: ConsistencyExecutionCounter
    var returnedArtifact: ArtifactWriteRequest? = nil

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let invocation = await counter.increment()
                return .text(
                    callID: call.id,
                    toolName: call.name,
                    content: "run-\(invocation)",
                    artifacts: returnedArtifact.map { [$0] } ?? []
                )
            }
        ]
    }
}

private func makeConsistencyDefinition() -> ToolDefinition {
    ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .automatic
    )
}

@Test
func assistantTurnCommitFailureLeavesNoPendingToolToExecuteOnRestart() async throws {
    let tempRoot = makeConsistencyTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = FailureInjectingStore(base: base, assistantTurnEventFailures: 1)
    let counter = ConsistencyExecutionCounter()
    let definition = makeConsistencyDefinition()
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "first",
            toolCalls: [call]
        ),
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "apply")
        Issue.record("Expected injected assistant turn journal append failure")
    } catch let error as AgentError {
        guard case .persistenceFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("assistant turn"))
    }

    let sessionID = try #require(try await base.testFirstSessionID())
    let restarted = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )
    let finalSnapshot = try await restarted.run(sessionID: sessionID)

    #expect(await counter.value() == 0)
    #expect(finalSnapshot.messages.contains(where: { $0.role == .tool }) == false)
}

@Test
func failedToolCompletionCommitLeavesStartedEffectAndBlocksReexecution() async throws {
    let tempRoot = makeConsistencyTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = FailureInjectingStore(base: base, successfulToolSnapshotFailures: 1)
    let counter = ConsistencyExecutionCounter()
    let definition = makeConsistencyDefinition()
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "first",
            toolCalls: [call]
        ),
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "apply")
        Issue.record("Expected injected successful tool snapshot save failure")
    } catch let error as AgentError {
        guard case .persistenceFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("successful tool snapshot"))
    }

    let sessionID = try #require(try await base.testFirstSessionID())
    let restarted = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )
    let beforeResume = try #require(try await store.loadSnapshot(sessionID: sessionID))
    let beforeInspection = try await restarted.inspectRecovery(sessionID: sessionID)
    let pendingBefore = try #require(beforeInspection.pendingToolEffects.first)
    #expect(beforeInspection.requiresHostReconciliation)
    #expect(pendingBefore.call == call)
    #expect(pendingBefore.effectRecord?.status == .started)
    let modelCallsBeforeResume = await provider.callCount()

    await #expect(throws: AgentError.self) {
        _ = try await restarted.run(sessionID: sessionID)
    }

    let afterResume = try #require(try await store.loadSnapshot(sessionID: sessionID))
    #expect(afterResume == beforeResume)
    #expect(afterResume.revision == beforeResume.revision)
    #expect(afterResume.messages == beforeResume.messages)
    #expect(afterResume.messages.contains { $0.role == .tool } == false)
    #expect(await counter.value() == 1)
    #expect(await provider.callCount() == modelCallsBeforeResume)

    let afterInspection = try await restarted.inspectRecovery(sessionID: sessionID)
    let pendingAfter = try #require(afterInspection.pendingToolEffects.first)
    #expect(afterInspection.requiresHostReconciliation)
    #expect(pendingAfter.call == call)
    #expect(pendingAfter.effectRecord?.status == .started)
}

@Test
func failedArtifactCommitRemovesOnlyTheUnreferencedFile() async throws {
    let tempRoot = makeConsistencyTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = FailureInjectingStore(base: base, successfulToolSnapshotFailures: 1)
    let counter = ConsistencyExecutionCounter()
    let definition = makeConsistencyDefinition()
    let call = ToolCall(id: "artifact-call", name: definition.name, arguments: ["content": "alpha"])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "create", toolCalls: [call])
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(
            definition: definition,
            counter: counter,
            returnedArtifact: ArtifactWriteRequest(
                preferredFilename: "result.txt",
                mimeType: "text/plain",
                data: Data("uncommitted".utf8)
            )
        )]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "create")
        Issue.record("Expected injected artifact transaction failure")
    } catch let error as AgentError {
        guard case .persistenceFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("successful tool snapshot"))
    }

    let snapshot = try #require(try await base.testFirstSnapshot())
    #expect(snapshot.artifacts.isEmpty)
    let directory = base.layout.artifactsDirectoryURL(sessionID: snapshot.sessionID)
    let files = if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    } else {
        []
    }
    #expect(files.isEmpty)
}

@Test
func uncertainArtifactCommitPreservesTheDurablyReferencedFile() async throws {
    let tempRoot = makeConsistencyTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = FailureInjectingStore(base: base, successfulToolPostCommitFailures: 1)
    let counter = ConsistencyExecutionCounter()
    let definition = makeConsistencyDefinition()
    let call = ToolCall(id: "artifact-call", name: definition.name, arguments: ["content": "alpha"])
    let payload = Data("committed".utf8)
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "create", toolCalls: [call])
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(
            definition: definition,
            counter: counter,
            returnedArtifact: ArtifactWriteRequest(
                preferredFilename: "result.txt",
                mimeType: "text/plain",
                data: payload
            )
        )]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "create")
        Issue.record("Expected injected post-commit acknowledgement failure")
    } catch let error as AgentError {
        guard case .persistenceFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("post-commit acknowledgement"))
    }

    let snapshot = try #require(try await base.testFirstSnapshot())
    let artifact = try #require(snapshot.artifacts.first)
    #expect(snapshot.artifacts.count == 1)
    #expect(
        try await base.loadArtifact(
            sessionID: snapshot.sessionID,
            artifactID: artifact.id
        ) == payload
    )
}

@Test
func startedEffectBlocksReexecutionWhenCompletedEffectSaveFails() async throws {
    let tempRoot = makeConsistencyTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = FailureInjectingStore(base: base, completedEffectFailures: 1)
    let counter = ConsistencyExecutionCounter()
    let definition = makeConsistencyDefinition()
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "first",
            toolCalls: [call]
        ),
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "apply")
        Issue.record("Expected injected completed effect save failure")
    } catch let error as AgentError {
        guard case .persistenceFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("completed tool effect"))
    }

    let sessionID = try #require(try await base.testFirstSessionID())
    let restarted = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )
    let beforeResume = try #require(try await store.loadSnapshot(sessionID: sessionID))
    let beforeInspection = try await restarted.inspectRecovery(sessionID: sessionID)
    let pendingBefore = try #require(beforeInspection.pendingToolEffects.first)
    #expect(beforeInspection.requiresHostReconciliation)
    #expect(pendingBefore.call == call)
    #expect(pendingBefore.effectRecord?.status == .started)
    let modelCallsBeforeResume = await provider.callCount()

    await #expect(throws: AgentError.self) {
        _ = try await restarted.run(sessionID: sessionID)
    }

    let afterResume = try #require(try await store.loadSnapshot(sessionID: sessionID))
    #expect(afterResume == beforeResume)
    #expect(afterResume.revision == beforeResume.revision)
    #expect(afterResume.messages == beforeResume.messages)
    #expect(afterResume.messages.contains { $0.role == .tool } == false)
    #expect(await counter.value() == 1)
    #expect(await provider.callCount() == modelCallsBeforeResume)

    let afterInspection = try await restarted.inspectRecovery(sessionID: sessionID)
    let pendingAfter = try #require(afterInspection.pendingToolEffects.first)
    #expect(afterInspection.requiresHostReconciliation)
    #expect(pendingAfter.call == call)
    #expect(pendingAfter.effectRecord?.status == .started)
}


@Test
func effectLedgerReadFailureFailsSessionInsteadOfBecomingToolOutput() async throws {
    let tempRoot = makeConsistencyTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = FailureInjectingStore(base: base, effectLoadFailures: 1)
    let counter = ConsistencyExecutionCounter()
    let definition = makeConsistencyDefinition()
    let call = ToolCall(id: "call-ledger-read", name: definition.name, arguments: ["content": "alpha"])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(
                content: "apply",
                toolCalls: [call]
            )
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ConsistencyToolPack(definition: definition, counter: counter)]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "apply")
        Issue.record("Expected effect ledger read failure")
    } catch let error as AgentError {
        guard case .effectLedgerFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("Injected tool effect ledger read failure"))
    }

    #expect(await counter.value() == 0)
    let snapshot = try #require(try await base.testFirstSnapshot())
    #expect(snapshot.status == .failed)
    let repairMessage = try #require(snapshot.messages.last(where: { $0.role == .tool }))
    #expect(repairMessage.metadata["isError"]?.boolValue == true)
    #expect(repairMessage.content.contains("interrupted before producing a result"))
    #expect(snapshot.failure?.code == "effect_ledger_failure")
    #expect(snapshot.failure?.message.contains("Injected tool effect ledger read failure") == true)
}
