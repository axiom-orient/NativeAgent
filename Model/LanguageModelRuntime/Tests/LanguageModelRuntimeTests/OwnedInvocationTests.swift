import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@Suite("Provider producer and native drain ownership")
struct OwnedInvocationTests {
  @Test(arguments: [false, true]) func bufferedStartCannotBeMisreportedAsNoEffectAfterCancellation(
    throughModel: Bool
  ) async throws {
    let started = CancellationSignal()
    let client = StartSignalFixture(started: started)
    let runtime =
      throughModel
      ? try ModelRuntime(
        id: .init(rawValue: "buffered.start"), model: ClientLanguageModel(client: client))
      : try ModelRuntime(id: .init(rawValue: "buffered.start"), client: client)
    let run = try await runtime.start(request())
    try await until { started.count == 1 }
    #expect(run.effectState == .started)
    await run.cancel()
    #expect(run.effectState == .started)
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test(arguments: [false, true]) func cleanEOFCannotPublishCompletionOrIdleBeforeNativeDrain(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe()
    let runtime = try runtime(native, throughModel: throughModel)
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    #expect(await runtime.status().phase == .running)
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await runtime.start(request()) }
    await native.release()
    #expect(try await collect(run).last == .completed(ModelTurn(content: "ok")))
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test(arguments: [false, true]) func cancellationSignalsOwnedProducerAndJoinsNativeDrain(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe()
    let signal = CancellationSignal()
    let runtime = try runtime(native, throughModel: throughModel, signal: signal)
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    let cancellation = Task { await run.cancel() }
    try await until { signal.count > 0 }
    #expect(await runtime.status().phase == .draining)
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await runtime.reserve(request()) }
    await native.release()
    await cancellation.value
    do {
      _ = try await collect(run)
      Issue.record("Cancelled success escaped")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .cancelled) }
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test(arguments: [false, true]) func drainFailureQuarantinesAndNeverRunsCleanup(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe(failFirstJoin: true)
    let cleanup = CancellationSignal()
    let runtime = try runtime(native, throughModel: throughModel, cleanup: { cleanup.increment() })
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    await native.release()
    do {
      _ = try await collect(run)
      Issue.record("Drain failure became success")
    } catch let failure as ModelRuntimeFailure { #expect(failure.code == .nativeDrainFailed) }
    #expect(await runtime.status().phase == .failed)
    #expect(await native.joinCount == 1)  // No retry turns failed proof into success.
    await #expect(throws: ModelRuntimeFailure.self) { try await runtime.shutdown() }
    #expect(cleanup.count == 0)
  }

  @Test(arguments: [false, true])
  func shutdownDuringFailedDrainDoesNotMistakeFinishedPumpForSafeRelease(throughModel: Bool)
    async throws
  {
    let native = DrainProbe(failFirstJoin: true)
    let cleanup = CancellationSignal()
    let runtime = try runtime(native, throughModel: throughModel, cleanup: { cleanup.increment() })
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    let close = Task { try await runtime.shutdown() }
    try await until { await runtime.status().phase == .closing }
    await native.release()
    await #expect(throws: ModelRuntimeFailure.self) { try await close.value }
    do {
      _ = try await collect(run)
      Issue.record("Shutdown cancellation escaped")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .cancelled) }
    #expect(await runtime.status().failure?.code == .nativeDrainFailed)
    #expect(cleanup.count == 0)
    #expect(await runtime.status().phase == .failed)
  }

  @Test(arguments: [false, true]) func malformedStreamStillDrainsBeforeReleasingAdmission(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe()
    let signal = CancellationSignal()
    let runtime = try runtime(native, throughModel: throughModel, signal: signal, malformed: true)
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    // The executor may begin joining EOF before the runtime consumer validates
    // its buffered malformed event. Observe cancellation independently; joining
    // is not proof that the consumer has already requested cancellation.
    try await until { signal.count > 0 }
    #expect(signal.count > 0)
    #expect(await runtime.status().phase == .running)
    await native.release()
    do {
      _ = try await collect(run)
      Issue.record("Malformed stream accepted")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .malformedEvent) }
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test(arguments: [false, true]) func failedDrainAfterMalformedStreamQuarantines(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe(failFirstJoin: true)
    let runtime = try runtime(native, throughModel: throughModel, malformed: true)
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    await native.release()
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await collect(run) }
    #expect(await runtime.status().failure?.code == .nativeDrainFailed)
  }

  @Test(arguments: [false, true]) func deadlineCannotExposeBufferedLateSuccessWhileDrainIsPending(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe()
    let signal = CancellationSignal()
    let runtime = try runtime(native, throughModel: throughModel, signal: signal)
    let run = try await runtime.start(request(deadline: .milliseconds(30)))
    try await until { await runtime.status().drainReason == .deadlineExceeded }
    #expect(signal.count > 0)
    await native.release()
    do {
      _ = try await collect(run)
      Issue.record("Late success escaped deadline")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .deadlineExceeded) }
    #expect(await runtime.status().phase == .idle)
  }

  @Test(arguments: [false, true]) func shutdownTimeoutRetainsResidentEvenAfterLateDrain(
    throughModel: Bool
  ) async throws {
    let native = DrainProbe()
    let cleanup = CancellationSignal()
    let policy = try ModelRuntimePolicy(
      shutdownDrainTimeout: .milliseconds(30), drainPollInterval: .milliseconds(1))
    let runtime = try runtime(
      native, throughModel: throughModel, policy: policy, cleanup: { cleanup.increment() })
    let run = try await runtime.start(request())
    try await until { await native.isJoining }
    do {
      try await runtime.shutdown()
      Issue.record("Drain timeout was ignored")
    } catch let failure as ModelRuntimeFailure { #expect(failure.code == .shutdownDrainTimedOut) }
    #expect(cleanup.count == 0)
    await native.release()
    await run.cancel()
    #expect(await runtime.status().phase == .failed)
    await #expect(throws: ModelRuntimeFailure.self) { try await runtime.shutdown() }
    #expect(cleanup.count == 0)
  }
}

