import NativeAgentTestSupport
import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore

private func makeObserverTempRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
}

private actor ObserverExecutionCounter {
  private var count = 0

  func increment() -> Int {
    count += 1
    return count
  }

  func value() -> Int {
    count
  }
}

private actor RecordingRuntimeObserver: RuntimeObserver {
  private var modelStreamEvents: [ModelInvocationStreamEvent] = []
  private var decisionEvents: [ToolEffectDecisionEvent] = []
  private var durationEvents: [ToolExecutionDurationEvent] = []

  func record(modelStream event: ModelInvocationStreamEvent) async {
    modelStreamEvents.append(event)
  }

  func record(effectDecision event: ToolEffectDecisionEvent) async {
    decisionEvents.append(event)
  }

  func record(toolExecutionDuration event: ToolExecutionDurationEvent) async {
    durationEvents.append(event)
  }

  func decisions() -> [ToolEffectDecisionEvent] {
    decisionEvents
  }

  func modelEvents() -> [ModelInvocationStreamEvent] {
    modelStreamEvents
  }

  func durations() -> [ToolExecutionDurationEvent] {
    durationEvents
  }
}

private struct ObserverStreamingModelClient: ModelClient {
  let providerID = "provider.test.streaming"
  let events: [ModelEvent]

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request))
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

@Test
func runtimeObservesOrderedModelDeltasButPersistsOnlyTerminalTurn() async throws {
  let root = makeObserverTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: root)
  let observer = RecordingRuntimeObserver()
  let turn = ModelTurn(
    content: "hello", usage: .init(inputTokens: 1, outputTokens: 2, totalTokens: 3))
  let provider = ObserverStreamingModelClient(events: [
    .started(descriptor: nil),
    .textDelta("hel"),
    .textDelta("lo"),
    .usage(.init(inputTokens: 1, outputTokens: 2, totalTokens: 3)),
    .completed(turn),
  ])
  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    observer: observer
  )

  let snapshot = try await coordinator.startSession(userPrompt: "say hello")
  let events = await observer.modelEvents()
  let observedEvents = events.map(\.event)
  #expect(observedEvents.count == provider.events.count)
  guard case .started(let descriptor) = observedEvents.first else {
    Issue.record("Expected runtime-authoritative started event")
    return
  }
  #expect(descriptor?.id == "test-model")
  #expect(descriptor?.providerID == provider.providerID)
  #expect(Array(observedEvents.dropFirst()) == Array(provider.events.dropFirst()))
  #expect(snapshot.messages.map(\.content) == ["say hello", "hello"])
  #expect(snapshot.messages.filter { $0.role == .assistant }.count == 1)
}

private struct ObserverToolPack: ToolPack {
  let packID = "toolpack.observer"
  let definition: ToolDefinition
  let counter: ObserverExecutionCounter

  func executors() -> [any ToolExecutor] {
    [
      ClosureToolExecutor(definition: definition) { call, _ in
        let invocation = await counter.increment()
        return .text(
          callID: call.id,
          toolName: call.name,
          content: "run-\(invocation)"
        )
      }
    ]
  }
}

@Test
func runtimeObserverReceivesExecuteReplayAndDurationEvents() async throws {
  let tempRoot = makeObserverTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let counter = ObserverExecutionCounter()
  let observer = RecordingRuntimeObserver()
  let definition = ToolDefinition(
    name: "notes.apply",
    description: "Apply note updates.",
    capabilityID: .files,
    inputSchema: ToolSchema.object(
      properties: ["content": ToolSchema.string(description: "Content")],
      required: ["content"]
    ),
    approvalPolicy: .automatic
  )
  let repeatedCall = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(
      content: "first",
      toolCalls: [repeatedCall]
    ),
    ModelTurn(
      content: "second",
      toolCalls: [repeatedCall]
    ),
    ModelTurn(content: "done"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [ObserverToolPack(definition: definition, counter: counter)],
    observer: observer
  )

  _ = try await coordinator.startSession(userPrompt: "apply")
  let decisions = await observer.decisions()
  let durations = await observer.durations()

  #expect(await counter.value() == 1)
  #expect(decisions.map(\.decision) == [.execute, .replay])
  #expect(durations.count == 1)
  #expect(durations.first?.succeeded == true)
  #expect((durations.first?.durationSeconds ?? 0) >= 0)
}

@Test
func runtimeObserverWaitsForReconciliationBeforeRecordingEffectEvents() async throws {
  let tempRoot = makeObserverTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let counter = ObserverExecutionCounter()
  let observer = RecordingRuntimeObserver()
  let timestamp = Date(timeIntervalSince1970: 1_726_000_000)
  let definition = ToolDefinition(
    name: "notes.apply",
    description: "Apply note updates.",
    capabilityID: .files,
    inputSchema: ToolSchema.object(
      properties: ["content": ToolSchema.string(description: "Content")],
      required: ["content"]
    ),
    approvalPolicy: .automatic
  )
  let call = ToolCall(id: "call-1", name: definition.name, arguments: ["content": "alpha"])
  let startingSnapshot = SessionSnapshotTransitions.makeStartedSession(
    input: SessionStartInput(
      sessionID: "observer-session",
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
  let snapshot = startingSnapshot.applying(
    .appended(
      messages: [
        AgentMessage(
          id: "assistant-1",
          role: .assistant,
          content: "pending",
          createdAt: timestamp,
          toolCalls: [call]
        )
      ],
      artifacts: startingSnapshot.artifacts,
      updatedAt: timestamp
    ))
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
    toolPacks: [ObserverToolPack(definition: definition, counter: counter)],
    observer: observer
  )

  let providerCallsBeforeRun = await provider.callCount()
  await #expect(throws: AgentError.self) {
    _ = try await coordinator.run(sessionID: snapshot.sessionID)
  }
  let finalSnapshot = try #require(try await store.loadSnapshot(sessionID: snapshot.sessionID))
  let effect = try #require(
    try await store.loadEffect(
      sessionID: snapshot.sessionID,
      scope: .toolCall,
      key: call.id
    )
  )
  let inspection = try await coordinator.inspectRecovery(sessionID: snapshot.sessionID)
  let item = try #require(inspection.pendingToolEffects.first)
  let decisions = await observer.decisions()
  let durations = await observer.durations()

  #expect(finalSnapshot == snapshot)
  #expect(finalSnapshot.revision == snapshot.revision)
  #expect(finalSnapshot.messages == snapshot.messages)
  #expect(finalSnapshot.messages.contains(where: { $0.role == .tool }) == false)
  #expect(await counter.value() == 0)
  #expect(await provider.callCount() == providerCallsBeforeRun)
  #expect(effect.status == .started)
  #expect(inspection.requiresHostReconciliation)
  #expect(item.call == call)
  #expect(item.effectRecord?.status == .started)
  #expect(item.disposition == .reconciliationRequired)
  #expect(decisions.isEmpty)
  #expect(durations.isEmpty)
}
