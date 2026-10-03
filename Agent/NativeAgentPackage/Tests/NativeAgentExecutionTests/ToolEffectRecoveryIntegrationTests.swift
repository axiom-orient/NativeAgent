import Foundation
import NativeAgent
import NativeAgentMemory
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private actor RecoveryExecutionCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct RecoveryToolPack: ToolPack {
    let packID = "toolpack.recovery"
    let definition: ToolDefinition
    let counter: RecoveryExecutionCounter

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                await counter.increment()
                return .text(
                    callID: call.id,
                    toolName: call.name,
                    content: "executor must not run during reconciliation"
                )
            }
        ]
    }
}

private struct PlainUnknownToolError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private struct ThrowingMutationToolPack<Failure: Error & Sendable>: ToolPack {
    let packID = "toolpack.throwing-mutation"
    let definition: ToolDefinition
    let counter: RecoveryExecutionCounter
    let failure: Failure

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                await counter.increment()
                throw failure
            }
        ]
    }
}

private func recoveryTempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-effect-recovery-\(UUID().uuidString)", isDirectory: true)
}

private func recoveryDefinition(sensitive: Bool = false) -> ToolDefinition {
    ToolDefinition(
        name: "notes.commit",
        description: "Commit a note mutation.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval,
        metadata: sensitive ? ["sensitiveData": .bool(true)] : [:]
    )
}

private func makePendingRecoverySession(
    store: ApplicationSupportSessionStore,
    sessionID: String,
    call: ToolCall,
    effectStatus: EffectStatus,
    sessionStatus: SessionStatus = .running
) async throws {
    try await store.prepare()
    let failure = sessionStatus == .failed
        ? SessionFailure(
            code: "interrupted_effect",
            message: "process interrupted while the mutation outcome was unknown",
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        : nil
    let snapshot = SessionSnapshot(
        sessionID: sessionID,
        status: sessionStatus,
        messages: [
            AgentMessage(id: "user-1", role: .user, content: "commit note"),
            AgentMessage(
                id: "assistant-1",
                role: .assistant,
                content: "committing",
                toolCalls: [call]
            )
        ],
        failure: failure
    )
    try await store.createSession(snapshot, events: [], effects: [])
    let error = effectStatus == .failed ? "process interrupted after provider failure" : nil
    try await store.saveEffect(
        EffectRecord(
            sessionID: sessionID,
            scope: .toolCall,
            key: call.id,
            effectType: call.name,
            status: effectStatus,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            input: try JSONValue.encode(call),
            result: nil,
            error: error
        )
    )
}

@Test
func rejectedReconciliationDoesNotResumeFailedSession() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition()
    let call = ToolCall(id: "call-failed-state", name: definition.name, arguments: ["content": "delta"])
    try await makePendingRecoverySession(
        store: store,
        sessionID: "session-failed-state",
        call: call,
        effectStatus: .started,
        sessionStatus: .failed
    )
    let before = try #require(try await store.loadSnapshot(sessionID: "session-failed-state"))
    let coordinator = try makeRecoveryCoordinator(
        store: store,
        definition: definition,
        counter: RecoveryExecutionCounter(),
        provider: ScriptedModelClient()
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.resolvePendingToolEffect(
            sessionID: "session-failed-state",
            callID: call.id,
            resolution: .completed(
                .text(callID: "wrong-call", toolName: call.name, content: "invalid")
            )
        )
    }

    let after = try #require(try await store.loadSnapshot(sessionID: "session-failed-state"))
    #expect(after == before)
    #expect(after.status == .failed)
    #expect(after.failure?.code == "interrupted_effect")
}

@Test
func validReconciliationResumesFailedSessionAndPersistsResolutionTogether() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition()
    let call = ToolCall(id: "call-resume-failed", name: definition.name, arguments: ["content": "epsilon"])
    try await makePendingRecoverySession(
        store: store,
        sessionID: "session-resume-failed",
        call: call,
        effectStatus: .started,
        sessionStatus: .failed
    )
    let coordinator = try makeRecoveryCoordinator(
        store: store,
        definition: definition,
        counter: RecoveryExecutionCounter(),
        provider: ScriptedModelClient()
    )

    let resolved = try await coordinator.resolvePendingToolEffect(
        sessionID: "session-resume-failed",
        callID: call.id,
        resolution: .failed("host verified that the mutation did not commit")
    )

    #expect(resolved.status == .running)
    #expect(resolved.failure == nil)
    #expect(resolved.messages.last?.toolCallID == call.id)
    #expect(resolved.messages.last?.metadata["effectReconciled"]?.boolValue == true)
}

