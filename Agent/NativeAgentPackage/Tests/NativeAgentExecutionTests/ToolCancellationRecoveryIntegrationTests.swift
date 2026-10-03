import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private actor CancellationRecoveryExecutionState {
    private var invocations = 0
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspendAfterStarting() async throws -> ToolResult {
        invocations += 1
        started = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
        try await Task.sleep(for: .seconds(60))
        throw AgentError.invariantViolation("Cancellation recovery test executor unexpectedly resumed.")
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func invocationCount() -> Int { invocations }
}

private struct CancellationRecoveryToolPack: ToolPack {
    let packID = "toolpack.cancellation-recovery"
    let definition: ToolDefinition
    let state: CancellationRecoveryExecutionState

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { _, _ in
                try await state.suspendAfterStarting()
            }
        ]
    }
}

@Test
func cancellationAfterApprovedMutationStartsPreservesExplicitRecoveryState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NativeAgent-tool-cancellation-recovery-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "session-cancelled-mutation"
    let call = ToolCall(
        id: "call-cancelled-mutation",
        name: "notes.commit",
        arguments: .object(["content": .string("alpha")])
    )
    let definition = ToolDefinition(
        name: call.name,
        description: "Commit a durable note mutation.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string()],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval
    )
    let executionState = CancellationRecoveryExecutionState()
    let store = ApplicationSupportSessionStore(rootURL: root)
    let model = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "committing", toolCalls: [call]),
        ModelTurn(content: "recovery complete")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: model,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [
            CancellationRecoveryToolPack(
                definition: definition,
                state: executionState
            )
        ]
    )

    let task = Task {
        try await coordinator.startSession(
            sessionID: sessionID,
            userPrompt: "Commit the note."
        )
    }
    await executionState.waitUntilStarted()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }

    let interrupted = try await coordinator.loadSession(sessionID: sessionID)
    #expect(interrupted.status == .failed)
    #expect(interrupted.messages.contains { $0.role == .tool && $0.toolCallID == call.id } == false)
    #expect(await executionState.invocationCount() == 1)

    let effect = try #require(
        try await store.loadEffect(
            sessionID: sessionID,
            scope: .toolCall,
            key: call.id
        )
    )
    #expect(effect.status == .started)

    let inspection = try await coordinator.inspectRecovery(sessionID: sessionID)
    let pending = try #require(inspection.pendingToolEffects.first)
    #expect(inspection.requiresHostReconciliation)
    #expect(pending.call == call)
    #expect(pending.effectRecord?.status == .started)
    #expect(pending.disposition == .reconciliationRequired)

    let reconciled = try await coordinator.resolvePendingToolEffect(
        sessionID: sessionID,
        callID: call.id,
        resolution: .failed("Host could not verify whether the mutation completed.")
    )
    #expect(reconciled.status == .running)
    #expect(reconciled.messages.contains { message in
        message.role == .tool
            && message.toolCallID == call.id
            && message.metadata["effectReconciled"]?.boolValue == true
    })
    #expect(await executionState.invocationCount() == 1)

    let completed = try await coordinator.run(sessionID: sessionID)
    #expect(completed.status == .completed)
    #expect(completed.messages.last?.content == "recovery complete")
    #expect(await executionState.invocationCount() == 1)
    #expect(await model.callCount() == 2)
}
