import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeWaitResumeTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor WaitResumeCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private actor UnexpectedApprovalRouter: ApprovalRouter {
    private var requests: [ApprovalRequest] = []

    func resolve(request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return .denied(reason: "unexpected_reapproval")
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct WaitResumeToolPack: ToolPack {
    let packID = "toolpack.wait-resume"
    let definition: ToolDefinition
    let counter: WaitResumeCounter

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let invocation = await counter.increment()
                return .text(callID: call.id, toolName: call.name, content: "applied-\(invocation)")
            }
        ]
    }
}

private func makeRunningSnapshot(
    sessionID: String,
    timestamp: Date
) -> SessionSnapshot {
    SessionSnapshotTransitions.makeStartedSession(
        input: SessionStartInput(
            sessionID: sessionID,
            userPrompt: "seed",
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
}

private func waitReasons(_ events: [SessionEvent]) -> [String] {
    events.compactMap {
        guard $0.kind == .snapshotSaved else { return nil }
        return $0.payload.objectValue?["reason"]?.stringValue
    }
}

@Test
func signalWaitCanBeResumedWithUserPrompt() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_001_000)
    let snapshot = makeRunningSnapshot(sessionID: "signal-session", timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])

    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "done")
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let waitingSnapshot = try await coordinator.waitForSignal(
        sessionID: snapshot.sessionID,
        identifier: "sync.ready",
        details: ["source": .string("push")]
    )
    #expect(waitingSnapshot.status == .waiting)
    #expect(waitingSnapshot.waitState?.kind == .signal)

    let finalSnapshot = try await coordinator.resumeSignalWait(
        sessionID: snapshot.sessionID,
        identifier: "sync.ready",
        payload: .object(["revision": .integer(7)]),
        userPrompt: "signal received"
    )
    let reasons = waitReasons(try await store.loadEvents(sessionID: snapshot.sessionID))

    #expect(finalSnapshot.status == .completed)
    #expect(finalSnapshot.waitState == nil)
    #expect(finalSnapshot.messages.contains(where: { $0.role == .user && $0.content == "signal received" }))
    #expect(finalSnapshot.lastSignal?.identifier == "sync.ready")
    #expect(finalSnapshot.lastSignal?.payload.objectValue?["revision"]?.intValue == 7)
    #expect(reasons.contains("wait_entered"))
    #expect(reasons.contains("signal_received"))
    #expect(reasons.contains("wait_cleared") == false)

    let events = try await store.loadEvents(sessionID: snapshot.sessionID)
    #expect(events.contains(where: { $0.kind == .signalReceived }))
}

@Test
func dueTimeWaitClearsAutomaticallyOnRun() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_001_100)
    let snapshot = makeRunningSnapshot(sessionID: "time-session", timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])

    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "done")
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        now: { timestamp }
    )

    _ = try await coordinator.waitUntil(
        sessionID: snapshot.sessionID,
        resumeAt: timestamp.addingTimeInterval(-1),
        identifier: "timer.1"
    )

    let finalSnapshot = try await coordinator.run(sessionID: snapshot.sessionID)
    let reasons = waitReasons(try await store.loadEvents(sessionID: snapshot.sessionID))

    #expect(finalSnapshot.status == .completed)
    #expect(finalSnapshot.waitState == nil)
    #expect(reasons.contains("wait_entered"))
    #expect(reasons.contains("wait_cleared"))
}

@Test
func timeWaitCannotResumeBeforeDeadline() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_001_200)
    let snapshot = makeRunningSnapshot(sessionID: "time-not-ready", timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])

    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: []),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        now: { timestamp }
    )

    _ = try await coordinator.waitUntil(
        sessionID: snapshot.sessionID,
        resumeAt: timestamp.addingTimeInterval(60),
        identifier: "timer.future"
    )

    do {
        _ = try await coordinator.run(sessionID: snapshot.sessionID)
        Issue.record("Expected sessionWaiting before time wait deadline")
    } catch let error as AgentError {
        guard case .sessionWaiting(let sessionID) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(sessionID == snapshot.sessionID)
    }
}

