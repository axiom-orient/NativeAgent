import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeCrashRecoveryTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor CrashExecutionCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private struct CrashRecoveryCompletionPayload: Codable {
    let message: AgentMessage
    let artifacts: [ArtifactRecord]
}

private struct CrashRecoveryToolPack: ToolPack {
    let packID = "toolpack.crash-recovery"
    let definition: ToolDefinition
    let counter: CrashExecutionCounter

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let invocation = await counter.increment()
                return .text(callID: call.id, toolName: call.name, content: "recovered-\(invocation)")
            }
        ]
    }
}

private func makePendingToolSnapshot(
    sessionID: String,
    call: ToolCall,
    timestamp: Date
) -> SessionSnapshot {
    let snapshot = SessionSnapshotTransitions.makeStartedSession(
        input: SessionStartInput(
            sessionID: sessionID,
            userPrompt: "apply",
            systemPrompt: nil,
            title: nil,
            modelID: nil,
            metadata: [:],
            requestMetadata: [:],
            providerID: "provider.test.scripted",
            timestamp: timestamp
        ),
        idGenerator: { UUID().uuidString }
    )
    return snapshot.applying(.appended(
        messages: [
        AgentMessage(
            id: "assistant-pending",
            role: .assistant,
            content: "pending tool call",
            createdAt: timestamp,
            toolCalls: [call]
        )
        ],
        artifacts: snapshot.artifacts,
        updatedAt: timestamp
    ))
}

@Test
func restartRecoversPendingToolCallBeforeNextModelTurn() async throws {
    let tempRoot = makeCrashRecoveryTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = CrashExecutionCounter()
    let timestamp = Date(timeIntervalSince1970: 1_726_000_100)
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: ["content": ToolSchema.string(description: "Content")], required: ["content"]),
        approvalPolicy: .automatic
    )
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let snapshot = makePendingToolSnapshot(sessionID: "crash-session", call: call, timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])

    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [CrashRecoveryToolPack(definition: definition, counter: counter)]
    )

    let finalSnapshot = try await coordinator.run(sessionID: snapshot.sessionID)
    let roles = finalSnapshot.messages.map(\.role)

    #expect(await counter.value() == 1)
    #expect(roles == [.user, .assistant, .tool, .assistant])
    #expect(finalSnapshot.messages.first(where: { $0.role == .tool })?.content == "recovered-1")
}

@Test
func restartReplaysCompletedEffectWithoutReexecutingTool() async throws {
    let tempRoot = makeCrashRecoveryTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = CrashExecutionCounter()
    let timestamp = Date(timeIntervalSince1970: 1_726_000_200)
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: ["content": ToolSchema.string(description: "Content")], required: ["content"]),
        approvalPolicy: .automatic
    )
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let snapshot = makePendingToolSnapshot(sessionID: "crash-replay", call: call, timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])

    let artifact = try await store.persistArtifact(
        sessionID: snapshot.sessionID,
        artifact: ArtifactWriteRequest(
            preferredFilename: "replayed.txt",
            mimeType: "text/plain",
            data: Data("artifact-replayed".utf8)
        ),
        createdAt: timestamp
    )
    let toolMessage = AgentMessage(
        id: "tool-completed",
        role: .tool,
        content: "replayed-from-ledger",
        createdAt: timestamp,
        toolCallID: call.id,
        toolName: call.name,
        metadata: ["isError": .bool(false)]
    )
    try await store.saveEffect(
        EffectRecord(
            sessionID: snapshot.sessionID,
            scope: .toolCall,
            key: call.id,
            effectType: definition.name,
            status: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            input: try JSONValue.encode(call),
            result: try JSONValue.encode(
                CrashRecoveryCompletionPayload(message: toolMessage, artifacts: [artifact])
            )
        )
    )

    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [CrashRecoveryToolPack(definition: definition, counter: counter)]
    )

    let finalSnapshot = try await coordinator.run(sessionID: snapshot.sessionID)
    let toolMessages = finalSnapshot.messages.filter { $0.role == .tool }

    #expect(await counter.value() == 0)
    #expect(toolMessages.map(\.content) == ["replayed-from-ledger"])
    #expect(toolMessages.first?.metadata["effectReplayed"]?.boolValue == true)
    #expect(finalSnapshot.artifacts.count == 1)

    let artifactData = try await coordinator.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifact.id)
    #expect(String(decoding: artifactData, as: UTF8.self) == "artifact-replayed")
}

@Test
func restartRequiresReconciliationForStartedEffect() async throws {
    let tempRoot = makeCrashRecoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = CrashExecutionCounter()
    let timestamp = Date(timeIntervalSince1970: 1_726_000_300)
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: ["content": ToolSchema.string(description: "Content")], required: ["content"]),
        approvalPolicy: .automatic
    )
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let snapshot = makePendingToolSnapshot(sessionID: "crash-block", call: call, timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])
    try await store.saveEffect(
        EffectRecord(
            sessionID: snapshot.sessionID,
            scope: .toolCall,
            key: call.id,
            effectType: definition.name,
            status: .started,
            createdAt: timestamp,
            updatedAt: timestamp,
            input: try JSONValue.encode(call)
        )
    )

    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [CrashRecoveryToolPack(definition: definition, counter: counter)]
    )

    let providerCallsBeforeRun = await provider.callCount()
    await #expect(throws: AgentError.self) {
        _ = try await coordinator.run(sessionID: snapshot.sessionID)
    }
    let afterRun = try #require(try await store.loadSnapshot(sessionID: snapshot.sessionID))
    let effect = try #require(
        try await store.loadEffect(
            sessionID: snapshot.sessionID,
            scope: .toolCall,
            key: call.id
        )
    )
    let inspection = try await coordinator.inspectRecovery(sessionID: snapshot.sessionID)
    let item = try #require(inspection.pendingToolEffects.first)

    #expect(afterRun == snapshot)
    #expect(afterRun.revision == snapshot.revision)
    #expect(afterRun.messages == snapshot.messages)
    #expect(afterRun.messages.contains(where: { $0.role == .tool }) == false)
    #expect(await counter.value() == 0)
    #expect(await provider.callCount() == providerCallsBeforeRun)
    #expect(effect.status == .started)
    #expect(inspection.requiresHostReconciliation)
    #expect(item.call == call)
    #expect(item.effectRecord?.status == .started)
    #expect(item.disposition == .reconciliationRequired)
}