@Test
func pendingToolCallIndexRejectsConflictingReuseOfOneEffectIdentity() throws {
    let call = ToolCall(id: "duplicate-call", name: "notes.commit", arguments: ["content": "one"])
    let snapshot = SessionSnapshot(
        sessionID: "duplicate-pending",
        messages: [
            AgentMessage(id: "assistant-one", role: .assistant, content: "one", toolCalls: [call]),
            AgentMessage(
                id: "assistant-two",
                role: .assistant,
                content: "two",
                toolCalls: [ToolCall(id: call.id, name: call.name, arguments: ["content": "two"])]
            )
        ]
    )

    #expect(throws: AgentError.self) {
        _ = try PendingToolCallIndex.calls(in: snapshot)
    }
}

@Test
func reconciledSensitiveCompletionPreservesSensitivityAtDurableMessageBoundary() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition(sensitive: true)
    let call = ToolCall(id: "call-sensitive-complete", name: definition.name, arguments: ["content": "secret"])
    try await makePendingRecoverySession(
        store: store, sessionID: "session-sensitive-complete", call: call, effectStatus: .started
    )
    let coordinator = try makeRecoveryCoordinator(
        store: store, definition: definition, counter: RecoveryExecutionCounter(), provider: ScriptedModelClient()
    )

    let resolved = try await coordinator.resolvePendingToolEffect(
        sessionID: "session-sensitive-complete",
        callID: call.id,
        resolution: .completed(.text(callID: call.id, toolName: call.name, content: "private result"))
    )

    let message = try #require(resolved.messages.last(where: { $0.role == .tool }))
    #expect(message.metadata["sensitiveData"]?.boolValue == true)
    #expect(message.metadata["effectReconciled"]?.boolValue == true)
}

@Test
func reconciledSensitiveFailurePreservesSensitivityAtDurableMessageBoundary() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition(sensitive: true)
    let call = ToolCall(id: "call-sensitive-failed", name: definition.name, arguments: ["content": "secret"])
    try await makePendingRecoverySession(
        store: store, sessionID: "session-sensitive-failed", call: call, effectStatus: .started
    )
    let coordinator = try makeRecoveryCoordinator(
        store: store, definition: definition, counter: RecoveryExecutionCounter(), provider: ScriptedModelClient()
    )

    let resolved = try await coordinator.resolvePendingToolEffect(
        sessionID: "session-sensitive-failed",
        callID: call.id,
        resolution: .failed("host verified failure")
    )

    let message = try #require(resolved.messages.last(where: { $0.role == .tool }))
    #expect(message.metadata["sensitiveData"]?.boolValue == true)
    #expect(message.metadata["effectReconciled"]?.boolValue == true)
    #expect(message.metadata["isError"]?.boolValue == true)
}

private struct RecoveryTranscript: MemoryTranscriptSource {
    let snapshot: SessionSnapshot

    func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        try AgentJournalRecord(
            sessionID: snapshot.sessionID,
            revision: snapshot.revision,
            status: snapshot.status,
            updatedAt: snapshot.updatedAt,
            messageCount: snapshot.messages.count,
            artifactCount: snapshot.artifacts.count
        )
    }

    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage {
        SessionMessagePage(
            sessionID: snapshot.sessionID,
            offset: offset,
            totalCount: snapshot.messages.count,
            messages: Array(snapshot.messages.dropFirst(offset).prefix(limit))
        )
    }
}

