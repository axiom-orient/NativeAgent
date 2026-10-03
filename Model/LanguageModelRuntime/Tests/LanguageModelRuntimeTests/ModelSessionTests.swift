import Foundation
import LanguageModelCore
import Testing

@testable import LanguageModelRuntime

@Suite("Conversation authority and façade lifecycle")
struct ModelSessionTests {
  @Test func settledResponsesCommitAndSubsequentRequestsReuseHistory() async throws {
    let probe = SessionProbe()
    let runtime = try makeSessionRuntime(probe)
    let session = ModelSession(id: "conversation", runtime: .borrowed(runtime))
    #expect(try await session.respond(to: [user("one")]).content == "ok")
    #expect(try await session.respond(to: [user("two")]).content == "ok")
    #expect(await session.transcript.count == 4)
    #expect(await probe.requests.map(\.messages.count) == [1, 3])
    #expect(await session.transcript[1].metadata == ["source": .string("fixture")])
    try await session.close()
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func failedResponseDoesNotCommitPendingInput() async throws {
    let runtime = try makeSessionRuntime(SessionProbe(fail: true))
    let session = ModelSession(id: "conversation", runtime: .owned(runtime))
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await session.respond(to: [user("one")])
    }
    #expect(await session.transcript.isEmpty)
    #expect(await session.status == .ready)
    try await session.close()
  }

  @Test func concurrentPromptIsRejectedWithoutCorruptingTranscript() async throws {
    let probe = SessionProbe(wait: true)
    let runtime = try makeSessionRuntime(probe)
    let session = ModelSession(id: "conversation", runtime: .borrowed(runtime))
    let first = Task { try await session.respond(to: [user("one")]) }
    try await untilSession { await probe.requests.count == 1 }
    await #expect(throws: ModelRuntimeFailure.self) {
      _ = try await session.respond(to: [user("two")])
    }
    #expect(await session.transcript.isEmpty)
    await probe.release()
    _ = try await first.value
    #expect(await session.transcript.map(\.content) == ["one", "ok"])
    try await session.close()
    try await runtime.shutdown()
  }

  @Test func cancelledPromptDrainsAndNeverCommitsLateResponse() async throws {
    let probe = SessionProbe(wait: true)
    let runtime = try makeSessionRuntime(probe)
    let session = ModelSession(id: "conversation", runtime: .owned(runtime))
    let first = Task { try await session.respond(to: [user("one")]) }
    try await untilSession { await probe.requests.count == 1 }
    first.cancel()
    try await untilSession { await runtime.status().phase == .draining }
    #expect(await session.status == .generating)
    await probe.release()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    #expect(await session.transcript.isEmpty)
    #expect(await session.status == .ready)
    try await session.close()
  }

  @Test func closingIdleBorrowerNeverCancelsAnotherConversation() async throws {
    let probe = SessionProbe(wait: true)
    let runtime = try makeSessionRuntime(probe)
    let first = ModelSession(id: "first", runtime: .borrowed(runtime))
    let idle = ModelSession(id: "idle", runtime: .borrowed(runtime))
    let response = Task { try await first.respond(to: [user("one")]) }
    try await untilSession { await probe.requests.count == 1 }
    try await idle.close()
    #expect(await runtime.status().phase == .running)
    await probe.release()
    #expect(try await response.value.content == "ok")
    try await first.close()
    try await runtime.shutdown()
  }

  @Test func closeRejectsNewPromptsAndWaitsForItsGeneration() async throws {
    let probe = SessionProbe(wait: true)
    let runtime = try makeSessionRuntime(probe)
    let session = ModelSession(id: "conversation", runtime: .owned(runtime))
    let response = Task { try await session.respond(to: [user("one")]) }
    try await untilSession { await probe.requests.count == 1 }
    let close = Task { try await session.close() }
    try await untilSession { await session.status == .closing }
    await #expect(throws: ModelRuntimeFailure.self) {
      _ = try await session.respond(to: [user("two")])
    }
    close.cancel()  // A waiter does not own the teardown task.
    await probe.release()
    await #expect(throws: CancellationError.self) { _ = try await response.value }
    try await close.value
    try await session.close()
    #expect(await session.status == .closed)
    #expect(await session.transcript.isEmpty)
    #expect(await runtime.status().phase == .closed)
  }

  @Test func streamTerminalImpliesCommittedHistory() async throws {
    let runtime = try makeSessionRuntime(SessionProbe())
    let session = ModelSession(id: "conversation", runtime: .owned(runtime))
    let stream = try await session.stream(to: [user("one")])
    var terminals = 0
    for try await event in stream {
      if case .completed = event {
        terminals += 1
        #expect(await session.transcript.count == 2)
        #expect(await runtime.status().phase == .idle)
      }
    }
    #expect(terminals == 1)
    try await session.close()
  }

  @Test func invalidInputDoesNotStartTaskOrMutateHistory() async throws {
    let probe = SessionProbe()
    let runtime = try makeSessionRuntime(probe)
    let session = ModelSession(id: "conversation", runtime: .borrowed(runtime))
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await session.respond(to: [user("one")], maxOutputBytes: 0)
    }
    #expect(await session.status == .ready)
    #expect(await probe.requests.isEmpty)
    #expect(await session.transcript.isEmpty)
    try await session.close()
    try await runtime.shutdown()
  }

  @Test func pureReducerIgnoresStaleSuccessAndPreservesFullTurn() throws {
    var state = SessionLedger(transcript: [])
    state = try SessionLedger.reduce(state: state, event: .begin([user("one")])).0
    state = try SessionLedger.reduce(state: state, event: .failed(1)).0
    state = try SessionLedger.reduce(state: state, event: .begin([user("two")])).0
    let (unchanged, ignored) = try SessionLedger.reduce(
      state: state,
      event: .succeeded(1, ModelTurn(content: "late")))
    #expect(unchanged.transcript.isEmpty)
    guard case .discarded = ignored else {
      Issue.record("Stale success accepted")
      return
    }
    let turn = ModelTurn(content: "ok", metadata: ["evidence": .string("ref")])
    state = try SessionLedger.reduce(state: unchanged, event: .succeeded(2, turn)).0
    #expect(state.transcript.map(\.content) == ["two", "ok"])
    #expect(state.transcript.last?.contentParts == turn.contentParts)
    #expect(state.transcript.last?.metadata == turn.metadata)
  }

  @Test func pureReducerPreventsGenerationOverflowAndClosedCommit() throws {
    var exhausted = SessionLedger(transcript: [], generation: UInt64.max)
    #expect(throws: ModelRuntimeFailure.self) {
      _ = try SessionLedger.reduce(state: exhausted, event: .begin([user("one")]))
    }
    exhausted = SessionLedger(transcript: [])
    exhausted = try SessionLedger.reduce(state: exhausted, event: .begin([user("one")])).0
    exhausted = try SessionLedger.reduce(state: exhausted, event: .close).0
    let (closed, effect) = try SessionLedger.reduce(
      state: exhausted,
      event: .succeeded(1, ModelTurn(content: "late")))
    #expect(closed.transcript.isEmpty)
    guard case .discarded = effect else {
      Issue.record("Closed commit accepted")
      return
    }
  }

  @Test func resumedTranscriptNeverCollidesWithGeneratedResponseIdentity() throws {
    var state = SessionLedger(transcript: [
      .init(id: "model-response-1", role: .user, content: "history"),
      .init(id: "model-response-1-1", role: .assistant, content: "old answer"),
    ])
    state = try SessionLedger.reduce(
      state: state,
      event: .begin([.init(id: "model-response-1-2", role: .user, content: "new")])
    ).0
    state = try SessionLedger.reduce(
      state: state, event: .succeeded(1, ModelTurn(content: "reply"))
    ).0
    #expect(Set(state.transcript.map(\.id)).count == state.transcript.count)
    #expect(state.transcript.last?.id == "model-response-1-3")
    #expect(state.transcript.first?.id == "model-response-1")
  }

  @Test func cancelledUnprovedDrainRemainsFailureNotSuccessfulBorrowedClose() async throws {
    let drain = FailingSessionDrain()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "failed.drain"),
      model: ClientLanguageModel(client: FailingDrainClient(drain: drain)))
    let session = ModelSession(id: "conversation", runtime: .borrowed(runtime))
    let response = Task { try await session.respond(to: [user("one")]) }
    try await untilSession { await drain.joining }
    let close = Task { try await session.close() }
    try await untilSession { await session.status == .closing }
    await drain.release()
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await response.value }
    await #expect(throws: ModelRuntimeFailure.self) { try await close.value }
    await #expect(throws: ModelRuntimeFailure.self) { try await session.close() }
    #expect(await session.transcript.isEmpty)
  }
}

