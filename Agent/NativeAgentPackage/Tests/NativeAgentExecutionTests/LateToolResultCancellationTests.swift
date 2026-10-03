import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

/// A real file effect is complete before cancellation; the gate only controls result delivery.
private actor LateToolResultGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var invocationCount = 0

    func didWriteAndWait() async {
        invocationCount += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { completion = $0 }
    }

    func waitForWrite() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        completion?.resume()
        completion = nil
    }
}

private struct LateToolResultPack: ToolPack {
    let packID = "late-result-pack"
    let executor: ClosureToolExecutor
    func executors() -> [any ToolExecutor] { [executor] }
}

@Test(.timeLimit(.minutes(1)))
func cancellationPreservesKnownLateToolResultAndArtifact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NativeAgent-late-result-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let effectURL = root.appendingPathComponent("external-effect.txt")
    let bytes = Data("committed before cancellation".utf8)
    let gate = LateToolResultGate()
    let call = ToolCall(id: "late-file-commit", name: "files.commit", arguments: .object([:]))
    let definition = ToolDefinition(
        name: call.name, description: "Write one file and publish its exact bytes.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:], required: []),
        approvalPolicy: .requireApproval)
    let executor = ClosureToolExecutor(definition: definition) { invocation, _ in
        try bytes.write(to: effectURL, options: .atomic)
        await gate.didWriteAndWait()
        return ToolResult(
            callID: invocation.id, toolName: invocation.name,
            output: .object(["written": .bool(true)]),
            artifacts: [ArtifactWriteRequest(
                preferredFilename: "receipt.txt", mimeType: "text/plain", data: bytes)])
    }
    let store = ApplicationSupportSessionStore(rootURL: root.appendingPathComponent("sessions"))
    let model = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "write", toolCalls: [call])])
    let coordinator = try SessionCoordinator(
        modelClient: model, approvalRouter: AllowAllApprovalRouter(), runtimeStore: store,
        toolPacks: [LateToolResultPack(executor: executor)])
    let task = Task {
        try await coordinator.startSession(sessionID: "late-result", userPrompt: "Write the file.")
    }
    await gate.waitForWrite()
    #expect(try Data(contentsOf: effectURL) == bytes)
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    let snapshot = try await coordinator.loadSession(sessionID: "late-result")
    #expect(snapshot.status == .failed) // Run cancelled; the already-known effect is not erased.
    #expect(snapshot.messages.contains { $0.role == .tool && $0.toolCallID == call.id })
    #expect(snapshot.artifacts.count == 1)
    let effect = try #require(try await store.loadEffect(
        sessionID: "late-result", scope: .toolCall, key: call.id))
    #expect(effect.status == .completed)
    let inspection = try await coordinator.inspectRecovery(sessionID: "late-result")
    #expect(inspection.pendingToolEffects.isEmpty)

    // Reopen the real store and read artifact bytes, not only its in-memory reference count.
    let reopened = ApplicationSupportSessionStore(rootURL: root.appendingPathComponent("sessions"))
    try await reopened.prepare()
    let restored = try #require(try await reopened.loadSnapshot(sessionID: "late-result"))
    #expect(restored.artifacts == snapshot.artifacts)
    let artifact = try #require(restored.artifacts.first)
    #expect(try await reopened.loadArtifact(sessionID: "late-result", artifactID: artifact.id) == bytes)
    let restoredEffect = try #require(try await reopened.loadEffect(
        sessionID: "late-result", scope: .toolCall, key: call.id))
    #expect(restoredEffect.status == .completed)
    #expect(await gate.invocationCount == 1)
    #expect(await model.callCount() == 1) // Cancellation must not dispatch another model request.
    #expect(try Data(contentsOf: effectURL) == bytes)
}
