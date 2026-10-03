import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@Suite("Descriptor / executor / reuse boundary")
struct LanguageModelExecutionTests {
  @Test func sameConfigurationReusesOneAdmissionSlot() async throws {
    let probe = ExecutorProbe()
    let model = FixtureModel(configuration: .init(probe: probe, behavior: .wait))
    let store = ModelExecutorStore()
    let first = try await store.runtime(for: model)
    let second = try await store.runtime(for: model)
    #expect(first === second)
    let run = try await first.start(request())
    try await eventually { await probe.responses == 1 }
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await second.start(request()) }
    await probe.release()
    #expect(try await collect(run).last == .completed(ModelTurn(content: "ok")))
    try await store.shutdown()
    #expect(await probe.shutdowns == 1)
  }

  @Test func differentConfigurationsAndExecutorTypesAreIsolated() async throws {
    let probe = ExecutorProbe()
    let store = ModelExecutorStore()
    let configuration = FixtureConfiguration(probe: probe)
    let first = try await store.runtime(for: FixtureModel(configuration: configuration))
    let otherConfig = try await store.runtime(
      for: FixtureModel(configuration: .init(probe: probe, key: 2)))
    let otherType = try await store.runtime(for: OtherFixtureModel(configuration: configuration))
    #expect(first !== otherConfig)
    #expect(first !== otherType)
    try await store.shutdown()
    #expect(await probe.shutdowns == 3)
  }

  @Test func sameConfigurationCannotChangeAuthoritativeDescriptor() async throws {
    let store = ModelExecutorStore()
    let configuration = FixtureConfiguration(probe: ExecutorProbe())
    _ = try await store.runtime(for: FixtureModel(configuration: configuration))
    await #expect(throws: ModelRuntimeFailure.self) {
      _ = try await store.runtime(for: FixtureModel(configuration: configuration, modelID: "other"))
    }
    try await store.shutdown()
  }

  @Test func capabilitiesAreRejectedBeforeExecutorEntry() async throws {
    let probe = ExecutorProbe()
    let runtime = try makeRuntime(probe)
    let invalid = ModelRequest(
      sessionID: "s", messages: [.init(role: .user, content: "hi")],
      tools: [], requiredCapabilities: .imageInput)
    await #expect(throws: ModelGenerationFailure.self) { _ = try await runtime.start(invalid) }
    #expect(await probe.responses == 0)
    try await runtime.shutdown()
  }

  @Test func executorCompletionWaitsForSettlement() async throws {
    let probe = ExecutorProbe()
    let runtime = try makeRuntime(probe, .wait)
    let run = try await runtime.start(request())
    try await eventually { await probe.responses == 1 }
    #expect(await runtime.status().phase == .running)
    await probe.release()
    #expect(try await collect(run).last == .completed(ModelTurn(content: "ok")))
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func cancellationDoesNotPublishLateCompleted() async throws {
    let probe = ExecutorProbe()
    let runtime = try makeRuntime(probe, .wait)
    let run = try await runtime.start(request())
    try await eventually { await probe.responses == 1 }
    let cancellation = Task { await run.cancel() }
    try await eventually { await runtime.status().phase == .draining }
    await probe.release()
    await cancellation.value
    do {
      _ = try await collect(run)
      Issue.record("Late success escaped cancellation")
    } catch let error as ModelGenerationFailure { #expect(error.code == .cancelled) }
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func trailingErrorAndDuplicateTerminalNeverBecomeSuccess() async throws {
    for behavior in [FixtureBehavior.trailingError, .duplicate] {
      let runtime = try makeRuntime(ExecutorProbe(), behavior)
      let run = try await runtime.start(request())
      await #expect(throws: (any Error).self) { _ = try await collect(run) }
      #expect(await runtime.status().phase == .idle)
      try await runtime.shutdown()
    }
  }

  @Test func unprovedDrainQuarantinesAndDoesNotShutdownExecutor() async throws {
    let probe = ExecutorProbe()
    let runtime = try makeRuntime(probe, .drainFailure)
    let run = try await runtime.start(request())
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await collect(run) }
    #expect(await runtime.status().failure?.code == .nativeDrainFailed)
    await #expect(throws: ModelRuntimeFailure.self) { try await runtime.shutdown() }
    #expect(await probe.shutdowns == 0)
  }

  @Test func shutdownIsIdempotentAndRejectsNewEntries() async throws {
    let probe = ExecutorProbe()
    let model = FixtureModel(configuration: .init(probe: probe))
    let store = ModelExecutorStore()
    _ = try await store.runtime(for: model)
    async let one: Void = store.shutdown()
    async let two: Void = store.shutdown()
    _ = try await (one, two)
    try await store.shutdown()
    #expect(await probe.shutdowns == 1)
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await store.runtime(for: model) }
  }

  @Test func failedShutdownStillAttemptsIndependentEntries() async throws {
    let failed = ExecutorProbe(failShutdown: true)
    let good = ExecutorProbe()
    let store = ModelExecutorStore()
    _ = try await store.runtime(for: FixtureModel(configuration: .init(probe: failed)))
    _ = try await store.runtime(for: FixtureModel(configuration: .init(probe: good)))
    await #expect(throws: ModelRuntimeFailure.self) { try await store.shutdown() }
    #expect(await failed.shutdowns == 1)
    #expect(await good.shutdowns == 1)
    await #expect(throws: ModelRuntimeFailure.self) { try await store.shutdown() }
    #expect(await failed.shutdowns == 1)
  }

  @Test func clientBindingCopiesReuseButSeparateAccountsDoNotAlias() async throws {
    let store = ModelExecutorStore()
    let first = try ClientLanguageModel(client: ExistingClient())
    let second = try ClientLanguageModel(client: ExistingClient())
    #expect(first.executorConfiguration != second.executorConfiguration)
    let one = try await store.runtime(for: first)
    let copy = try await store.runtime(for: first)
    let separate = try await store.runtime(for: second)
    #expect(one === copy)
    #expect(one !== separate)
    #expect(try await one.generate(request()).content == "ok")
    try await store.shutdown()
  }

  @Test func clientModelRejectsDescriptorOverrideAndStandaloneSemantics() throws {
    #expect(throws: ModelGenerationFailure.self) {
      _ = try ClientLanguageModel(
        client: ExistingClient(),
        descriptor:
          ModelDescriptor(id: "other", providerID: "fixture", capabilities: .textOnly))
    }
    #expect(throws: ModelGenerationFailure.self) {
      _ = try ClientLanguageModel(client: ExistingClient(standalone: true))
    }
  }
}

