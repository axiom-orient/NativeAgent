import Foundation
import LanguageModelCore
import Testing

@testable import LanguageModelRuntime

@Suite("Shared local backend lifetime")
struct LocalBackendTests {
  @Test func concurrentLoadsReturnExactlyOneRuntime() async throws {
    let calls = BackendProbe()
    let gate = BackendGate()
    let runtime = try makeRuntime()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        await gate.wait()
        return runtime
      }, releaseResident: { await calls.record("release") })
    let waiters = (0..<24).map { _ in Task { try await backend.load() } }
    try await eventually { await calls.count("load") == 1 }
    #expect(await backend.status() == .loading)
    await gate.open()
    for waiter in waiters { #expect(try await waiter.value === runtime) }
    #expect(await calls.count("load") == 1)
    #expect(await backend.status() == .ready(runtime.id))
    try await backend.shutdown()
    #expect(await calls.count("release") == 1)
  }

  @Test func failedLoadRequiresAnExplicitRetry() async throws {
    let calls = BackendProbe()
    let runtime = try makeRuntime()
    let backend = LocalBackend(
      load: {
        let attempt = await calls.record("load")
        if attempt == 1 { throw BackendTestError.load }
        return runtime
      }, releaseResident: {})
    await #expect(throws: BackendTestError.load) { _ = try await backend.load() }
    #expect(await backend.status() == .unloaded)
    #expect(await calls.count("load") == 1)
    #expect(try await backend.load() === runtime)
    try await backend.shutdown()
  }

  @Test func precancelledLoadNeverEntersLoader() async throws {
    let gate = BackendGate()
    let calls = BackendProbe()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        return try makeRuntime()
      }, releaseResident: {})
    let waiter = Task {
      await gate.wait()
      return try await backend.load()
    }
    waiter.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) { _ = try await waiter.value }
    #expect(await calls.count("load") == 0)
    try await backend.shutdown()
  }

  @Test func cancelledWaiterDoesNotCancelAnotherBorrower() async throws {
    let gate = BackendGate()
    let calls = BackendProbe()
    let runtime = try makeRuntime()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        await gate.wait()
        #expect(!Task.isCancelled)
        return runtime
      }, releaseResident: { await calls.record("release") })
    let first = Task { try await backend.load() }
    try await eventually { await calls.count("load") == 1 }
    let second = Task { try await backend.load() }
    first.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    #expect(try await second.value === runtime)
    try await backend.shutdown()
    #expect(await calls.count("release") == 1)
  }

  @Test func shutdownJoinsLateSuccessfulLoadAndNeverPublishesIt() async throws {
    let loadGate = BackendGate()
    let calls = BackendProbe()
    let runtime = try makeRuntime(cleanup: { await calls.record("runtimeClose") })
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        await loadGate.wait()  // Deliberately non-cooperative native construction.
        #expect(Task.isCancelled)
        return runtime
      }, releaseResident: { await calls.record("release") })
    let waiter = Task { try await backend.load() }
    try await eventually { await calls.count("load") == 1 }
    let close = Task { try await backend.shutdown() }
    try await eventually { await backend.status() == .closing }
    #expect(await calls.count("release") == 0)
    await #expect(throws: LocalBackendFailure.closing) { _ = try await backend.load() }
    await loadGate.open()
    do {
      _ = try await waiter.value
      Issue.record("Late load escaped close")
    } catch let error as LocalBackendFailure { #expect(error == .closing || error == .closed) }
    try await close.value
    #expect(await backend.status() == .closed)
    #expect(await calls.values == ["load", "runtimeClose", "release"])
  }

  @Test func closingUnloadedBackendDoesNotLoad() async throws {
    let calls = BackendProbe()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        return try makeRuntime()
      }, releaseResident: {})
    try await backend.shutdown()
    try await backend.shutdown()
    #expect(await calls.count("load") == 0)
    await #expect(throws: LocalBackendFailure.closed) { _ = try await backend.load() }
  }

  @Test func concurrentShutdownReleasesExactlyOnceInOrder() async throws {
    let calls = BackendProbe()
    let gate = BackendGate()
    let runtime = try makeRuntime(cleanup: {
      await calls.record("runtimeClose")
      await gate.wait()
    })
    let backend = LocalBackend(
      load: {
        runtime
      }, releaseResident: { await calls.record("release") })
    _ = try await backend.load()
    let closes = (0..<16).map { _ in Task { try await backend.shutdown() } }
    try await eventually { await calls.count("runtimeClose") == 1 }
    #expect(await calls.count("release") == 0)
    await gate.open()
    for close in closes { try await close.value }
    #expect(await calls.values == ["runtimeClose", "release"])
  }

  @Test func cancelledCloseWaiterDoesNotAbandonTeardown() async throws {
    let calls = BackendProbe()
    let gate = BackendGate()
    let runtime = try makeRuntime(cleanup: {
      await calls.record("runtimeClose")
      await gate.wait()
    })
    let backend = LocalBackend(
      load: {
        runtime
      }, releaseResident: { await calls.record("release") })
    _ = try await backend.load()
    let close = Task { try await backend.shutdown() }
    try await eventually { await calls.count("runtimeClose") == 1 }
    close.cancel()
    await gate.open()
    try await close.value
    #expect(await backend.status() == .closed)
    #expect(await calls.count("release") == 1)
  }

  @Test func runtimeShutdownFailureQuarantinesWithoutReleasingResident() async throws {
    let calls = BackendProbe()
    let runtime = try makeRuntime(cleanup: { throw BackendTestError.cleanup })
    let backend = LocalBackend(
      load: {
        runtime
      }, releaseResident: { await calls.record("release") })
    _ = try await backend.load()
    await #expect(throws: LocalBackendFailure.runtimeShutdownFailed) {
      try await backend.shutdown()
    }
    #expect(await backend.status() == .failed(.runtimeShutdownFailed))
    await #expect(throws: LocalBackendFailure.runtimeShutdownFailed) {
      _ = try await backend.load()
    }
    await #expect(throws: LocalBackendFailure.runtimeShutdownFailed) {
      try await backend.shutdown()
    }
    #expect(await calls.count("release") == 0)
  }

  @Test func releaseFailureIsStickyAndNeverReportedAsClosed() async throws {
    let calls = BackendProbe()
    let backend = LocalBackend(
      load: {
        try makeRuntime()
      },
      releaseResident: {
        await calls.record("release")
        throw BackendTestError.cleanup
      })
    _ = try await backend.load()
    await #expect(throws: LocalBackendFailure.residentReleaseFailed) {
      try await backend.shutdown()
    }
    await #expect(throws: LocalBackendFailure.residentReleaseFailed) {
      try await backend.shutdown()
    }
    #expect(await backend.status() == .failed(.residentReleaseFailed))
    #expect(await calls.count("release") == 1)
  }

  @Test func failedPartialLoadCleanupIsStickyAndDoesNotRetry() async throws {
    let calls = BackendProbe()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        throw BackendTestError.load
      },
      releaseResident: {
        await calls.record("release")
        throw BackendTestError.cleanup
      })
    await #expect(throws: LocalBackendFailure.loadCleanupFailed) { _ = try await backend.load() }
    #expect(await backend.status() == .failed(.loadCleanupFailed))
    await #expect(throws: LocalBackendFailure.loadCleanupFailed) { _ = try await backend.load() }
    await #expect(throws: LocalBackendFailure.loadCleanupFailed) { try await backend.shutdown() }
    #expect(await calls.values == ["load", "release"])
  }

  @Test func cancelledLoadWaiterPreservesPartialLoadCleanupFailure() async throws {
    let gate = BackendGate()
    let calls = BackendProbe()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        await gate.wait()
        throw BackendTestError.load
      },
      releaseResident: {
        await calls.record("release")
        throw BackendTestError.cleanup
      })
    let load = Task { try await backend.load() }
    try await eventually { await calls.count("load") == 1 }

    load.cancel()
    await gate.open()

    await #expect(throws: LocalBackendFailure.loadCleanupFailed) { _ = try await load.value }
    #expect(await backend.status() == .failed(.loadCleanupFailed))
    #expect(await calls.values == ["load", "release"])
  }

  @Test func shutdownJoinsCancelledPartialLoadCleanupWithoutCancellingIt() async throws {
    let gate = BackendGate()
    let calls = BackendProbe()
    let backend = LocalBackend(
      load: {
        await calls.record("load")
        await gate.wait()
        try Task.checkCancellation()
        return try makeRuntime()
      },
      releaseResident: {
        #expect(!Task.isCancelled)
        await calls.record("release")
      })
    let load = Task { try await backend.load() }
    try await eventually { await calls.count("load") == 1 }
    let close = Task { try await backend.shutdown() }
    try await eventually { await backend.status() == .closing }
    await gate.open()
    await #expect(throws: CancellationError.self) { _ = try await load.value }
    try await close.value
    #expect(await backend.status() == .closed)
    #expect(await calls.values == ["load", "release"])
  }

  @Test func twoFrontendsUseOneInvocationReservation() async throws {
    let backend = LocalBackend(
      load: {
        try makeRuntime()
      }, releaseResident: {})
    let native = try await backend.load()
    let apple = try await backend.load()
    #expect(native === apple)
    let reservation = try await native.reserve(backendRequest())
    await #expect(throws: ModelRuntimeFailure.self) {
      _ = try await apple.reserve(backendRequest())
    }
    #expect(await native.release(reservation))
    #expect(try await apple.generate(backendRequest()).content == "ok")
    try await backend.shutdown()
  }
}

private enum BackendTestError: Error, Equatable { case load, cleanup }
private actor BackendProbe {
  var values: [String] = []
  @discardableResult func record(_ value: String) -> Int {
    values.append(value)
    return count(value)
  }
  func count(_ value: String) -> Int { values.filter { $0 == value }.count }
}
private actor BackendGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}
private struct BackendClient: ModelClient {
  let providerID = "test.local"
  var modelDescriptor: ModelDescriptor? {
    ModelDescriptor(id: "test.model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn { ModelTurn(content: "ok") }
}
private func makeRuntime(cleanup: @escaping @Sendable () async throws -> Void = {}) throws
  -> ModelRuntime
{
  try ModelRuntime(id: .init(rawValue: "test.runtime"), client: BackendClient(), cleanup: cleanup)
}
private func backendRequest() -> ModelRequest {
  ModelRequest(
    sessionID: "test.session", messages: [.init(role: .user, content: "hello")], tools: [])
}
private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
  let clock = ContinuousClock()
  let end = clock.now.advanced(by: .seconds(2))
  while !(await condition()) {
    guard clock.now < end else { throw BackendTestError.load }
    try await Task.sleep(for: .milliseconds(1))
  }
}
