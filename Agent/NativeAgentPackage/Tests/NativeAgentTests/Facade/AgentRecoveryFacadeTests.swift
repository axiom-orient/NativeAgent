import Foundation
import Testing
import NativeAgent
import NativeAgentDomain
import NativeAgentStore
import NativeAgentTestSupport

@Suite(.serialized)
struct AgentRecoveryFacadeTests {
    @Test
    func facadeInspectsAndReconcilesUncertainToolEffectWithoutExecutingTool() async throws {
        let root = temporaryDirectory("tool-effect")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-tool-recovery"
        let call = ToolCall(
            id: "call-tool-recovery",
            name: "app.commit",
            arguments: .object(["value": .string("alpha")])
        )
        let store = ApplicationSupportSessionStore(rootURL: root)
        try await store.prepare()
        try await store.createSession(
            SessionSnapshot(
                sessionID: sessionID,
                status: .running,
                messages: [
                    AgentMessage(id: "user-1", role: .user, content: "commit alpha"),
                    AgentMessage(
                        id: "assistant-1",
                        role: .assistant,
                        content: "committing",
                        toolCalls: [call]
                    )
                ]
            ),
            events: [],
            effects: []
        )
        try await store.saveEffect(
            EffectRecord(
                sessionID: sessionID,
                scope: .toolCall,
                key: call.id,
                effectType: call.name,
                status: .started,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                input: try JSONValue.encode(call)
            )
        )

        let counter = RecoveryFacadeInvocationCounter()
        let tool = AgentTool(
            name: call.name,
            description: "Commit application state.",
            inputSchema: ToolSchema.object(
                properties: ["value": ToolSchema.string()],
                required: ["value"]
            ),
            approvalPolicy: .requireApproval
        ) { _ in
            await counter.increment()
            return .object(["content": .string("executor must not run")])
        }
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "recovery complete")
        ])
        let agent = try Agent(
            model: model,
            storage: AgentStorage(runtimePersistence: store),
            tools: [tool],
            approval: .allowAll
        )

        let inspection = try await agent.inspectRecovery(sessionID: sessionID)
        let pending = try #require(inspection.pendingToolEffects.first)
        #expect(inspection.requiresHostReconciliation)
        #expect(pending.call == call)
        #expect(pending.effectRecord?.status == .started)
        #expect(pending.disposition == .reconciliationRequired)
        #expect(await counter.value() == 0)

        let beforeSend = try await agent.session(id: sessionID)
        let modelCallsBeforeSend = await model.callCount()
        await #expect(throws: AgentError.self) {
            _ = try await agent.send("follow-up", to: sessionID)
        }
        let afterSend = try await agent.session(id: sessionID)
        #expect(afterSend == beforeSend)
        #expect(afterSend.revision == beforeSend.revision)
        #expect(afterSend.messages == beforeSend.messages)
        #expect(afterSend.status == beforeSend.status)
        #expect(await model.callCount() == modelCallsBeforeSend)
        #expect(await counter.value() == 0)
        let afterSendInspection = try await agent.inspectRecovery(sessionID: sessionID)
        let pendingAfterSend = try #require(afterSendInspection.pendingToolEffects.first)
        #expect(afterSendInspection.requiresHostReconciliation)
        #expect(pendingAfterSend.call == call)
        #expect(pendingAfterSend.effectRecord?.status == .started)
        #expect(pendingAfterSend.disposition == .reconciliationRequired)

        let final = try await agent.resolveToolEffect(
            sessionID: sessionID,
            callID: call.id,
            resolution: .completed(
                .text(
                    callID: call.id,
                    toolName: call.name,
                    content: "host verified completion",
                    artifacts: [
                        ArtifactWriteRequest(
                            preferredFilename: "recovered.txt",
                            mimeType: "text/plain",
                            data: Data("verified".utf8)
                        )
                    ]
                )
            )
        )

        #expect(final.status == .completed)
        #expect(final.output == "recovery complete")
        #expect(await counter.value() == 0)
        #expect(await model.callCount() == 1)
        #expect(final.messages.contains { message in
            message.role == .tool
                && message.toolCallID == call.id
                && message.metadata["effectReconciled"]?.boolValue == true
        })
        let artifact = try #require(final.artifacts.first)
        #expect(try await agent.loadArtifact(
            sessionID: sessionID,
            artifactID: artifact.id
        ) == Data("verified".utf8))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NativeAgent-AgentRecoveryFacade-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}

private actor RecoveryFacadeInvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