// Contract fixtures only. These do not claim vendor inference or Apple SDK qualification.
private enum FixtureBehavior: Hashable, Sendable {
  case success, wait, trailingError, duplicate, drainFailure
}
private struct FixtureConfiguration: Hashable, Sendable {
  let probe: ExecutorProbe
  var key: Int = 1
  var behavior: FixtureBehavior = .success
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.probe === rhs.probe && lhs.key == rhs.key && lhs.behavior == rhs.behavior
  }
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(probe))
    hasher.combine(key)
    hasher.combine(behavior)
  }
}
private struct FixtureModel: LanguageModel {
  let configuration: FixtureConfiguration
  var modelID = "fixture.model"
  var descriptor: ModelDescriptor {
    .init(id: modelID, providerID: "fixture", capabilities: .textOnly)
  }
  var executorConfiguration: FixtureConfiguration { configuration }
  struct Executor: LanguageModelExecutor {
    typealias Model = FixtureModel
    let configuration: FixtureConfiguration
    func respond(
      to request: ModelRequest, model: Model, streamingInto channel: ModelGenerationChannel
    ) async throws {
      try await configuration.probe.respond(behavior: configuration.behavior, channel: channel)
    }
    func shutdown() async throws { try await configuration.probe.shutdown() }
  }
}
private struct OtherFixtureModel: LanguageModel {
  let configuration: FixtureConfiguration
  var descriptor: ModelDescriptor {
    .init(id: "fixture.model", providerID: "fixture", capabilities: .textOnly)
  }
  var executorConfiguration: FixtureConfiguration { configuration }
  struct Executor: LanguageModelExecutor {
    typealias Model = OtherFixtureModel
    let configuration: FixtureConfiguration
    func respond(
      to request: ModelRequest, model: Model, streamingInto channel: ModelGenerationChannel
    ) async throws {
      try await configuration.probe.respond(behavior: configuration.behavior, channel: channel)
    }
    func shutdown() async throws { try await configuration.probe.shutdown() }
  }
}
private actor ExecutorProbe {
  private(set) var responses = 0
  private(set) var shutdowns = 0
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  let failShutdown: Bool
  init(failShutdown: Bool = false) { self.failShutdown = failShutdown }
  func respond(behavior: FixtureBehavior, channel: ModelGenerationChannel) async throws {
    try channel.send(.started(descriptor: nil))
    try channel.send(.textDelta("ok"))
    try channel.send(.completed(ModelTurn(content: "ok")))
    responses += 1
    if behavior == .wait && !released { await withCheckedContinuation { waiters.append($0) } }
    if behavior == .trailingError {
      throw ModelGenerationFailure(.transportFailure, "trailing failure")
    }
    if behavior == .duplicate { try channel.send(.completed(ModelTurn(content: "ok"))) }
    if behavior == .drainFailure { throw ModelExecutorDrainFailure("fixture native drain failure") }
  }
  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
  func shutdown() throws {
    shutdowns += 1
    if failShutdown { throw ModelGenerationFailure(.transportFailure, "fixture release failure") }
  }
}
private struct ExistingClient: ModelClient {
  var standalone = false
  let providerID = "fixture"
  var invocationSemantics: ModelClientInvocationSemantics {
    standalone ? .standaloneOnly : .exactRequest
  }
  var modelDescriptor: ModelDescriptor? {
    .init(id: "fixture.model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn { ModelTurn(content: "ok") }
}
private func makeRuntime(_ probe: ExecutorProbe, _ behavior: FixtureBehavior = .success) throws
  -> ModelRuntime
{
  try ModelRuntime(
    id: .init(rawValue: "fixture.runtime"),
    model: FixtureModel(configuration: .init(probe: probe, behavior: behavior)))
}
private func request() -> ModelRequest {
  ModelRequest(
    sessionID: "fixture.session", messages: [.init(role: .user, content: "hi")], tools: [])
}
private func collect(_ run: ModelRun) async throws -> [ModelEvent] {
  var events: [ModelEvent] = []
  for try await event in run.events { events.append(event) }
  return events
}
private func eventually(_ predicate: () async -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while !(await predicate()) {
    guard ContinuousClock.now < deadline else { throw FixtureTimeout.expired }
    try await Task.sleep(for: .milliseconds(1))
  }
}
private enum FixtureTimeout: Error { case expired }