private actor SessionProbe {
  private(set) var requests: [ModelRequest] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  let wait: Bool
  let fail: Bool
  init(wait: Bool = false, fail: Bool = false) {
    self.wait = wait
    self.fail = fail
  }
  func respond(_ request: ModelRequest) async throws -> ModelTurn {
    requests.append(request)
    if wait && !released { await withCheckedContinuation { waiters.append($0) } }
    if fail { throw ModelGenerationFailure(.transportFailure, "fixture failure") }
    return ModelTurn(content: "ok", metadata: ["source": .string("fixture")])
  }
  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
private struct SessionClient: ModelClient {
  let probe: SessionProbe
  let providerID = "fixture"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await probe.respond(request)
  }
}
private func makeSessionRuntime(_ probe: SessionProbe) throws -> ModelRuntime {
  try ModelRuntime(
    id: .init(rawValue: "session.runtime"),
    model: ClientLanguageModel(client: SessionClient(probe: probe)))
}
private func user(_ text: String) -> AgentMessage { .init(role: .user, content: text) }
private func untilSession(_ predicate: () async -> Bool) async throws {
  let end = ContinuousClock.now.advanced(by: .seconds(3))
  while !(await predicate()) {
    guard ContinuousClock.now < end else { throw SessionTestTimeout.expired }
    try await Task.sleep(for: .milliseconds(1))
  }
}
private enum SessionTestTimeout: Error { case expired }
private actor FailingSessionDrain {
  private(set) var joining = false
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func join() async throws {
    joining = true
    if !opened { await withCheckedContinuation { waiters.append($0) } }
    throw ModelExecutorDrainFailure("Fixture cannot prove native drain")
  }
  func release() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
private struct FailingDrainClient: ModelClientWithOwnedInvocation {
  let drain: FailingSessionDrain
  let providerID = "fixture"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    throw ModelGenerationFailure(.invalidRequest, "Fixture requires owned invocation")
  }
  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void)
    -> ModelClientInvocation
  {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    onStarted()
    pair.continuation.yield(.started(descriptor: modelDescriptor))
    pair.continuation.yield(.completed(ModelTurn(content: "ok")))
    pair.continuation.finish()
    return .init(events: pair.stream, cancel: {}, waitForCompletion: { try await drain.join() })
  }
}
