import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_spi(Service) @testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
import LanguageModelCore
import Testing

// Controlled completion gates establish ordering. They are not live account/model evidence.
@Suite(.timeLimit(.minutes(1)))
struct ChatGPTTransportLifecycleTests {
  @Test func nativeTaskReceiptAloneDoesNotAuthorizeRelease() {
    var state = ChatGPTTransportCompletionState.pending
    state.observe(.task)
    state.observe(.task)
    #expect(state == .taskFinished)
    state.observe(.session)
    state.observe(.session)
    #expect(state == .settled)
  }

  @Test func earlyInvalidationDoesNotMasqueradeAsNativeCompletion() {
    var state = ChatGPTTransportCompletionState.pending
    state.observe(.session)
    state.observe(.session)
    #expect(state == .sessionInvalidated)
    state.observe(.task)
    state.observe(.session)
    state.observe(.task)
    #expect(state == .settled)
  }

  @Test func legacyStreamDoesNotInventNativeCompletion() async throws {
    let transport = LegacyStreamOnlyTransport()
    await #expect(throws: ChatGPTFailure(.invalidConfiguration)) {
      try await transport.invocation(request(), maxResponseBytes: 4096)
    }
    #expect(await transport.calls == 0)
  }

  @Test func sseEOFWaitsForTransportSettlement() async throws {
    let gate = TransportSettlementGate()
    let operation = chatGPTSSE(
      transport: GatedTransport(gate: gate), request: request(),
      maxResponseBytes: 4096, maxFrameBytes: 256)
    let reader = Task {
      var values: [String] = []
      for try await event in operation.events { values.append(event.data) }
      #expect(await gate.isReleased)
      return values
    }
    await gate.waitUntilJoined()
    #expect(!(await gate.isReleased))
    await gate.release()
    #expect(try await reader.value == ["hello"])
    try await operation.waitForCompletion()
    try await operation.waitForCompletion()
    operation.cancel() // Settled cancellation is harmless.
  }

  @Test func sseCancellationStillDrainsFromCancelledWaiter() async throws {
    let gate = TransportSettlementGate()
    let operation = chatGPTSSE(
      transport: GatedTransport(gate: gate), request: request(),
      maxResponseBytes: 4096, maxFrameBytes: 256)
    await gate.waitUntilJoined()
    operation.cancel()
    operation.cancel()
    let waiter = Task {
      try await operation.waitForCompletion()
      #expect(await gate.isReleased)
    }
    waiter.cancel()
    await gate.release()
    try await waiter.value
    await #expect(throws: CancellationError.self) {
      for try await _ in operation.events {}
    }
    #expect(gate.cancelCount > 0)
  }

  @Test func rejectedHTTPAttemptDrainsBeforeExposingRetryable401() async throws {
    let gate = TransportSettlementGate()
    let operation = chatGPTSSE(
      transport: GatedTransport(gate: gate, status: 401), request: request(),
      maxResponseBytes: 4096, maxFrameBytes: 256)
    let reader = Task {
      do {
        for try await _ in operation.events {}
        Issue.record("401 was reported as success.")
      } catch {
        #expect(await gate.isReleased)
        #expect(error as? ChatGPTWireError == .httpStatus(401))
      }
    }
    await gate.waitUntilJoined()
    await gate.release()
    await reader.value
    try await operation.waitForCompletion()
    #expect(gate.cancelCount > 0)
  }

  @Test func malformedSSEDrainsBeforeReportingParserFailure() async throws {
    let gate = TransportSettlementGate()
    let operation = chatGPTSSE(
      transport: GatedTransport(gate: gate, body: Data([0xFF, 0x0A, 0x0A])),
      request: request(), maxResponseBytes: 4096, maxFrameBytes: 256)
    let reader = Task {
      await #expect(throws: ChatGPTWireError.malformedSSE) {
        for try await _ in operation.events {}
      }
      #expect(await gate.isReleased)
    }
    await gate.waitUntilJoined()
    await gate.release()
    await reader.value
    try await operation.waitForCompletion()
  }

  @Test func unprovedTransportDrainFailsBothSSEPorts() async throws {
    let gate = TransportSettlementGate(fails: true)
    let operation = chatGPTSSE(
      transport: GatedTransport(gate: gate), request: request(),
      maxResponseBytes: 4096, maxFrameBytes: 256)
    await gate.waitUntilJoined()
    await gate.release()
    await #expect(throws: ModelExecutorDrainFailure.self) {
      for try await _ in operation.events {}
    }
    await #expect(throws: ModelExecutorDrainFailure.self) {
      try await operation.waitForCompletion()
    }
    #expect(await gate.joinCount == 1)
  }

  @Test func imageResponseWaitsForTheSameTransportBoundary() async throws {
    let gate = TransportSettlementGate()
    let task = Task {
      let value = try await ChatGPTImageWireCodec.response(
        transport: GatedTransport(gate: gate, body: Data("image-bytes".utf8)),
        request: request(), maximumBytes: 4096)
      #expect(await gate.isReleased)
      return value.body
    }
    await gate.waitUntilJoined()
    await gate.release()
    #expect(try await task.value == Data("image-bytes".utf8))
  }

  @Test func imageParseFailureCancelsAndJoinsTransport() async throws {
    let gate = TransportSettlementGate()
    let task = Task {
      await #expect(throws: ChatGPTImageFailure(.limitExceeded)) {
        try await ChatGPTImageWireCodec.response(
          transport: GatedTransport(gate: gate), request: request(), maximumBytes: 1)
      }
      #expect(await gate.isReleased)
    }
    await gate.waitUntilJoined()
    await gate.release()
    _ = await task.value
    #expect(gate.cancelCount > 0)
  }

  @Test func imageNeverReturnsSuccessWhenTransportDrainFails() async throws {
    let gate = TransportSettlementGate(fails: true)
    let task = Task {
      await #expect(throws: ChatGPTTransportDrainFailure.self) {
        try await ChatGPTImageWireCodec.response(
          transport: GatedTransport(gate: gate), request: request(), maximumBytes: 4096)
      }
    }
    await gate.waitUntilJoined()
    await gate.release()
    _ = await task.value
  }

  @Test func cancellationDuringImageDrainCannotReturnSuccess() async throws {
    let gate = TransportSettlementGate()
    let task = Task {
      try await ChatGPTImageWireCodec.response(
        transport: GatedTransport(gate: gate), request: request(), maximumBytes: 4096)
    }
    await gate.waitUntilJoined()
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(gate.cancelCount > 0)
  }

  private func request() -> URLRequest {
    URLRequest(url: URL(string: "https://fixture.invalid/stream")!)
  }
}