extension AgentRecoveryFacadeTests {
    @Test
    func facadeRecoversKnownSessionAfterUncertainModelInvocationWithoutBlindRetry() async throws {
        let root = temporaryDirectory("model-invocation")
        defer { try? FileManager.default.removeItem(at: root) }

        let base = ApplicationSupportSessionStore(rootURL: root)
        let store = FacadeAssistantCommitFailureStore(base: base, failures: 1)
        let model = RecoveryFacadeCountingModelClient()
        let sessionID = "session-model-recovery"
        let firstAgent = try Agent(
            model: model,
            storage: AgentStorage(runtimePersistence: store)
        )

        do {
            _ = try await firstAgent.run("hello", sessionID: sessionID)
            Issue.record("Expected the injected assistant/model-invocation commit failure")
        } catch let error as AgentError {
            guard case .persistenceFailure(let message) = error else {
                Issue.record("Unexpected AgentError: \(error)")
                return
            }
            #expect(message.contains("assistant/model-invocation"))
        }
        #expect(await model.count() == 1)

        let restartedAgent = try Agent(
            model: model,
            storage: AgentStorage(runtimePersistence: store)
        )
        let waiting = try await restartedAgent.resume(sessionID: sessionID)
        #expect(waiting.status == .waiting)
        #expect(waiting.snapshot.waitState?.kind == .modelInvocation)
        #expect(await model.count() == 1)

        let pending = try #require(
            try await restartedAgent.pendingModelInvocation(sessionID: sessionID)
        )
        #expect(pending.sessionID == sessionID)
        #expect(pending.providerID == model.providerID)
        #expect(pending.request.sessionID == sessionID)

        let final = try await restartedAgent.resolveModelInvocation(
            sessionID: sessionID,
            invocationID: pending.id,
            resolution: .completed(ModelTurn(content: "host verified response"))
        )

        #expect(final.status == .completed)
        #expect(final.output == "host verified response")
        #expect(await model.count() == 1)
        #expect(try await restartedAgent.pendingModelInvocation(sessionID: sessionID) == nil)
    }
}

private actor RecoveryFacadeCountingModelClient: ModelClient {
    nonisolated let providerID = "provider.test.recovery-facade"
    private var invocationCount = 0

    func generate(request: ModelRequest) async throws -> ModelTurn {
        invocationCount += 1
        return ModelTurn(content: "response-\(invocationCount)")
    }

    func count() -> Int {
        invocationCount
    }
}

private actor FacadeAssistantCommitFailureStore: SessionRuntimeStore, SessionExecutionClaimStore {
    private let base: ApplicationSupportSessionStore
    private var remainingFailures: Int

    init(base: ApplicationSupportSessionStore, failures: Int) {
        self.base = base
        self.remainingFailures = failures
    }

    func prepare() async throws {
        try await base.prepare()
    }

    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? {
        try await base.loadSessionRuntimeAdmission(sessionID: sessionID)
    }


    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {
        try await base.createSession(snapshot, events: events, effects: effects)
    }

    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? {
        try await base.loadSnapshot(sessionID: sessionID)
    }



    func commit(_ transaction: SessionPersistenceTransaction) async throws {
        let completesModelInvocation = transaction.effects.contains { effect in
            effect.scope == .modelInvocation && effect.status == .completed
        }
        if completesModelInvocation && remainingFailures > 0 {
            remainingFailures -= 1
            throw AgentError.persistenceFailure(
                "Injected assistant/model-invocation transaction failure"
            )
        }
        try await base.commit(transaction)
    }

    func commitFork(_ transaction: SessionForkPersistenceTransaction) async throws {
        try await base.commitFork(transaction)
    }

    func loadEvents(sessionID: String) async throws -> [SessionEvent] {
        try await base.loadEvents(sessionID: sessionID)
    }

    func loadEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) async throws -> EffectRecord? {
        try await base.loadEffect(sessionID: sessionID, scope: scope, key: key)
    }

    func saveEffect(_ effect: EffectRecord) async throws {
        try await base.saveEffect(effect)
    }

    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        try await base.acquireExecutionClaim(sessionID: sessionID)
    }

    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        try await base.releaseExecutionClaim(claim)
    }

    func listSessionSummaries(limit: Int, offset: Int) async throws -> [SessionSummary] {
        try await base.listSessionSummaries(limit: limit, offset: offset)
    }

    func querySessionList(_ query: SessionListQuery) async throws -> [SessionListItem] {
        try await base.querySessionList(query)
    }

    func searchSessionMessages(
        _ query: SessionMessageSearchQuery
    ) async throws -> SessionMessageSearchPage {
        try await base.searchSessionMessages(query)
    }

    func loadSessionSummary(sessionID: String) async throws -> SessionSummary? {
        try await base.loadSessionSummary(sessionID: sessionID)
    }

    func loadSessionMessages(
        sessionID: String,
        offset: Int,
        limit: Int
    ) async throws -> SessionMessagePage {
        try await base.loadSessionMessages(
            sessionID: sessionID,
            offset: offset,
            limit: limit
        )
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

    func sandboxRootURL() async throws -> URL {
        try await base.sandboxRootURL()
    }

    func sessionDirectoryURL(sessionID: String) async throws -> URL {
        try await base.sessionDirectoryURL(sessionID: sessionID)
    }
}
