import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeMakiSemanticsTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor ToolExecutionCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor StartSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard started == false else { return }
        started = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilStarted() async {
        if started {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct LoopEchoToolPack: ToolPack {
    let packID = "loop-echo"
    let counter: ToolExecutionCounter

    func executors() -> [any ToolExecutor] {
        [LoopEchoExecutor(counter: counter)]
    }
}

private struct LoopEchoExecutor: ToolExecutor {
    let counter: ToolExecutionCounter

    var definition: ToolDefinition {
        ToolDefinition(
            name: "loop.echo",
            description: "Returns a stable response.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: ["value": ToolSchema.string()],
                required: ["value"]
            ),
            approvalPolicy: .automatic
        )
    }

    func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        await counter.increment()
        return .text(callID: call.id, toolName: call.name, content: "ok")
    }
}

private struct InterruptibleToolPack: ToolPack {
    let packID = "interrupt-pack"
    let startSignal: StartSignal

    func executors() -> [any ToolExecutor] {
        [FastExecutor(), SlowExecutor(startSignal: startSignal)]
    }
}

private struct FastExecutor: ToolExecutor {
    let definition = ToolDefinition(
        name: "interrupt.fast",
        description: "Completes immediately.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic,
        effect: .readOnly
    )

    func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        .text(callID: call.id, toolName: call.name, content: "fast")
    }
}

private struct SlowExecutor: ToolExecutor {
    let startSignal: StartSignal

    var definition: ToolDefinition {
        ToolDefinition(
            name: "interrupt.slow",
            description: "Waits until cancelled.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(properties: [:]),
            approvalPolicy: .automatic,
            effect: .readOnly
        )
    }

    func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        await startSignal.markStarted()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return .text(callID: call.id, toolName: call.name, content: "slow")
    }
}

@Test
func repeatedIdenticalToolCallIsAllowedForANewUserTurn() async throws {
    let tempRoot = makeMakiSemanticsTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = ToolExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "first",
            toolCalls: [ToolCall(id: "call-1", name: "loop.echo", arguments: ["value": "same"]) ]
        ),
        ModelTurn(
            content: "second",
            toolCalls: [ToolCall(id: "call-2", name: "loop.echo", arguments: ["value": "same"]) ]
        ),
        ModelTurn(content: "done-1"),
        ModelTurn(
            content: "third",
            toolCalls: [ToolCall(id: "call-3", name: "loop.echo", arguments: ["value": "same"]) ]
        ),
        ModelTurn(content: "done-2")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [LoopEchoToolPack(counter: counter)]
    )

    let firstSnapshot = try await coordinator.startSession(userPrompt: "run first")
    #expect(firstSnapshot.status == .completed)

    let secondSnapshot = try await coordinator.continueSession(sessionID: firstSnapshot.sessionID, userPrompt: "run again")
    let executedMessage = try #require(secondSnapshot.messages.last { $0.toolCallID == "call-3" })

    #expect(secondSnapshot.status == .completed)
    #expect(await counter.value() == 3)
    #expect(executedMessage.role == .tool)
    #expect(executedMessage.metadata["isError"]?.boolValue == false)
    #expect(executedMessage.content == "ok")
}

@Test
func repeatedIdenticalToolCallWithNoNewResultIsRejectedWithinOneUserTurn() async throws {
    let tempRoot = makeMakiSemanticsTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = ToolExecutionCounter()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "first",
            toolCalls: [ToolCall(id: "call-1", name: "loop.echo", arguments: ["value": "same"]) ]
        ),
        ModelTurn(
            content: "second",
            toolCalls: [ToolCall(id: "call-2", name: "loop.echo", arguments: ["value": "same"]) ]
        ),
        ModelTurn(
            content: "third",
            toolCalls: [ToolCall(id: "call-3", name: "loop.echo", arguments: ["value": "same"]) ]
        ),
        ModelTurn(content: "changed course")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [LoopEchoToolPack(counter: counter)]
    )
    let snapshot = try await coordinator.startSession(userPrompt: "look up once")
    let blocked = try #require(snapshot.messages.last { $0.toolCallID == "call-3" })

    #expect(snapshot.status == .completed)
    #expect(snapshot.messages.last?.content == "changed course")
    #expect(await counter.value() == 2)
    #expect(blocked.metadata["isError"]?.boolValue == true)
    #expect(blocked.content == ToolCallLoopGuard.repeatedCallMessage)
}

@Test
func cancellationRepairsDanglingToolCallTranscript() async throws {
    let tempRoot = makeMakiSemanticsTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let signal = StartSignal()
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "run tools",
            toolCalls: [
                ToolCall(id: "call-fast", name: "interrupt.fast", arguments: [:]),
                ToolCall(id: "call-slow", name: "interrupt.slow", arguments: [:])
            ]
        )
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [InterruptibleToolPack(startSignal: signal)],
        idGenerator: { "session-interrupted" }
    )

    let task = Task {
        try await coordinator.startSession(userPrompt: "run interruptible tools")
    }

    await signal.waitUntilStarted()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }

    let snapshot = try await coordinator.loadSession(sessionID: "session-interrupted")
    let repairedMessage = try #require(snapshot.messages.last { $0.toolCallID == "call-slow" })
    let completedMessage = try #require(snapshot.messages.last { $0.toolCallID == "call-fast" })

    #expect(snapshot.status == .failed)
    #expect(completedMessage.metadata["isError"]?.boolValue == false)
    #expect(repairedMessage.role == .tool)
    #expect(repairedMessage.metadata["isError"]?.boolValue == true)
    #expect(repairedMessage.content == TranscriptRepair.interruptedToolMessage)
}
