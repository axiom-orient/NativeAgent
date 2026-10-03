import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@testable import AppleSystemModelProvider

// This suite exercises the actual provider projection and Runtime. The controlled
// snapshot port proves lifetime semantics, not live Apple inference or SDK drain.
@Suite("Apple text projection ownership")
struct FoundationModelsOwnershipTests {
  @Test func eofCannotReleaseAdmissionBeforeSnapshotProducerSettlement() async throws {
    let drain = SnapshotDrain()
    let runtime = try makeRuntime(drain)
    let run = try await runtime.start(request)
    try await until { await drain.joinCount == 1 }
    #expect(await runtime.status().phase == .running)
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await runtime.start(request) }
    await drain.release()
    var events: [ModelEvent] = []
    for try await event in run.events { events.append(event) }
    #expect(events.last == .completed(ModelTurn(content: "ok")))
    #expect(await runtime.status().phase == .idle)
    #expect(await drain.joinCount == 1)
    try await runtime.shutdown()
  }

  @Test func cancelJoinsNativePortBeforePermittingAnotherRequest() async throws {
    let drain = SnapshotDrain()
    let signal = SnapshotCancelSignal()
    let runtime = try makeRuntime(drain, signal: signal)
    let run = try await runtime.start(request)
    try await until { await drain.joinCount == 1 }
    let cancellation = Task { await run.cancel() }
    try await until { signal.count > 0 }
    #expect(await runtime.status().phase == .draining)
    await #expect(throws: ModelRuntimeFailure.self) { _ = try await runtime.reserve(request) }
    await drain.release()
    await cancellation.value
    do {
      for try await _ in run.events {}
      Issue.record("Cancelled snapshot generation became success")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .cancelled) }
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func failedNativePortJoinQuarantinesWithoutCleanupOrRetry() async throws {
    let drain = SnapshotDrain(fail: true)
    let cleanup = SnapshotCancelSignal()
    let runtime = try makeRuntime(drain, cleanup: { cleanup.mark() })
    let run = try await runtime.start(request)
    try await until { await drain.joinCount == 1 }
    await drain.release()
    await #expect(throws: ModelRuntimeFailure.self) { for try await _ in run.events {} }
    #expect(await runtime.status().failure?.code == .nativeDrainFailed)
    #expect(await drain.joinCount == 1)
    await #expect(throws: ModelRuntimeFailure.self) { try await runtime.shutdown() }
    #expect(cleanup.count == 0)
  }

  @Test func emptyNativeSnapshotSequenceIsNotSuccessfulEmptyText() async throws {
    let called = SnapshotCancelSignal()
    let client = FoundationModelsClient(
      availability: { .available },
      responses: { _ in
        .init(
          snapshots: AsyncThrowingStream { $0.finish() }, cancel: {},
          waitForCompletion: { called.mark() })
      })
    do {
      _ = try await client.generate(request: request)
      Issue.record("No native response must not become an empty success")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .terminalMissing) }
    #expect(called.count > 0)
  }

  private var request: ModelRequest {
    .init(sessionID: "apple-owned", messages: [.init(role: .user, content: "hello")], tools: [])
  }
  private func makeRuntime(
    _ drain: SnapshotDrain, signal: SnapshotCancelSignal = .init(),
    cleanup: @escaping @Sendable () async throws -> Void = {}
  ) throws -> ModelRuntime {
    let descriptor = ModelDescriptor(
      id: "system-language-model", providerID: "apple.fixture",
      capabilities: [.textInput, .textOutput, .streaming])
    let client = FoundationModelsClient(
      providerID: descriptor.providerID, modelDescriptor: descriptor,
      availability: { .available },
      responses: { _ in
        .init(
          snapshots: AsyncThrowingStream {
            $0.yield("ok")
            $0.finish()
          },
          cancel: { signal.mark() }, waitForCompletion: { try await drain.join() })
      })
    return try ModelRuntime(
      id: .init(rawValue: "apple.runtime"),
      model: ClientLanguageModel(client: client), cleanup: cleanup)
  }
  private func until(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else { throw SnapshotTestFailure.timeout }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}
private actor SnapshotDrain {
  private(set) var joinCount = 0
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  let fail: Bool
  init(fail: Bool = false) { self.fail = fail }
  func join() async throws {
    joinCount += 1
    if !opened { await withCheckedContinuation { waiters.append($0) } }
    if fail { throw SnapshotTestFailure.nativeDrain }
  }
  func release() {
    opened = true
    let current = waiters
    waiters.removeAll()
    for waiter in current { waiter.resume() }
  }
}
private final class SnapshotCancelSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func mark() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}
private enum SnapshotTestFailure: Error { case timeout, nativeDrain }
