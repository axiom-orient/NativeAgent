import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount

func expiredToken(accountID: String = "account-1", access: String = "old-access") -> ChatGPTTokenSet {
  ChatGPTTokenSet(accessToken: access, refreshToken: "old-refresh", idToken: "id-token",
    expiresAt: Date(timeIntervalSince1970: 1),
    account: ChatGPTAccount(accountID: accountID, plan: "plus", email: nil))
}

final class MemoryCredentials: ChatGPTCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var token: ChatGPTTokenSet?
  private var deleteCount = 0
  private var shouldFailDelete = false
  private var shouldFailSave = false
  init(token: ChatGPTTokenSet?) { self.token = token }
  var deletions: Int { lock.withLock { deleteCount } }
  var failDelete: Bool {
    get { lock.withLock { shouldFailDelete } }
    set { lock.withLock { shouldFailDelete = newValue } }
  }
  var failSave: Bool {
    get { lock.withLock { shouldFailSave } }
    set { lock.withLock { shouldFailSave = newValue } }
  }
  func load() throws -> ChatGPTTokenSet? { lock.withLock { token } }
  func save(_ value: ChatGPTTokenSet) throws {
    try lock.withLock {
      if shouldFailSave { throw ChatGPTFailure(.credentialStorageFailed) }
      token = value
    }
  }
  func delete() throws {
    try lock.withLock {
      deleteCount += 1
      if shouldFailDelete { throw ChatGPTFailure(.credentialStorageFailed) }
      token = nil
    }
  }
}

actor Signal {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  var isOpen: Bool { opened }
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

final class ReceiptGate: @unchecked Sendable {
  let entered = Signal()
  let cancelled = Signal()
  let release = Signal()
  private let lock = NSLock()
  private var callCount = 0
  var calls: Int { lock.withLock { callCount } }
  func called() { lock.withLock { callCount += 1 } }
}

struct GatedTransport: ChatGPTTransport {
  let receipt: ReceiptGate
  var status = 200
  var body = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
  var failDrain = false
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws -> ChatGPTTransportInvocation {
    receipt.called()
    let events = AsyncThrowingStream<ChatGPTTransportElement, any Error> { continuation in
      continuation.yield(.response(statusCode: status, headers: [:]))
      continuation.yield(.body(body))
      continuation.finish()
    }
    return ChatGPTTransportInvocation(events: events,
      cancel: { Task { await receipt.cancelled.open() } },
      waitForCompletion: {
        await receipt.entered.open()
        await receipt.release.wait()
        if failDrain { throw ReceiptFailure() }
      })
  }
}
struct ReceiptFailure: Error {}

struct RefreshAndSignInTransport: ChatGPTTransport {
  let refresh: GatedTransport
  let signIn: GatedTransport
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws -> ChatGPTTransportInvocation {
    let port = request.value(forHTTPHeaderField: "Content-Type") == "application/json" ? refresh : signIn
    return try await port.invocation(request, maxResponseBytes: maxResponseBytes)
  }
}

final class SignInPort: @unchecked Sendable {
  let startEntered = Signal()
  let allowStart = Signal()
  let callbackEntered = Signal()
  let allowCallback = Signal()
  let cancelEntered = Signal()
  let allowCancel = Signal()
  let stopped = Signal()
  private let lock = NSLock()
  private var startCount = 0
  var starts: Int { lock.withLock { startCount } }
  let callback: URL
  let authorization = ChatGPTWebAuthorization(
    authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize?state=test-state")!,
    expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
    redirectURI: URL(string: "http://localhost:1455/auth/callback")!,
    state: "test-state", verifier: String(repeating: "a", count: 64))

  init(callback: URL = URL(string: "http://localhost:1455/auth/callback?state=test-state&code=test-code")!) {
    self.callback = callback
  }
  func start(_ profile: ChatGPTProtocolProfile) async throws -> ChatGPTSignInSession {
    lock.withLock { startCount += 1 }
    await startEntered.open()
    await allowStart.wait()
    return ChatGPTSignInSession(authorization: authorization,
      waitForCallback: { _ in
        await self.callbackEntered.open()
        await self.allowCallback.wait()
        return self.callback
      }, cancel: {
        await self.cancelEntered.open()
        await self.allowCancel.wait()
        await self.stopped.open()
      })
  }
  func prepare() async {
    await allowStart.open()
    await allowCallback.open()
    await allowCancel.open()
  }
}

func signInBody(accountID: String = "new-account") throws -> Data {
  let claims = try JSONSerialization.data(withJSONObject: [
    "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": "plus"]])
  let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  return try JSONSerialization.data(withJSONObject: [
    "access_token": "login-access", "refresh_token": "login-refresh", "id_token": "header.\(payload).signature",
    "expires_in": 3600])
}