// These fixtures exercise the REAL runtime state machine, not vendor inference.
private actor DrainProbe {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var opened = false
  private let failFirstJoin: Bool
  private(set) var joinCount = 0
  var isJoining: Bool { joinCount > 0 }
  init(failFirstJoin: Bool = false) { self.failFirstJoin = failFirstJoin }
  func join() async throws {
    joinCount += 1
    let attempt = joinCount
    if !opened { await withCheckedContinuation { waiters.append($0) } }
    if failFirstJoin && attempt == 1 { throw DrainTestError.nativeFailure }
  }
  func release() {
    opened = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}
private final class CancellationSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}
private enum DrainTestError: Error { case nativeFailure, timeout }
private struct OwnedClient: ModelClientWithOwnedInvocation {
  let native: DrainProbe
  let signal: CancellationSignal
  let malformed: Bool
  let providerID = "test.owned"
  var modelDescriptor: ModelDescriptor? {
    ModelDescriptor(id: "test.model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    throw DrainTestError.nativeFailure  // Runtime must use the owned invocation port.
  }
  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }
  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void)
    -> ModelClientInvocation
  {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    if !malformed {
      pair.continuation.yield(.started(descriptor: modelDescriptor))
      onStarted()
    }
    pair.continuation.yield(.textDelta("ok"))
    pair.continuation.yield(.completed(ModelTurn(content: "ok")))
    pair.continuation.finish()
    return ModelClientInvocation(
      events: pair.stream, cancel: { signal.increment() },
      waitForCompletion: { try await native.join() })
  }
}
private func runtime(
  _ native: DrainProbe, throughModel: Bool, signal: CancellationSignal = CancellationSignal(),
  malformed: Bool = false, policy: ModelRuntimePolicy = .default,
  cleanup: @escaping @Sendable () async throws -> Void = {}
) throws -> ModelRuntime {
  let client = OwnedClient(native: native, signal: signal, malformed: malformed)
  if throughModel {
    return try ModelRuntime(
      id: .init(rawValue: "test.runtime"),
      model: ClientLanguageModel(client: client), policy: policy, cleanup: cleanup)
  }
  return try ModelRuntime(
    id: .init(rawValue: "test.runtime"),
    client: client, policy: policy, cleanup: cleanup)
}
private func request(deadline: Duration = .seconds(5)) -> ModelRequest {
  ModelRequest(
    sessionID: "test.session", messages: [.init(role: .user, content: "hello")],
    tools: [], deadline: deadline)
}
private func collect(_ run: ModelRun) async throws -> [ModelEvent] {
  var events: [ModelEvent] = []
  for try await event in run.events { events.append(event) }
  return events
}
private func until(_ condition: @escaping @Sendable () async -> Bool) async throws {
  let clock = ContinuousClock()
  let end = clock.now.advanced(by: .seconds(3))
  while !(await condition()) {
    guard clock.now < end else { throw DrainTestError.timeout }
    try await Task.sleep(for: .milliseconds(1))
  }
}

private struct StartSignalFixture: ModelClientWithOwnedInvocation {
  let started: CancellationSignal
  let providerID = "test.signal"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    throw DrainTestError.nativeFailure
  }
  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void)
    -> ModelClientInvocation
  {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    // The producer has crossed its start boundary; its .started event has not
    // reached the consumer. Cancellation cannot assert that nothing started.
    onStarted()
    started.increment()
    return .init(
      events: pair.stream,
      cancel: { pair.continuation.finish(throwing: CancellationError()) },
      waitForCompletion: {})
  }
}