@Test
func sensitiveReconciliationRemainsExcludedAfterTranscriptMemorySync() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root.appendingPathComponent("agent"))
    let definition = ToolDefinition(
        name: "notes.sensitiveUnknown",
        description: "Apply a sensitive mutation whose result may become uncertain.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .automatic,
        metadata: ["sensitiveData": .bool(true)]
    )
    let call = ToolCall(id: "call-sensitive-memory", name: definition.name, arguments: ["content": "private input"])
    let counter = RecoveryExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "committing private input", toolCalls: [call])
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            ThrowingMutationToolPack(
                definition: definition,
                counter: counter,
                failure: PlainUnknownToolError(message: "transport ended after sensitive mutation dispatch")
            )
        ],
        configuration: RuntimeConfiguration(safetyPolicy: .durable)
    )

    await #expect(throws: PlainUnknownToolError.self) {
        _ = try await coordinator.startSession(
            sessionID: "session-sensitive-memory",
            userPrompt: "perform sensitive mutation"
        )
    }
    let interrupted = try await coordinator.loadSession(sessionID: "session-sensitive-memory")
    let assistantBeforeRecovery = try #require(interrupted.messages.last(where: { $0.role == .assistant }))
    #expect(assistantBeforeRecovery.metadata["sensitiveData"]?.boolValue == true)

    let resolved = try await coordinator.resolvePendingToolEffect(
        sessionID: "session-sensitive-memory",
        callID: call.id,
        resolution: .completed(.text(callID: call.id, toolName: call.name, content: "private reconciled result"))
    )
    let toolMessage = try #require(resolved.messages.last(where: { $0.role == .tool }))
    #expect(toolMessage.metadata["sensitiveData"]?.boolValue == true)

    let memory = MemoryController(
        configuration: MemoryConfiguration(
            dataDirectory: root.appendingPathComponent("memory"),
            defaultProfileID: "profile",
            defaultUserID: "user",
            namespace: "shared"
        )
    )
    let scope = MemoryScope(profileID: "profile", userID: "user", sessionKey: resolved.sessionID, namespace: "shared")
    _ = try await memory.sync(
        scope: scope,
        sessionID: resolved.sessionID,
        from: RecoveryTranscript(snapshot: resolved)
    )

    #expect(try await memory.search(scope: scope, query: "private reconciled result").matches.isEmpty)
    #expect(try await memory.search(scope: scope, query: "private input").matches.isEmpty)
}

private func makeRecoveryCoordinator(
    store: ApplicationSupportSessionStore,
    definition: ToolDefinition,
    counter: RecoveryExecutionCounter,
    provider: ScriptedModelClient
) throws -> SessionCoordinator {
    try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [RecoveryToolPack(definition: definition, counter: counter)],
        configuration: RuntimeConfiguration(safetyPolicy: .durable)
    )
}

@Test
func recoveryInspectionExposesUncertainMutatingEffectWithoutExecutingIt() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition()
    let call = ToolCall(id: "call-inspect", name: definition.name, arguments: ["content": "alpha"])
    try await makePendingRecoverySession(
        store: store,
        sessionID: "session-inspect",
        call: call,
        effectStatus: .started
    )
    let counter = RecoveryExecutionCounter()
    let coordinator = try makeRecoveryCoordinator(
        store: store,
        definition: definition,
        counter: counter,
        provider: ScriptedModelClient()
    )

    let inspection = try await coordinator.inspectRecovery(sessionID: "session-inspect")
    let item = try #require(inspection.pendingToolEffects.first)

    #expect(inspection.requiresHostReconciliation)
    #expect(item.call == call)
    #expect(item.effectRecord?.status == .started)
    #expect(item.disposition == .reconciliationRequired)
    #expect(await counter.value() == 0)
}

