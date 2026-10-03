import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeEffectLedgerRuntimeTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor ExecutionCounter {
    private var valueStorage = 0

    func increment() -> Int {
        valueStorage += 1
        return valueStorage
    }

    func value() -> Int {
        valueStorage
    }
}

private struct CountingToolPack: ToolPack {
    let packID = "toolpack.counting"
    let definition: ToolDefinition
    let counter: ExecutionCounter
    let includeArtifact: Bool

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let invocation = await counter.increment()
                let artifacts: [ArtifactWriteRequest]
                if includeArtifact {
                    artifacts = [
                        ArtifactWriteRequest(
                            preferredFilename: "result-\(invocation).txt",
                            mimeType: "text/plain",
                            data: Data("artifact-\(invocation)".utf8)
                        )
                    ]
                } else {
                    artifacts = []
                }

                return .text(
                    callID: call.id,
                    toolName: call.name,
                    content: "applied-run-\(invocation)",
                    artifacts: artifacts
                )
            }
        ]
    }
}

private struct PreflightFailureToolPack: ToolPack {
    let packID = "toolpack.preflight-failure"
    let definition: ToolDefinition

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { _, _ in
                throw ToolPreflightFailure(
                    code: .conflict,
                    operation: "notes.apply.preflight",
                    cause: "revision mismatch",
                    context: ["expected": "a", "actual": "b"]
                )
            }
        ]
    }
}

@Test
func mutatingToolDedupesCompletedEffectsAndReplaysPersistedArtifacts() async throws {
    let tempRoot = makeEffectLedgerRuntimeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = ExecutionCounter()
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply a note update.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "content": ToolSchema.string(description: "Content")
            ],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval
    )
    let repeatedCall = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "apply once",
            toolCalls: [repeatedCall]
        ),
        ModelTurn(
            content: "apply again",
            toolCalls: [repeatedCall]
        ),
        ModelTurn(content: "done")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            CountingToolPack(
                definition: definition,
                counter: counter,
                includeArtifact: true
            )
        ]
    )

    let snapshot = try await coordinator.startSession(userPrompt: "apply")
    let executionCount = await counter.value()
    let effect = try await store.loadEffect(sessionID: snapshot.sessionID, scope: .toolCall, key: repeatedCall.id)
    let toolMessages = snapshot.messages.filter { $0.role == .tool }

    #expect(executionCount == 1)
    #expect(toolMessages.map(\.content) == ["applied-run-1", "applied-run-1"])
    #expect(toolMessages.last?.metadata["effectReplayed"]?.boolValue == true)
    #expect(snapshot.artifacts.count == 1)
    #expect(effect?.status == .completed)

    let artifactID = try #require(snapshot.artifacts.first?.id)
    let artifactData = try await coordinator.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifactID)
    #expect(String(decoding: artifactData, as: UTF8.self) == "artifact-1")
}

@Test
func mutatingToolRequiresReconciliationWhenStartedEffectAlreadyExists() async throws {
    let tempRoot = makeEffectLedgerRuntimeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = ExecutionCounter()
    let sessionID = "session-effect-started"
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply a note update.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "content": ToolSchema.string(description: "Content")
            ],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval
    )
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "apply once",
            toolCalls: [call]
        ),
        ModelTurn(content: "done")
    ])

    try await store.prepare()
    try await store.createSession(
        SessionSnapshot(
            sessionID: sessionID,
            status: .running,
            messages: [
                AgentMessage(id: "user-1", role: .user, content: "apply"),
                AgentMessage(
                    id: "assistant-1",
                    role: .assistant,
                    content: "apply once",
                    toolCalls: [call]
                )
            ]
        ), events: [], effects: [])
    try await store.saveEffect(
        EffectRecord(
            sessionID: sessionID,
            scope: .toolCall,
            key: call.id,
            effectType: definition.name,
            status: .started,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            input: try JSONValue.encode(call)
        )
    )

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            CountingToolPack(
                definition: definition,
                counter: counter,
                includeArtifact: false
            )
        ],
        idGenerator: { sessionID }
    )

    let beforeRun = try #require(try await store.loadSnapshot(sessionID: sessionID))
    let providerCallsBeforeRun = await provider.callCount()
    await #expect(throws: AgentError.self) {
        _ = try await coordinator.run(sessionID: sessionID)
    }
    let afterRun = try #require(try await store.loadSnapshot(sessionID: sessionID))
    let effect = try #require(
        try await store.loadEffect(sessionID: sessionID, scope: .toolCall, key: call.id)
    )
    let inspection = try await coordinator.inspectRecovery(sessionID: sessionID)
    let item = try #require(inspection.pendingToolEffects.first)

    #expect(afterRun == beforeRun)
    #expect(afterRun.revision == beforeRun.revision)
    #expect(afterRun.messages == beforeRun.messages)
    #expect(afterRun.messages.contains(where: { $0.role == .tool }) == false)
    #expect(await counter.value() == 0)
    #expect(await provider.callCount() == providerCallsBeforeRun)
    #expect(effect.status == .started)
    #expect(inspection.requiresHostReconciliation)
    #expect(item.call == call)
    #expect(item.effectRecord?.status == .started)
    #expect(item.disposition == .reconciliationRequired)
}

