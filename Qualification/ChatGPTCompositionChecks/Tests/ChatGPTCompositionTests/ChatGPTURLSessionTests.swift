import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_spi(Service) import ChatGPTAccount
@testable import ChatGPTText
import Testing

/// Real production URLSession + local socket server. No URLProtocol or transport mock.
/// tools/verify-chatgpt-wire.py owns the fixture server. This is NOT live ChatGPT proof.
@Suite(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["NATIVEAI_HTTP_FIXTURE_URL"] != nil))
struct ChatGPTURLSessionTests {
  @Test func successHasIdempotentConcurrentCompletion() async throws {
    let operation = try await URLSessionChatGPTTransport().invocation(request("ok"), maxResponseBytes: 4096)
    let value = try await collect(operation.events)
    #expect(value.status == 200)
    #expect(value.body == Data("hello".utf8))
    async let first: Void = operation.waitForCompletion()
    async let second: Void = operation.waitForCompletion()
    _ = try await (first, second)
    operation.cancel()
    try await operation.waitForCompletion()
  }

  @Test func cancellationJoinsInvalidationEvenForCancelledCaller() async throws {
    let operation = try await URLSessionChatGPTTransport().invocation(request("stall"), maxResponseBytes: 4096)
    var iterator = operation.events.makeAsyncIterator()
    guard case .response? = try await iterator.next() else {
      Issue.record("Expected a real response before cancellation.")
      return
    }
    operation.cancel()
    operation.cancel()
    let waiter = Task { try await operation.waitForCompletion() }
    waiter.cancel()
    try await waiter.value
    // Drain can succeed even though the request itself was cancelled.
    await #expect(throws: CancellationError.self) {
      while let _ = try await iterator.next() {}
    }
  }

  @Test func oversizedContentLengthFailsButDrains() async throws {
    let operation = try await URLSessionChatGPTTransport().invocation(request("large"), maxResponseBytes: 4)
    await #expect(throws: ChatGPTTransportError.responseTooLarge) {
      try await collect(operation.events)
    }
    try await operation.waitForCompletion()
  }

  @Test func chunkedCumulativeLimitFailsButDrains() async throws {
    let operation = try await URLSessionChatGPTTransport().invocation(request("chunked-large"), maxResponseBytes: 4)
    await #expect(throws: ChatGPTTransportError.responseTooLarge) {
      try await collect(operation.events)
    }
    try await operation.waitForCompletion()
  }

  @Test func abruptPeerDisconnectCannotBecomeSuccess() async throws {
    let operation = try await URLSessionChatGPTTransport().invocation(request("truncated"), maxResponseBytes: 4096)
    await #expect(throws: ChatGPTTransportError.invalidResponse) {
      try await collect(operation.events)
    }
    try await operation.waitForCompletion()
  }

  @Test func redirectIsRejectedWithoutFollowingLocation() async throws {
    var request = try request("redirect")
    request.setValue("Bearer public-test-marker", forHTTPHeaderField: "Authorization")
    let operation = try await URLSessionChatGPTTransport().invocation(request, maxResponseBytes: 4096)
    await #expect(throws: ChatGPTTransportError.invalidResponse) {
      try await collect(operation.events)
    }
    try await operation.waitForCompletion()
    // The fixture runner independently asserts that /redirect-target was never reached.
  }

  @Test func textSSEUsesRealTransportAndCanBeReused() async throws {
    let transport = URLSessionChatGPTTransport()
    for _ in 0..<3 {
      let operation = chatGPTSSE(
        transport: transport, request: try request("sse"), maxResponseBytes: 4096, maxFrameBytes: 256)
      var values: [String] = []
      for try await event in operation.events { values.append(event.data) }
      try await operation.waitForCompletion()
      #expect(values == ["한글", "done"])
    }
  }

  @Test func cancellingOneRequestDoesNotCancelAnother() async throws {
    let transport = URLSessionChatGPTTransport()
    let stalled = try await transport.invocation(request("stall"), maxResponseBytes: 4096)
    var iterator = stalled.events.makeAsyncIterator()
    _ = try await iterator.next()
    let healthy = try await transport.invocation(request("ok"), maxResponseBytes: 4096)
    stalled.cancel()
    try await stalled.waitForCompletion()
    let response = try await collect(healthy.events)
    try await healthy.waitForCompletion()
    #expect(response.body == Data("hello".utf8))
  }

  @Test func invalidLimitIsRejectedBeforeDispatch() async throws {
    await #expect(throws: ChatGPTTransportError.limitExceeded) {
      try await URLSessionChatGPTTransport().invocation(request("must-not-dispatch"), maxResponseBytes: 0)
    }
  }

  @Test func alreadyCancelledCallerCannotStartTransport() async throws {
    let gate = HTTPTestGate()
    let task = Task {
      await gate.wait()
      await #expect(throws: CancellationError.self) {
        try await URLSessionChatGPTTransport().invocation(request("must-not-dispatch"), maxResponseBytes: 4096)
      }
    }
    task.cancel()
    await gate.open()
    _ = await task.value
  }

  private func request(_ path: String) throws -> URLRequest {
    let raw = try #require(ProcessInfo.processInfo.environment["NATIVEAI_HTTP_FIXTURE_URL"])
    let base = try #require(URL(string: raw))
    return URLRequest(url: base.appendingPathComponent(path))
  }

  private func collect(_ events: AsyncThrowingStream<ChatGPTTransportElement, any Error>) async throws
    -> (status: Int?, body: Data) {
    var status: Int?
    var body = Data()
    for try await event in events {
      switch event {
      case .response(let value, _): status = value
      case .body(let data): body.append(data)
      }
    }
    return (status, body)
  }
}

private actor HTTPTestGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
