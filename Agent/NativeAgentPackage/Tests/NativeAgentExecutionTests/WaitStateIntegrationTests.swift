import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeWaitStateTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func waitSnapshotSaveReasons(_ events: [SessionEvent]) -> [String] {
    events.compactMap { event in
        guard event.kind == .snapshotSaved else {
            return nil
        }
        return event.payload.objectValue?["reason"]?.stringValue
    }
}

private enum WaitStateTestError: Error {
    case timedOut
}

private func waitWithin<T: Sendable>(
    _ timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw WaitStateTestError.timedOut
        }
        guard let result = try await group.next() else {
            throw WaitStateTestError.timedOut
        }
        group.cancelAll()
        return result
    }
}

private actor ManualApprovalRouter: ApprovalRouter {
    private var requestStorage: ApprovalRequest?
    private var requestWaiters: [UUID: CheckedContinuation<ApprovalRequest, any Error>] = [:]
    private var decisionContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var pendingDecision: ApprovalDecision?

    func resolve(request: ApprovalRequest) async -> ApprovalDecision {
        requestStorage = request
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.values.forEach { $0.resume(returning: request) }
        if let pendingDecision {
            self.pendingDecision = nil
            return pendingDecision
        }
        return await withCheckedContinuation { continuation in
            decisionContinuation = continuation
        }
    }

    func nextRequest() async throws -> ApprovalRequest {
        if let requestStorage {
            return requestStorage
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let requestStorage {
                    continuation.resume(returning: requestStorage)
                } else {
                    requestWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRequestWaiter(id: waiterID) }
        }
    }

    func approve(reason: String? = nil) {
        resolveDecision(.approved(reason: reason))
    }

    func deny(reason: String? = nil) {
        resolveDecision(.denied(reason: reason))
    }

    func cancelPending() {
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        if let decisionContinuation {
            self.decisionContinuation = nil
            decisionContinuation.resume(returning: .denied(reason: "test cleanup"))
        }
        pendingDecision = nil
    }

    private func cancelRequestWaiter(id: UUID) {
        guard let continuation = requestWaiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resolveDecision(_ decision: ApprovalDecision) {
        guard let decisionContinuation else {
            pendingDecision = decision
            return
        }
        decisionContinuation.resume(returning: decision)
        self.decisionContinuation = nil
    }
}

private struct ApprovalWaitToolPack: ToolPack {
    let packID = "toolpack.approval-wait"
    let definition: ToolDefinition

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                .text(callID: call.id, toolName: call.name, content: "applied")
            }
        ]
    }
}

@Test
func approvalWaitStateIsPersistedAndClearedAfterResolution() async throws {
    let tempRoot = makeWaitStateTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let router = ManualApprovalRouter()
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval
    )
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "need approval",
            toolCalls: [ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])]
        ),
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: router,
        runtimeStore: store,
        toolPacks: [ApprovalWaitToolPack(definition: definition)]
    )

    let sessionTask = Task {
        try await coordinator.startSession(userPrompt: "apply")
    }
    defer { Task { await router.cancelPending() } }

    let request = try await waitWithin { try await router.nextRequest() }

    let waitingSnapshot = try await coordinator.loadSession(sessionID: request.sessionID)
    let waitState = try #require(waitingSnapshot.waitState)
    #expect(waitingSnapshot.status == .waiting)
    #expect(waitState.kind == .approval)
    #expect(waitState.identifier == request.id)
    #expect(waitState.details["toolCallID"]?.stringValue == "call-1")
    #expect(waitState.details["toolName"]?.stringValue == definition.name)

    let waitingEvents = try await store.loadEvents(sessionID: request.sessionID)
    let waitingReasons = waitSnapshotSaveReasons(waitingEvents)
    #expect(waitingReasons.contains("wait_entered"))
    let waitEnteredEvent = try #require(waitingEvents.last(where: {
        $0.kind == .snapshotSaved && $0.payload.objectValue?["reason"]?.stringValue == "wait_entered"
    }))
    #expect(waitEnteredEvent.payload.objectValue?["status"]?.stringValue == SessionStatus.waiting.rawValue)
    #expect(waitEnteredEvent.payload.objectValue?["waitState"]?.objectValue?["kind"]?.stringValue == SessionWaitKind.approval.rawValue)

    await router.approve(reason: "approved")
    let finalSnapshot = try await waitWithin { try await sessionTask.value }
    #expect(finalSnapshot.status == .completed)
    #expect(finalSnapshot.waitState == nil)

    let finalEvents = try await store.loadEvents(sessionID: request.sessionID)
    let finalReasons = waitSnapshotSaveReasons(finalEvents)
    #expect(finalReasons.contains("wait_cleared"))
    let waitClearedIndex = try #require(finalReasons.firstIndex(of: "wait_cleared"))
    let toolResultIndex = try #require(finalReasons.firstIndex(of: "tool_result_appended"))
    #expect(waitClearedIndex < toolResultIndex)
}

