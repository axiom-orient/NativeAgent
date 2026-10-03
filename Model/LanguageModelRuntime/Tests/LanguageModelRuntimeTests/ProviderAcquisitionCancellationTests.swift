import LanguageModelCore
import Testing

@testable import LanguageModelRuntime

@Suite("Provider discovery and acquisition cancellation")
struct ProviderAcquisitionCancellationTests {
  @Test func cancelledBeforeEntryDoesNotCallTheConnector() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe)
    let registry = try ModelProviderRegistry([connector(runtime, probe: probe)])
    let task = Task {
      await gate.pause()
      return try await registry.acquireRuntime(selection())
    }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    await expectCancellation(task)
    #expect(await probe.availabilityCount == 0)
    #expect(await probe.acquireCount == 0)
    try await runtime.shutdown()
  }

  @Test func cancelledAvailabilityDoesNotStartAcquisition() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe)
    let registry = try ModelProviderRegistry([
      connector(runtime, probe: probe, availabilityGate: gate)
    ])
    let task = Task { try await registry.acquireRuntime(selection()) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    await expectCancellation(task)
    #expect(await probe.acquireCount == 0)
    try await runtime.shutdown()
  }

  @Test func cancelledOwnedAcquisitionReleasesTheLateRuntime() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe)
    let registry = try ModelProviderRegistry([
      connector(runtime, probe: probe, acquireGate: gate)
    ])
    let task = Task { try await registry.acquireRuntime(selection()) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    await expectCancellation(task)
    #expect(await runtime.status().phase == .closed)
    #expect(await probe.cleanupCount == 1)
    try await runtime.shutdown()
  }

  @Test func cancelledBorrowedAcquisitionDoesNotCloseTheHostRuntime() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe)
    let registry = try ModelProviderRegistry([
      connector(runtime, probe: probe, acquireGate: gate, borrowed: true)
    ])
    let task = Task { try await registry.acquireRuntime(selection()) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    await expectCancellation(task)
    #expect(await runtime.status().phase == .idle)
    #expect(await probe.cleanupCount == 0)
    try await runtime.shutdown()
  }

  @Test func cancelledAcquisitionDoesNotHideCleanupFailure() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe, cleanupFails: true)
    let registry = try ModelProviderRegistry([
      connector(runtime, probe: probe, acquireGate: gate)
    ])
    let task = Task { try await registry.acquireRuntime(selection()) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    do {
      _ = try await task.value
      Issue.record("Cancelled acquisition returned a runtime whose release fails")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .cleanupFailed)
    } catch { Issue.record("Cleanup failure was hidden: \(error)") }
    #expect(await runtime.status().phase == .failed)
    #expect(await probe.cleanupCount == 1)
  }

  @Test func cancelledCatalogDoesNotPublishLateModels() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe)
    let registry = try ModelProviderRegistry([
      connector(runtime, probe: probe, modelsGate: gate)
    ])
    let task = Task { try await registry.models(providerID: runtime.providerID) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    do {
      _ = try await task.value
      Issue.record("Cancelled catalog lookup returned success")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    try await runtime.shutdown()
  }

  @Test func cancelledReadinessDoesNotPublishLateAvailability() async throws {
    let gate = AcquisitionGate()
    let probe = AcquisitionProbe()
    let runtime = try fixtureRuntime(probe)
    let registry = try ModelProviderRegistry([
      connector(runtime, probe: probe, availabilityGate: gate)
    ])
    let task = Task { try await registry.availability(providerID: runtime.providerID) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    do {
      _ = try await task.value
      Issue.record("Cancelled readiness lookup returned success")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    try await runtime.shutdown()
  }
}

private actor AcquisitionGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func pause() async {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func open() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private actor AcquisitionProbe {
  var availabilityCount = 0
  var acquireCount = 0
  var cleanupCount = 0
  func availability() { availabilityCount += 1 }
  func acquire() { acquireCount += 1 }
  func cleanup() { cleanupCount += 1 }
}

private struct AcquisitionConnector: ModelProviderConnector {
  let descriptor: ModelProviderDescriptor
  let access: ModelRuntimeAccess
  let probe: AcquisitionProbe
  var availabilityGate: AcquisitionGate?
  var acquireGate: AcquisitionGate?
  var modelsGate: AcquisitionGate?

  func availability() async -> ModelProviderAvailability {
    await probe.availability()
    await availabilityGate?.pause()
    return .available
  }
  func models() async -> [ModelDescriptor] {
    await modelsGate?.pause()
    return [access.runtime.modelDescriptor]
  }
  func makeRuntime(modelID: String?) async -> ModelRuntime { access.runtime }
  func acquireRuntime(modelID: String?) async -> ModelRuntimeAccess {
    await probe.acquire()
    await acquireGate?.pause()
    return access
  }
}

private func connector(
  _ runtime: ModelRuntime, probe: AcquisitionProbe,
  availabilityGate: AcquisitionGate? = nil, acquireGate: AcquisitionGate? = nil,
  modelsGate: AcquisitionGate? = nil, borrowed: Bool = false
) throws -> AcquisitionConnector {
  AcquisitionConnector(
    descriptor: try .init(id: runtime.providerID, displayName: "Fixture", kind: .onDevice),
    access: borrowed ? .borrowed(runtime) : .owned(runtime), probe: probe,
    availabilityGate: availabilityGate, acquireGate: acquireGate, modelsGate: modelsGate)
}

private struct AcquisitionClient: ModelClient {
  let providerID = "test.acquisition"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn { .init(content: "fixture") }
}
private enum AcquisitionFixtureFailure: Error { case cleanup }
private func fixtureRuntime(_ probe: AcquisitionProbe, cleanupFails: Bool = false) throws
  -> ModelRuntime
{
  try ModelRuntime(
    id: .init(rawValue: "acquisition.runtime"), client: AcquisitionClient(),
    cleanup: {
      try Task.checkCancellation()
      await probe.cleanup()
      if cleanupFails { throw AcquisitionFixtureFailure.cleanup }
    })
}
private func selection() throws -> ModelProviderSelection {
  try .init(providerID: "test.acquisition", modelID: "model")
}
private func expectCancellation(_ task: Task<ModelRuntimeAccess, any Error>) async {
  do {
    _ = try await task.value
    Issue.record("Cancelled acquisition returned success")
  } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}