@Test
func pendingApprovalCanBeResolvedAfterRestart() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = WaitResumeCounter()
    let timestamp = Date(timeIntervalSince1970: 1_726_001_300)
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
    let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
    let request = ApprovalRequest(
        id: "approval-1",
        sessionID: "approval-session",
        toolCall: call,
        definition: definition,
        createdAt: timestamp
    )
    let startingSnapshot = makeRunningSnapshot(sessionID: request.sessionID, timestamp: timestamp)
    let snapshot = startingSnapshot.applying(.appended(
        messages: [
        AgentMessage(
            id: "assistant-pending",
            role: .assistant,
            content: "needs approval",
            createdAt: timestamp,
            toolCalls: [call]
        )
        ],
        artifacts: startingSnapshot.artifacts,
        updatedAt: timestamp
    )).applying(.enteredWait(
        .approval(request: request, createdAt: request.createdAt),
        updatedAt: timestamp
    ))
    try await store.createSession(snapshot, events: [], effects: [])

    let router = UnexpectedApprovalRouter()
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "done")
        ]),
        approvalRouter: router,
        runtimeStore: store,
        toolPacks: [WaitResumeToolPack(definition: definition, counter: counter)]
    )

    let pendingRequest = try #require(try await coordinator.pendingApprovalRequest(sessionID: request.sessionID))
    #expect(pendingRequest.id == request.id)
    #expect(pendingRequest.toolCall == request.toolCall)

    do {
        _ = try await coordinator.resolvePendingApproval(
            sessionID: request.sessionID,
            requestID: "stale-approval",
            decision: .approved(reason: "must-not-apply")
        )
        Issue.record("Expected stale approval resolution to be rejected")
    } catch let error as AgentError {
        guard case .invariantViolation = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
    }
    #expect(await counter.value() == 0)
    #expect(try await coordinator.pendingApprovalRequest(sessionID: request.sessionID) == request)

    let finalSnapshot = try await coordinator.resolvePendingApproval(
        sessionID: request.sessionID,
        requestID: pendingRequest.id,
        decision: .approved(reason: "host-approved")
    )

    #expect(await counter.value() == 1)
    #expect(await router.requestCount() == 0)
    #expect(finalSnapshot.status == .completed)
    #expect(finalSnapshot.waitState == nil)
    #expect(finalSnapshot.messages.first(where: { $0.role == .tool })?.content == "applied-1")

    let approvalRecord = try #require(try await store.loadEffect(
        sessionID: request.sessionID,
        scope: .approval,
        key: call.id
    ))
    #expect(approvalRecord.status == .completed)
    #expect(approvalRecord.error == nil)

    let events = try await store.loadEvents(sessionID: request.sessionID)
    #expect(events.contains(where: { $0.kind == .approvalResolved }))
}

@Test
func pendingApprovalRequestFindsReferencedToolCallWithoutFlatteningTranscript() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_001_400)
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
    let targetCall = ToolCall(id: "call-target", name: definition.name, arguments: ["content": "beta"])
    let request = ApprovalRequest(
        id: "approval-2",
        sessionID: "approval-session-2",
        toolCall: targetCall,
        definition: definition,
        createdAt: timestamp
    )

    let startingSnapshot = makeRunningSnapshot(sessionID: request.sessionID, timestamp: timestamp)
    let withEarlierCall = startingSnapshot.applying(.appended(
        messages: [
        AgentMessage(
            id: "assistant-earlier",
            role: .assistant,
            content: "earlier calls",
            createdAt: timestamp,
            toolCalls: [
                ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"]),
                ToolCall(id: "call-2", name: definition.name, arguments: ["content": "gamma"])
            ]
        )
        ],
        artifacts: startingSnapshot.artifacts,
        updatedAt: timestamp
    ))
    let snapshot = withEarlierCall.applying(.appended(
        messages: [
        AgentMessage(
            id: "assistant-target",
            role: .assistant,
            content: "needs approval",
            createdAt: timestamp,
            toolCalls: [targetCall]
        )
        ],
        artifacts: withEarlierCall.artifacts,
        updatedAt: timestamp
    )).applying(.enteredWait(
        .approval(request: request, createdAt: request.createdAt),
        updatedAt: timestamp
    ))
    try await store.createSession(snapshot, events: [], effects: [])

    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: []),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [WaitResumeToolPack(definition: ToolDefinition(
            name: definition.name,
            description: definition.description,
            capabilityID: definition.capabilityID,
            inputSchema: definition.inputSchema,
            approvalPolicy: .automatic
        ), counter: WaitResumeCounter())]
    )

    let pendingRequest = try #require(try await coordinator.pendingApprovalRequest(sessionID: request.sessionID))
    #expect(pendingRequest.id == request.id)
    #expect(pendingRequest.toolCall == targetCall)
}