struct SettlementFailure: Error, Sendable {}

actor TransportSettlementGate {
  private(set) var isReleased = false
  nonisolated private let cancellation = TransportCancellationCounter()
  nonisolated var cancelCount: Int { cancellation.count }
  private var joined = false
  private(set) var joinCount = 0
  private var joinedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  let fails: Bool
  init(fails: Bool = false) { self.fails = fails }
  nonisolated func cancel() { cancellation.increment() }
  func wait() async throws {
    joinCount += 1
    joined = true
    let pending = joinedWaiters
    joinedWaiters.removeAll()
    for waiter in pending { waiter.resume() }
    if !isReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    if fails { throw SettlementFailure() }
  }
  func waitUntilJoined() async {
    if joined { return }
    await withCheckedContinuation { joinedWaiters.append($0) }
  }
  func release() {
    isReleased = true
    let pending = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

struct GatedTransport: ChatGPTTransport {
  let gate: TransportSettlementGate
  var status = 200
  var body = Data("data: hello\n\n".utf8)
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation {
    let pair = AsyncThrowingStream<ChatGPTTransportElement, any Error>.makeStream()
    pair.continuation.yield(.response(statusCode: status, headers: [:]))
    pair.continuation.yield(.body(body))
    pair.continuation.finish()
    return ChatGPTTransportInvocation(
      events: pair.stream,
      cancel: { gate.cancel() },
      waitForCompletion: { try await gate.wait() })
  }
}

private actor LegacyStreamOnlyTransport: ChatGPTTransport {
  private(set) var calls = 0
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    calls += 1
    return AsyncThrowingStream { $0.finish() }
  }
}

private final class TransportCancellationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return value }
  func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