@Test
func continueSessionDoesNotMutateActiveWaitingSession() async throws {
    let tempRoot = makeWaitStateTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let router = ManualApprovalRouter()
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval
    )
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "need approval",
            toolCalls: [ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])]
        ),
        ModelTurn(content: "done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: router,
        runtimeStore: store,
        toolPacks: [ApprovalWaitToolPack(definition: definition)]
    )

    let sessionTask = Task {
        try await coordinator.startSession(userPrompt: "apply")
    }
    defer { Task { await router.cancelPending() } }

    let request = try await waitWithin { try await router.nextRequest() }

    do {
        _ = try await coordinator.continueSession(sessionID: request.sessionID, userPrompt: "second")
        Issue.record("Expected sessionBusy while approval wait is active")
    } catch let error as AgentError {
        guard case .sessionBusy(let sessionID) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            await router.approve(reason: "test cleanup")
            _ = try await waitWithin { try await sessionTask.value }
            return
        }
        #expect(sessionID == request.sessionID)
    }

    let waitingSnapshot = try await coordinator.loadSession(sessionID: request.sessionID)
    #expect(waitingSnapshot.messages.contains(where: { $0.role == .user && $0.content == "second" }) == false)

    await router.approve(reason: "approved")
    _ = try await waitWithin { try await sessionTask.value }
}

@Test
func waitingSnapshotCannotBeRunFromFreshCoordinator() async throws {
    let tempRoot = makeWaitStateTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let router = ManualApprovalRouter()
    let definition = ToolDefinition(
        name: "notes.apply",
        description: "Apply note updates.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["content": ToolSchema.string(description: "Content")],
            required: ["content"]
        ),
        approvalPolicy: .requireApproval
    )
    let blockingProvider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "need approval",
            toolCalls: [ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])]
        ),
        ModelTurn(content: "done")
    ])
    let firstCoordinator = try SessionCoordinator(
        modelClient: blockingProvider,
        approvalRouter: router,
        runtimeStore: store,
        toolPacks: [ApprovalWaitToolPack(definition: definition)]
    )

    let sessionTask = Task {
        try await firstCoordinator.startSession(userPrompt: "apply")
    }
    defer { Task { await router.cancelPending() } }

    let request = try await waitWithin { try await router.nextRequest() }

    let secondCoordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [ApprovalWaitToolPack(definition: definition)]
    )

    do {
        _ = try await secondCoordinator.run(sessionID: request.sessionID)
        Issue.record("Expected waiting snapshot run to fail")
    } catch let error as AgentError {
        guard case .sessionBusy(let sessionID) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            await router.approve(reason: "test cleanup")
            _ = try await waitWithin { try await sessionTask.value }
            return
        }
        #expect(sessionID == request.sessionID)
    }

    await router.approve(reason: "approved")
    _ = try await waitWithin { try await sessionTask.value }
}
