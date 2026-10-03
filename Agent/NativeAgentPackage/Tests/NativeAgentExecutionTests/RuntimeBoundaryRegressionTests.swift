import Foundation
import NativeAgentTestSupport
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore

private func makeRuntimeBoundaryTempRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "native-agent-runtime-boundary-\(UUID().uuidString)",
    isDirectory: true
  )
}

private actor RuntimeContentionModelClient: ModelClient {
  nonisolated let providerID = "provider.runtime-contention"
  nonisolated let modelDescriptor: ModelDescriptor? = ModelDescriptor(
    id: "runtime-contention-model",
    providerID: "provider.runtime-contention",
    capabilities: .allKnown,
    contextWindowTokens: 1_000_000
  )

  private var invocationCount = 0
  private var firstInvocationStarted = false
  private var firstInvocationReleased = false
  private var firstInvocationRelease: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func generate(request: ModelRequest) async throws -> ModelTurn {
    invocationCount += 1
    if invocationCount == 1 {
      firstInvocationStarted = true
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      if firstInvocationReleased == false {
        await withCheckedContinuation { continuation in
          firstInvocationRelease = continuation
        }
      }
    }
    return ModelTurn(content: "done-\(request.sessionID)")
  }

  func waitUntilFirstInvocationStarts() async {
    if firstInvocationStarted { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstInvocation() {
    firstInvocationReleased = true
    firstInvocationRelease?.resume()
    firstInvocationRelease = nil
  }

  func calls() -> Int { invocationCount }
}

private struct RuntimeBoundaryToolPack: ToolPack {
  let packID = "toolpack.runtime-boundary"
  let definition: ToolDefinition

  func executors() -> [any ToolExecutor] {
    [
      ClosureToolExecutor(definition: definition) { call, _ in
        .text(callID: call.id, toolName: call.name, content: "unexpected")
      }
    ]
  }
}

@Test
func modelRuntimeContentionDoesNotPoisonAnotherSession() async throws {
  let tempRoot = makeRuntimeBoundaryTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = RuntimeContentionModelClient()
  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: []
  )

  let first = Task {
    try await coordinator.startSession(
      sessionID: "runtime-contention-a",
      userPrompt: "first"
    )
  }
  await provider.waitUntilFirstInvocationStarts()
  defer { Task { await provider.releaseFirstInvocation() } }

  var secondError: (any Error)?
  do {
    _ = try await coordinator.startSession(
      sessionID: "runtime-contention-b",
      userPrompt: "second"
    )
  } catch {
    secondError = error
  }

  await provider.releaseFirstInvocation()
  let firstSnapshot = try await first.value
  #expect(firstSnapshot.status == .completed)

  guard let secondError else {
    Issue.record("A second session unexpectedly entered an occupied model runtime.")
    return
  }
  guard case AgentError.sessionBusy(let sessionID) = secondError else {
    Issue.record("Runtime contention crossed the Agent boundary as \(secondError).")
    return
  }
  #expect(sessionID == "runtime-contention-b")

  let preserved = try await coordinator.loadSession(sessionID: "runtime-contention-b")
  #expect(preserved.status == .running)
  let preservedPrompt = preserved.messages.contains(where: {
    $0.role == .user && $0.content == "second"
  })
  #expect(preservedPrompt)

  let resumed = try await coordinator.run(sessionID: "runtime-contention-b")
  #expect(resumed.status == .completed)
  #expect(await provider.calls() == 2)
}

@Test
func modelInvocationWaitRevisionRejectsLegacyFloatingPointEncoding() {
  let exact = SessionWaitState(
    kind: .modelInvocation,
    identifier: "exact",
    details: ["snapshotRevision": .integer(9)]
  )
  let legacy = SessionWaitState(
    kind: .modelInvocation,
    identifier: "legacy",
    details: ["snapshotRevision": .number(9)]
  )

  #expect(SessionCoordinator.waitStateSnapshotRevision(exact) == 9)
  #expect(SessionCoordinator.waitStateSnapshotRevision(legacy) == nil)
}

@Test
func deniedApprovalUsesCanonicalPersistenceClock() async throws {
  let sourceTimestamp = Date(timeIntervalSince1970: 1_067_557_142.463_554_4)
  let expectedTimestamp = PersistedTimestamp.canonicalizing(sourceTimestamp)
  let tempRoot = makeRuntimeBoundaryTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let definition = ToolDefinition(
    name: "notes.apply",
    description: "Apply a note update.",
    capabilityID: .files,
    inputSchema: ToolSchema.object(
      properties: ["content": ToolSchema.string(description: "Content")],
      required: ["content"]
    ),
    approvalPolicy: .requireApproval
  )
  let call = ToolCall(
    id: "clock-call",
    name: definition.name,
    arguments: ["content": "alpha"]
  )
  let request = ApprovalRequest(
    id: "clock-approval",
    sessionID: "clock-session",
    toolCall: call,
    definition: definition,
    createdAt: expectedTimestamp
  )
  let started = SessionSnapshotTransitions.makeStartedSession(
    input: SessionStartInput(
      sessionID: request.sessionID,
      userPrompt: "apply",
      systemPrompt: nil,
      title: nil,
      modelID: "test-model",
      metadata: [:],
      requestMetadata: [:],
      providerID: "provider.test.scripted",
      timestamp: expectedTimestamp
    ),
    idGenerator: { "clock-user" }
  )
  let withCall = started.applying(
    .appended(
      messages: [
        AgentMessage(
          id: "clock-assistant",
          role: .assistant,
          content: "needs approval",
          createdAt: expectedTimestamp,
          toolCalls: [call]
        )
      ],
      artifacts: started.artifacts,
      updatedAt: expectedTimestamp
    )
  )
  let waiting = withCall.applying(
    .enteredWait(
      .approval(request: request, createdAt: request.createdAt),
      updatedAt: expectedTimestamp
    )
  )
  try await store.createSession(waiting, events: [], effects: [])

  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(scriptedTurns: [ModelTurn(content: "done")]),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [RuntimeBoundaryToolPack(definition: definition)],
    now: { sourceTimestamp },
    idGenerator: { UUID().uuidString }
  )

  let returned = try await coordinator.resolvePendingApproval(
    sessionID: request.sessionID,
    requestID: request.id,
    decision: .denied(reason: "host-denied")
  )
  let reloaded = try await coordinator.loadSession(sessionID: request.sessionID)
  let deniedMessage = try #require(
    returned.messages.first(where: {
      $0.role == .tool && $0.toolCallID == call.id
    })
  )

  #expect(returned == reloaded)
  #expect(deniedMessage.createdAt == expectedTimestamp)
  #expect(returned.updatedAt == expectedTimestamp)
}
