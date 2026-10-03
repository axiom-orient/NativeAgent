import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import LanguageModelCore
@testable @_spi(Service) import ChatGPTAccount
@testable import ChatGPTText

// These fixtures qualify the real ModelClient/Account composition, not a live service.
@Test(arguments: [true, false])
func failedAccountDrainFailsModelProducerReceipt(expired: Bool) async throws {
  let account = ChatGPTAccountSession(profile: .codexSubscription,
    store: ReadOnlyCredentials(expired: expired), transport: UnprovedTransport())
  let client = try ChatGPTModelClient(account: account)
  let invocation = client.invocation(request: request(), onStarted: {})
  await #expect(throws: ModelExecutorDrainFailure.self) {
    for try await _ in invocation.events {}
  }
  await #expect(throws: ModelExecutorDrainFailure.self) { try await invocation.waitForCompletion() }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await account.status() }
}

@Test func unsupportedHostDoesNotSilentlyCreateAnAccount() throws {
  #if !canImport(Security)
  #expect(throws: ChatGPTFailure(.invalidConfiguration)) {
    try ChatGPTAccountSession(credentialNamespace: "qualification.test")
  }
  #endif
}

@Test func settledAuthenticationFailureDoesNotBecomeFailedProducerDrain() async throws {
  let account = ChatGPTAccountSession(profile: .codexSubscription,
    store: ReadOnlyCredentials(expired: true), transport: UnprovedTransport(failsReceipt: false, status: 401))
  let client = try ChatGPTModelClient(account: account)
  let invocation = client.invocation(request: request(), onStarted: {})
  await #expect(throws: (any Error).self) { for try await _ in invocation.events {} }
  try await invocation.waitForCompletion()
}

private func request() -> ModelRequest {
  ModelRequest(sessionID: "account-completion", messages: [.init(role: .user, content: "Hello")], tools: [])
}
private struct ReadOnlyCredentials: ChatGPTCredentialStoring {
  let expired: Bool
  func load() throws -> ChatGPTTokenSet? {
    ChatGPTTokenSet(accessToken: "test-access", refreshToken: "test-refresh", idToken: "id",
      expiresAt: Date(timeIntervalSince1970: expired ? 1 : 4_000_000_000),
      account: ChatGPTAccount(accountID: "test-account", plan: nil, email: nil))
  }
  func save(_ value: ChatGPTTokenSet) throws { Issue.record("Unexpected credential save") }
  func delete() throws {} // no storage: this fixture only checks producer error separation
}
private struct UnprovedTransport: ChatGPTTransport {
  var failsReceipt = true
  var status = 200
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws -> ChatGPTTransportInvocation {
    let stream = AsyncThrowingStream<ChatGPTTransportElement, any Error> { continuation in
      continuation.yield(.response(statusCode: status, headers: [:]))
      continuation.yield(.body(Data("{}".utf8)))
      continuation.finish()
    }
    return ChatGPTTransportInvocation(events: stream, cancel: {}, waitForCompletion: {
      if failsReceipt { throw Unproved() }
    })
  }
  private struct Unproved: Error {}
}