@Test
func pendingWaitCanBeTimedOutIntoStructuredDurableFailure() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_001_500)
    let snapshot = makeRunningSnapshot(sessionID: "timeout-session", timestamp: timestamp)
    try await store.createSession(snapshot, events: [], effects: [])

    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        now: { timestamp.addingTimeInterval(30) }
    )
    _ = try await coordinator.waitForSignal(
        sessionID: snapshot.sessionID,
        identifier: "remote.reply"
    )

    let failed = try await coordinator.timeoutWait(
        sessionID: snapshot.sessionID,
        identifier: "remote.reply",
        reason: "Remote reply deadline expired."
    )

    #expect(failed.status == .failed)
    #expect(failed.waitState == nil)
    #expect(failed.failure?.code == "wait_timed_out")
    #expect(failed.failure?.message == "Remote reply deadline expired.")
    #expect(failed.failure?.details["identifier"] == .string("remote.reply"))

    let reloaded = try #require(try await store.loadSnapshot(sessionID: snapshot.sessionID))
    #expect(reloaded == failed)
    let events = try await store.loadEvents(sessionID: snapshot.sessionID)
    #expect(events.contains(where: { $0.kind == .waitTimedOut }))
    #expect(events.contains(where: { $0.kind == .sessionFailed }))
    #expect(waitReasons(events).contains("wait_timed_out"))
}

@Test
func hostIssuedPendingApprovalResumesWithoutModelInvocation() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = WaitResumeCounter()
    let timestamp = Date(timeIntervalSince1970: 1_726_001_500)
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
    let call = ToolCall(id: "host-call-approval", name: definition.name, arguments: ["content": "alpha"])
    let request = ApprovalRequest(
        id: "host-approval",
        sessionID: "host-approval-session",
        toolCall: call,
        definition: definition,
        createdAt: timestamp
    )
    let startingSnapshot = makeRunningSnapshot(sessionID: request.sessionID, timestamp: timestamp)
    let waiting = startingSnapshot.applying(.appended(
        messages: [
            AgentMessage(
                id: "host-assistant-pending",
                role: .assistant,
                content: "",
                createdAt: timestamp,
                toolCalls: [call],
                metadata: ["hostIssuedToolCall": .bool(true)]
            )
        ],
        artifacts: startingSnapshot.artifacts,
        updatedAt: timestamp
    )).applying(.enteredWait(
        .approval(request: request, createdAt: request.createdAt),
        updatedAt: timestamp
    ))
    try await store.createSession(waiting, events: [], effects: [])

    let provider = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "must-not-run")])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: UnexpectedApprovalRouter(),
        runtimeStore: store,
        toolPacks: [WaitResumeToolPack(definition: definition, counter: counter)]
    )

    let finalSnapshot = try await coordinator.resolvePendingApproval(
        sessionID: request.sessionID,
        requestID: request.id,
        decision: .approved(reason: "host-approved")
    )

    #expect(await provider.callCount() == 0)
    #expect(await counter.value() == 1)
    #expect(finalSnapshot.status == .running)
    #expect(finalSnapshot.waitState == nil)
    #expect(finalSnapshot.messages.last(where: { $0.role == .tool })?.content == "applied-1")
}

@Test
func hostIssuedPendingApprovalDenialReturnsWithoutModelInvocation() async throws {
    let tempRoot = makeWaitResumeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let counter = WaitResumeCounter()
    let timestamp = Date(timeIntervalSince1970: 1_726_001_600)
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
    let call = ToolCall(id: "host-call-denied", name: definition.name, arguments: ["content": "alpha"])
    let request = ApprovalRequest(
        id: "host-approval-denied",
        sessionID: "host-approval-denied-session",
        toolCall: call,
        definition: definition,
        createdAt: timestamp
    )
    let startingSnapshot = makeRunningSnapshot(sessionID: request.sessionID, timestamp: timestamp)
    let waiting = startingSnapshot.applying(.appended(
        messages: [
            AgentMessage(
                id: "host-assistant-denied",
                role: .assistant,
                content: "",
                createdAt: timestamp,
                toolCalls: [call],
                metadata: ["hostIssuedToolCall": .bool(true)]
            )
        ],
        artifacts: startingSnapshot.artifacts,
        updatedAt: timestamp
    )).applying(.enteredWait(
        .approval(request: request, createdAt: request.createdAt),
        updatedAt: timestamp
    ))
    try await store.createSession(waiting, events: [], effects: [])

    let provider = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "must-not-run")])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: UnexpectedApprovalRouter(),
        runtimeStore: store,
        toolPacks: [WaitResumeToolPack(definition: definition, counter: counter)]
    )

    let finalSnapshot = try await coordinator.resolvePendingApproval(
        sessionID: request.sessionID,
        requestID: request.id,
        decision: .denied(reason: "host-denied")
    )

    #expect(await provider.callCount() == 0)
    #expect(await counter.value() == 0)
    #expect(finalSnapshot.status == .running)
    #expect(finalSnapshot.waitState == nil)
    let denial = try #require(finalSnapshot.messages.last(where: { $0.role == .tool }))
    #expect(denial.metadata["isError"]?.boolValue == true)
    #expect(denial.metadata["errorCode"]?.stringValue == ToolFailureCode.permissionDenied.rawValue)
}
