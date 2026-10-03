import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeDurableRegressionRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
}

private actor DurableRegressionExecutionCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct ReturnedArtifactToolPack: ToolPack {
    let packID = "toolpack.direct-artifact"
    let definition: ToolDefinition

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                .text(
                    callID: call.id,
                    toolName: call.name,
                    content: "created",
                    artifacts: [
                        ArtifactWriteRequest(
                            preferredFilename: "result.txt",
                            mimeType: "text/plain",
                            data: Data("durable-result-artifact".utf8)
                        )
                    ]
                )
            }
        ]
    }
}

private actor EffectReadFailureStore:
    SessionRuntimeStore,
    SessionEventStore,
    EffectLedgerStore,
    SessionExecutionClaimStore
{
    private let base: ApplicationSupportSessionStore

    init(base: ApplicationSupportSessionStore) {
        self.base = base
    }

    func prepare() async throws { try await base.prepare() }
    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? { try await base.loadSessionRuntimeAdmission(sessionID: sessionID) }
    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? {
        try await base.loadSnapshot(sessionID: sessionID)
    }
    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {
        try await base.createSession(snapshot, events: events, effects: effects)
    }
    func commit(_ transaction: SessionPersistenceTransaction) async throws {
        try await base.commit(transaction)
    }
    func persistArtifact(
        sessionID: String,
        artifact: ArtifactWriteRequest,
        createdAt: Date
    ) async throws -> ArtifactRecord {
        try await base.persistArtifact(
            sessionID: sessionID,
            artifact: artifact,
            createdAt: createdAt
        )
    }
    func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws {
        try await base.discardUnreferencedArtifact(artifact)
    }
    func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        try await base.loadArtifact(sessionID: sessionID, artifactID: artifactID)
    }
    func sandboxRootURL() async throws -> URL { try await base.sandboxRootURL() }
    func sessionDirectoryURL(sessionID: String) async throws -> URL {
        try await base.sessionDirectoryURL(sessionID: sessionID)
    }
    func loadEvents(sessionID: String) async throws -> [SessionEvent] {
        try await base.loadEvents(sessionID: sessionID)
    }
    func saveEffect(_ record: EffectRecord) async throws {
        try await base.saveEffect(record)
    }
    func loadEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) async throws -> EffectRecord? {
        throw AgentError.persistenceFailure("Injected effect ledger read failure")
    }
    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        try await base.acquireExecutionClaim(sessionID: sessionID)
    }
    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        try await base.releaseExecutionClaim(claim)
    }
}

private struct CountingMutationToolPack: ToolPack {
    let packID = "toolpack.effect-read-failure"
    let definition: ToolDefinition
    let counter: DurableRegressionExecutionCounter

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                await counter.increment()
                return .text(callID: call.id, toolName: call.name, content: "executed")
            }
        ]
    }
}

@Test
func returnedToolArtifactIsAttachedAndSurvivesPrepare() async throws {
    let root = makeDurableRegressionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = ToolDefinition(
        name: "artifact.create",
        description: "Create one artifact.",
        capabilityID: "artifact",
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic,
        effect: .readOnly
    )
    let call = ToolCall(id: "artifact-call", name: definition.name, arguments: [:])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "create artifact", toolCalls: [call]),
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ReturnedArtifactToolPack(definition: definition)]
    )

    let completed = try await coordinator.startSession(userPrompt: "create")
    let artifact = try #require(completed.artifacts.first)
    #expect(completed.artifacts.count == 1)
    #expect(
        try await store.loadArtifact(
            sessionID: completed.sessionID,
            artifactID: artifact.id
        ) == Data("durable-result-artifact".utf8)
    )

    let restartedStore = ApplicationSupportSessionStore(rootURL: root)
    try await restartedStore.prepare()
    let reloaded = try #require(
        try await restartedStore.loadSnapshot(sessionID: completed.sessionID)
    )
    #expect(reloaded.artifacts == completed.artifacts)
    #expect(
        try await restartedStore.loadArtifact(
            sessionID: completed.sessionID,
            artifactID: artifact.id
        ) == Data("durable-result-artifact".utf8)
    )
}

@Test
func effectLedgerReadFailureFailsSessionWithoutExecutingTool() async throws {
    let root = makeDurableRegressionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = ApplicationSupportSessionStore(rootURL: root)
    let store = EffectReadFailureStore(base: base)
    let counter = DurableRegressionExecutionCounter()
    let definition = ToolDefinition(
        name: "mutation.apply",
        description: "Apply one mutation.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic
    )
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "apply",
            toolCalls: [ToolCall(id: "mutation-call", name: definition.name, arguments: [:])]
        )
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [CountingMutationToolPack(definition: definition, counter: counter)]
    )

    do {
        _ = try await coordinator.startSession(userPrompt: "apply")
        Issue.record("Expected effect-ledger read failure")
    } catch let error as AgentError {
        guard case .effectLedgerFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("Injected effect ledger read failure"))
    }

    #expect(await counter.value() == 0)
    let failed = try #require(try await base.testFirstSnapshot())
    #expect(failed.status == .failed)
    #expect(failed.failure?.message.contains("Injected effect ledger read failure") == true)
    #expect(failed.messages.contains(where: { $0.role == .tool }) == false)
}