@Test
func outcomeUnknownMutationKeepsStartedReceiptForHostReconciliation() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = ToolDefinition(
        name: "notes.unknown",
        description: "Apply a note mutation with an unconfirmed outcome.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .automatic
    )
    let call = ToolCall(
        id: "call-unknown",
        name: definition.name,
        arguments: ["content": "delta"]
    )
    let counter = RecoveryExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "committing", toolCalls: [call])
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            ThrowingMutationToolPack(
                definition: definition,
                counter: counter,
                failure: PlainUnknownToolError(
                    message: "transport ended after mutation dispatch for \(call.id)"
                )
            )
        ],
        configuration: RuntimeConfiguration(safetyPolicy: .durable)
    )

    await #expect(throws: PlainUnknownToolError.self) {
        _ = try await coordinator.startSession(
            sessionID: "session-unknown-tool",
            userPrompt: "commit note"
        )
    }

    let snapshot = try await coordinator.loadSession(sessionID: "session-unknown-tool")
    #expect(snapshot.status == .failed)
    #expect(snapshot.failure != nil)
    #expect(snapshot.messages.filter { $0.role == .tool }.isEmpty)
    #expect(await counter.value() == 1)
    let beforeRun = snapshot

    let inspection = try await coordinator.inspectRecovery(sessionID: snapshot.sessionID)
    let item = try #require(inspection.pendingToolEffects.first)
    #expect(inspection.requiresHostReconciliation)
    #expect(item.call == call)
    #expect(item.disposition == .reconciliationRequired)
    #expect(item.effectRecord?.status == .started)
    let modelCallsBeforeRun = await provider.callCount()

    let beforeContinue = snapshot
    await #expect(throws: AgentError.self) {
        _ = try await coordinator.continueSession(
            sessionID: snapshot.sessionID,
            userPrompt: "follow-up"
        )
    }
    let afterContinue = try await coordinator.loadSession(sessionID: snapshot.sessionID)
    #expect(afterContinue == beforeContinue)
    #expect(afterContinue.revision == beforeContinue.revision)
    #expect(afterContinue.status == .failed)
    #expect(afterContinue.messages.filter { $0.role == .tool }.isEmpty)
    #expect(await provider.callCount() == modelCallsBeforeRun)
    #expect(await counter.value() == 1)
    let afterContinueInspection = try await coordinator.inspectRecovery(
        sessionID: snapshot.sessionID
    )
    let afterContinueItem = try #require(afterContinueInspection.pendingToolEffects.first)
    #expect(afterContinueInspection.requiresHostReconciliation)
    #expect(afterContinueItem.effectRecord == item.effectRecord)
    #expect(afterContinueItem.disposition == .reconciliationRequired)

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.run(sessionID: snapshot.sessionID)
    }
    let afterRun = try await coordinator.loadSession(sessionID: snapshot.sessionID)
    #expect(afterRun == beforeRun)
    #expect(afterRun.revision == beforeRun.revision)
    #expect(afterRun.status == .failed)
    #expect(afterRun.messages.filter { $0.role == .tool }.isEmpty)
    #expect(await provider.callCount() == modelCallsBeforeRun)
    #expect(await counter.value() == 1)

    let afterInspection = try await coordinator.inspectRecovery(sessionID: snapshot.sessionID)
    let afterItem = try #require(afterInspection.pendingToolEffects.first)
    #expect(afterInspection.requiresHostReconciliation)
    #expect(afterItem.effectRecord?.status == .started)
}

@Test
func definiteMutationFailureKeepsTerminalToolFailureSemantics() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = ToolDefinition(
        name: "notes.definite",
        description: "Apply a definitely rejected note mutation.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .automatic
    )
    let call = ToolCall(
        id: "call-definite",
        name: definition.name,
        arguments: ["content": "epsilon"]
    )
    let counter = RecoveryExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "committing", toolCalls: [call]),
        ModelTurn(content: "handled rejection")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            ThrowingMutationToolPack(
                definition: definition,
                counter: counter,
                failure: EffectFailure.definiteFailure(
                    operation: "tool.execute",
                    cause: "validation rejected the mutation",
                    context: ["callID": call.id]
                )
            )
        ],
        configuration: RuntimeConfiguration(safetyPolicy: .durable)
    )

    let completed = try await coordinator.startSession(
        sessionID: "session-definite-tool",
        userPrompt: "commit note"
    )

    #expect(completed.status == .completed)
    #expect(completed.messages.contains { message in
        message.role == .tool
            && message.toolCallID == call.id
            && message.metadata["isError"]?.boolValue == true
            && message.content.contains("validation rejected")
    })
    #expect(await counter.value() == 1)
    let effect = try #require(try await store.loadEffect(
        sessionID: completed.sessionID,
        scope: .toolCall,
        key: call.id
    ))
    #expect(effect.status == .failed)
    #expect(effect.error?.contains("validation rejected") == true)
}

