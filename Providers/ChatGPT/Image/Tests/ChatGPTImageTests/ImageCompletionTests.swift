import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount
@testable import ChatGPTImage

@Test func failedImageDrainQuarantinesSharedClientAndRetainsInvocation() async throws {
  let probe = ImageProbe()
  let account = ChatGPTAccountSession(profile: .codexSubscription,
    store: FreshCredentials(), transport: ImageTransport(probe: ImageProbe(), failsReceipt: false))
  let client = try ChatGPTImageClient(account: account, transport: ImageTransport(probe: probe))
  let copy = client
  do {
    _ = try await client.generate(.init(prompt: "fixture"))
    Issue.record("Unproved image completion succeeded")
  } catch let failure as ChatGPTImageFailure {
    #expect(failure.code == .transportFailure)
    #expect(failure.responseCode == "local_completion_unproved")
    #expect(failure.httpStatusCode == nil)
  }
  #expect(probe.ownerIsAlive)
  await #expect(throws: ChatGPTImageFailure.self) { try await copy.generate(.init(prompt: "fixture")) }
  #expect(probe.calls == 1)
  #expect(probe.ownerIsAlive)
}

@Test func settledImageParseFailureDoesNotQuarantineClient() async throws {
  let probe = ImageProbe()
  let account = ChatGPTAccountSession(profile: .codexSubscription,
    store: FreshCredentials(), transport: ImageTransport(probe: ImageProbe(), failsReceipt: false))
  let client = try ChatGPTImageClient(account: account, transport: ImageTransport(probe: probe, failsReceipt: false))
  for _ in 0..<2 {
    await #expect(throws: ChatGPTImageFailure(.malformedResponse)) { try await client.generate(.init(prompt: "fixture")) }
  }
  #expect(probe.calls == 2)
  #expect(!probe.ownerIsAlive)
}

@Test func invalidImagePromptDoesNotEnterTransport() async throws {
  let probe = ImageProbe()
  let account = ChatGPTAccountSession(profile: .codexSubscription,
    store: FreshCredentials(), transport: ImageTransport(probe: ImageProbe(), failsReceipt: false))
  let client = try ChatGPTImageClient(account: account, transport: ImageTransport(probe: probe))
  await #expect(throws: ChatGPTImageFailure(.invalidRequest)) { try await client.generate(.init(prompt: "")) }
  #expect(probe.calls == 0)
}

private struct FreshCredentials: ChatGPTCredentialStoring {
  func load() throws -> ChatGPTTokenSet? {
    ChatGPTTokenSet(accessToken: "test-access", refreshToken: "test-refresh", idToken: "id",
      expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
      account: ChatGPTAccount(accountID: "test-account", plan: nil, email: nil))
  }
  func save(_ value: ChatGPTTokenSet) throws { Issue.record("Unexpected credential write") }
  func delete() throws { Issue.record("Unexpected credential deletion") }
}
private final class ImageNativeOperation: Sendable {}
private final class ImageProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private weak var owner: ImageNativeOperation?
  var calls: Int { lock.withLock { count } }
  var ownerIsAlive: Bool { lock.withLock { owner != nil } }
  func observe(_ owner: ImageNativeOperation) { lock.withLock { self.owner = owner; count += 1 } }
}
private struct ImageTransport: ChatGPTTransport {
  let probe: ImageProbe
  var failsReceipt = true
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws -> ChatGPTTransportInvocation {
    let owner = ImageNativeOperation()
    probe.observe(owner)
    let stream = AsyncThrowingStream<ChatGPTTransportElement, any Error> { continuation in
      continuation.yield(.response(statusCode: 200, headers: [:]))
      continuation.yield(.body(Data("{}".utf8)))
      continuation.finish()
    }
    return ChatGPTTransportInvocation(events: stream,
      cancel: { withExtendedLifetime(owner) {} }, waitForCompletion: {
        try withExtendedLifetime(owner) { if failsReceipt { throw Unproved() } }
      })
  }
  private struct Unproved: Error {}
}