@Test
func readOnlyToolsDoNotPersistEffectLedgerRecords() async throws {
    let tempRoot = makeEffectLedgerRuntimeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = ExecutionCounter()
    let definition = ToolDefinition(
        name: "notes.preview",
        description: "Preview a note update.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "content": ToolSchema.string(description: "Content")
            ],
            required: ["content"]
        ),
        approvalPolicy: .automatic,
        effect: .readOnly
    )
    let repeatedCall = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "preview once",
            toolCalls: [repeatedCall]
        ),
        ModelTurn(
            content: "preview again",
            toolCalls: [repeatedCall]
        ),
        ModelTurn(content: "done")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            CountingToolPack(
                definition: definition,
                counter: counter,
                includeArtifact: false
            )
        ]
    )

    let snapshot = try await coordinator.startSession(userPrompt: "preview")
    let executionCount = await counter.value()
    let effect = try await store.loadEffect(sessionID: snapshot.sessionID, scope: .toolCall, key: repeatedCall.id)
    let toolMessages = snapshot.messages.filter { $0.role == .tool }

    #expect(executionCount == 2)
    #expect(toolMessages.map(\.content) == ["applied-run-1", "applied-run-2"])
    #expect(toolMessages.contains(where: { $0.metadata["effectReplayed"]?.boolValue == true }) == false)
    #expect(effect == nil)
}

private struct MismatchedResultToolPack: ToolPack {
    let packID = "toolpack.mismatched-result"
    let definition: ToolDefinition

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { _, _ in
                ToolResult.text(
                    callID: "wrong-call",
                    toolName: "wrong.tool",
                    content: "must not be accepted",
                    artifacts: [
                        ArtifactWriteRequest(
                            preferredFilename: "must-not-exist.txt",
                            mimeType: "text/plain",
                            data: Data("must-not-exist".utf8)
                        )
                    ]
                )
            }
        ]
    }
}

@Test
func mismatchedToolResultIdentityKeepsStartedReceiptForReconciliation() async throws {
    let tempRoot = makeEffectLedgerRuntimeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply a note update.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic
    )
    let call = ToolCall(id: "call-identity", name: definition.name, arguments: .object([:]))
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(
                content: "apply",
                toolCalls: [call]
            ),
            ModelTurn(content: "must-not-run")
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [MismatchedResultToolPack(definition: definition)]
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.startSession(
            sessionID: "mismatched-result-session",
            userPrompt: "apply"
        )
    }

    let snapshot = try await coordinator.loadSession(sessionID: "mismatched-result-session")
    let effect = try #require(
        try await store.loadEffect(
            sessionID: snapshot.sessionID,
            scope: .toolCall,
            key: call.id
        )
    )
    let inspection = try await coordinator.inspectRecovery(sessionID: snapshot.sessionID)
    let pending = try #require(inspection.pendingToolEffects.first)

    #expect(snapshot.status == .failed)
    #expect(snapshot.artifacts.isEmpty)
    #expect(snapshot.messages.contains(where: { $0.role == .tool }) == false)
    #expect(effect.status == .started)
    #expect(inspection.requiresHostReconciliation)
    #expect(pending.call == call)
    #expect(pending.effectRecord?.status == .started)
    #expect(pending.disposition == .reconciliationRequired)

    let artifactsDirectory = store.layout.artifactsDirectoryURL(sessionID: snapshot.sessionID)
    let artifactNames = try FileManager.default.contentsOfDirectory(atPath: artifactsDirectory.path)
    #expect(artifactNames.isEmpty)
}

@Test
func completedEffectReplayRejectsPayloadWhoseToolIdentityDoesNotMatchLedgerRecord() async throws {
    let tempRoot = makeEffectLedgerRuntimeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply a note update.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic
    )
    let call = ToolCall(id: "call-replay", name: definition.name, arguments: .object([:]))
    let invalidMessage = AgentMessage(
        role: .tool,
        content: "corrupt",
        toolCallID: "different-call",
        toolName: definition.name
    )
    let completionPayload: JSONValue = .object([
        "message": try JSONValue.encode(invalidMessage),
        "artifacts": .array([])
    ])

    try await store.prepare()
    try await store.createSession(
        SessionSnapshot(
            sessionID: "replay-integrity-session",
            status: .running
        ), events: [], effects: [])
    try await store.saveEffect(
        EffectRecord(
            sessionID: "replay-integrity-session",
            scope: .toolCall,
            key: call.id,
            effectType: definition.name,
            status: .completed,
            input: try JSONValue.encode(call),
            result: completionPayload
        )
    )

    let ledger = ToolEffectLedger(store: store, now: { Date(timeIntervalSince1970: 1) })
    await #expect(throws: AgentError.self) {
        _ = try await ledger.decision(
            for: call,
            definition: definition,
            sessionID: "replay-integrity-session"
        )
    }
}

@Test
func typedPreflightConflictCompletesFailedReceiptWithoutReconciliation() async throws {
    let tempRoot = makeEffectLedgerRuntimeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply a note update.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic
    )
    let call = ToolCall(id: "call-preflight", name: definition.name, arguments: .object([:]))
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "apply", toolCalls: [call]),
        ModelTurn(content: "handled")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [PreflightFailureToolPack(definition: definition)]
    )

    let snapshot = try await coordinator.startSession(
        sessionID: "preflight-conflict-session",
        userPrompt: "apply"
    )
    let effect = try #require(
        try await store.loadEffect(sessionID: snapshot.sessionID, scope: .toolCall, key: call.id)
    )
    let toolMessage = try #require(snapshot.messages.last(where: { $0.role == .tool }))
    let inspection = try await coordinator.inspectRecovery(sessionID: snapshot.sessionID)

    #expect(snapshot.status == .completed)
    #expect(effect.status == .failed)
    #expect(toolMessage.metadata["errorCode"]?.stringValue == ToolFailureCode.conflict.rawValue)
    #expect(toolMessage.metadata["effectCertainty"]?.stringValue == EffectFailureCertainty.definiteFailure.rawValue)
    #expect(inspection.requiresHostReconciliation == false)
    #expect(inspection.pendingToolEffects.isEmpty)
    #expect(await provider.callCount() == 2)
}