@Test
func hostVerifiedCompletionReconcilesEffectPersistsArtifactAndContinuesWithoutExecutor() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition()
    let call = ToolCall(id: "call-complete", name: definition.name, arguments: ["content": "alpha"])
    try await makePendingRecoverySession(
        store: store,
        sessionID: "session-complete",
        call: call,
        effectStatus: .started
    )
    let counter = RecoveryExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "recovery complete")
    ])
    let coordinator = try makeRecoveryCoordinator(
        store: store,
        definition: definition,
        counter: counter,
        provider: provider
    )

    let reconciled = try await coordinator.resolvePendingToolEffect(
        sessionID: "session-complete",
        callID: call.id,
        resolution: .completed(
            .text(
                callID: call.id,
                toolName: call.name,
                content: "host verified completion",
                artifacts: [
                    ArtifactWriteRequest(
                        preferredFilename: "reconciled.txt",
                        mimeType: "text/plain",
                        data: Data("verified artifact".utf8)
                    )
                ]
            )
        )
    )

    let toolMessage = try #require(reconciled.messages.last(where: { $0.role == .tool }))
    let effect = try #require(
        try await store.loadEffect(
            sessionID: "session-complete",
            scope: .toolCall,
            key: call.id
        )
    )
    #expect(toolMessage.content == "host verified completion")
    #expect(toolMessage.metadata["effectReconciled"]?.boolValue == true)
    #expect(reconciled.artifacts.count == 1)
    #expect(effect.status == .completed)
    #expect(effect.metadata["reconciled"]?.boolValue == true)
    #expect(effect.metadata["reconciliationOutcome"]?.stringValue == "completed")
    #expect(await counter.value() == 0)

    let artifactID = try #require(reconciled.artifacts.first?.id)
    let artifact = try await coordinator.loadArtifact(
        sessionID: "session-complete",
        artifactID: artifactID
    )
    #expect(String(decoding: artifact, as: UTF8.self) == "verified artifact")

    let completed = try await coordinator.run(sessionID: "session-complete")
    #expect(completed.status == .completed)
    #expect(completed.messages.last?.content == "recovery complete")
    #expect(await counter.value() == 0)
    #expect(await provider.callCount() == 1)
}

@Test
func hostVerifiedFailureTerminatesUncertainEffectAndContinuesWithoutExecutor() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition()
    let call = ToolCall(id: "call-failed", name: definition.name, arguments: ["content": "beta"])
    try await makePendingRecoverySession(
        store: store,
        sessionID: "session-failed",
        call: call,
        effectStatus: .failed
    )
    let counter = RecoveryExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "handled failure")
    ])
    let coordinator = try makeRecoveryCoordinator(
        store: store,
        definition: definition,
        counter: counter,
        provider: provider
    )

    let reconciled = try await coordinator.resolvePendingToolEffect(
        sessionID: "session-failed",
        callID: call.id,
        resolution: .failed("host verified that the mutation did not commit")
    )

    let toolMessage = try #require(reconciled.messages.last(where: { $0.role == .tool }))
    let effect = try #require(
        try await store.loadEffect(
            sessionID: "session-failed",
            scope: .toolCall,
            key: call.id
        )
    )
    #expect(toolMessage.metadata["isError"]?.boolValue == true)
    #expect(toolMessage.metadata["effectReconciled"]?.boolValue == true)
    #expect(toolMessage.content.contains("did not commit"))
    #expect(effect.status == .failed)
    #expect(effect.error?.contains("did not commit") == true)
    #expect(effect.metadata["reconciled"]?.boolValue == true)
    #expect(await counter.value() == 0)

    let completed = try await coordinator.run(sessionID: "session-failed")
    #expect(completed.status == .completed)
    #expect(completed.messages.last?.content == "handled failure")
    #expect(await counter.value() == 0)
}

@Test
func reconciliationRejectsMismatchedResultAndPreservesUncertainReceipt() async throws {
    let root = recoveryTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let definition = recoveryDefinition()
    let call = ToolCall(id: "call-mismatch", name: definition.name, arguments: ["content": "gamma"])
    try await makePendingRecoverySession(
        store: store,
        sessionID: "session-mismatch",
        call: call,
        effectStatus: .started
    )
    let counter = RecoveryExecutionCounter()
    let coordinator = try makeRecoveryCoordinator(
        store: store,
        definition: definition,
        counter: counter,
        provider: ScriptedModelClient()
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.resolvePendingToolEffect(
            sessionID: "session-mismatch",
            callID: call.id,
            resolution: .completed(
                .text(callID: "wrong-call", toolName: call.name, content: "invalid")
            )
        )
    }

    let snapshot = try await coordinator.loadSession(sessionID: "session-mismatch")
    let effect = try #require(
        try await store.loadEffect(
            sessionID: "session-mismatch",
            scope: .toolCall,
            key: call.id
        )
    )
    #expect(snapshot.messages.filter { $0.role == .tool }.isEmpty)
    #expect(snapshot.artifacts.isEmpty)
    #expect(effect.status == .started)
    #expect(await counter.value() == 0)
}
