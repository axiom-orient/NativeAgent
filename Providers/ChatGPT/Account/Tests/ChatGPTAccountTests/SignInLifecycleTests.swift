import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount

@Test func signInCommitsOnlyValidatedAccount() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let signIn = SignInPort()
  await signIn.prepare()
  let store = MemoryCredentials(token: nil)
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt, body: try signInBody()), startAuthorization: signIn.start)
  let authorization = try await session.beginSignIn()
  let account = try await session.completeSignIn(authorization)
  #expect(account.accountID == "new-account")
  #expect(try store.load()?.refreshToken == "login-refresh")
  #expect(try await session.status() == .ready(account))
}

@Test(.timeLimit(.minutes(1))) func replacementWaitsForOldRefreshAndCannotCommitItsLateToken() async throws {
  let refreshReceipt = ReceiptGate()
  let loginReceipt = ReceiptGate()
  await loginReceipt.release.open()
  let signIn = SignInPort()
  await signIn.prepare()
  let store = MemoryCredentials(token: expiredToken())
  let transport = RefreshAndSignInTransport(refresh: GatedTransport(receipt: refreshReceipt),
    signIn: GatedTransport(receipt: loginReceipt, body: try signInBody()))
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: transport, startAuthorization: signIn.start)
  let refresh = Task { try await session.access(forceRefresh: true) }
  await refreshReceipt.entered.wait()
  let authorization = try await session.beginSignIn()
  let login = Task { try await session.completeSignIn(authorization) }
  await refreshReceipt.cancelled.wait()
  #expect(try store.load()?.account.accountID == "account-1")
  await refreshReceipt.release.open()
  #expect(try await login.value.accountID == "new-account")
  _ = await refresh.result
  #expect(try store.load()?.accessToken == "login-access")
  #expect(try store.load()?.refreshToken == "login-refresh")
}

@Test(.timeLimit(.minutes(1))) func logoutWinsAgainstLateCallback() async throws {
  let receipt = ReceiptGate()
  let signIn = SignInPort()
  await signIn.allowStart.open()
  await signIn.allowCancel.open()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt), startAuthorization: signIn.start)
  let authorization = try await session.beginSignIn()
  let login = Task { try await session.completeSignIn(authorization) }
  await signIn.callbackEntered.wait()
  let logout = Task { try await session.signOut() }
  await signIn.cancelEntered.wait()
  #expect(store.deletions == 0)
  await signIn.allowCallback.open()
  try await logout.value
  _ = await login.result
  #expect(try store.load() == nil)
  #expect(receipt.calls == 0)
}

@Test(.timeLimit(.minutes(1))) func cancelledSignInCleanupCallerStillWaitsForListenerStop() async throws {
  let receipt = ReceiptGate()
  let signIn = SignInPort()
  await signIn.allowStart.open()
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: MemoryCredentials(token: nil),
    transport: GatedTransport(receipt: receipt), startAuthorization: signIn.start)
  _ = try await session.beginSignIn()
  let cleanup = Task {
    try await session.cancelSignIn()
    #expect(await signIn.stopped.isOpen)
  }
  await signIn.cancelEntered.wait()
  cleanup.cancel()
  await signIn.allowCancel.open()
  try await cleanup.value
  #expect(try await session.status() == .signedOut)
}

@Test(arguments: [
  "http://localhost:1455/auth/callback?state=wrong&code=code",
  "http://localhost:1455/auth/callback?state=test-state&state=test-state&code=code",
  "http://localhost:1457/auth/callback?state=test-state&code=code",
  "http://attacker.invalid:1455/auth/callback?state=test-state&code=code",
  "http://localhost:1455/other?state=test-state&code=code",
  "http://localhost:1455/auth/callback?state=test-state&code=code#fragment"
])
func invalidOAuthCallbackNeverDispatchesTokenExchange(callback: String) async throws {
  let signIn = SignInPort(callback: try #require(URL(string: callback)))
  await signIn.prepare()
  let receipt = ReceiptGate()
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: MemoryCredentials(token: nil),
    transport: GatedTransport(receipt: receipt), startAuthorization: signIn.start)
  let authorization = try await session.beginSignIn()
  await #expect(throws: ChatGPTFailure(.authorizationFailed)) { try await session.completeSignIn(authorization) }
  #expect(receipt.calls == 0)
}

@Test func transportDrainFailureDuringSignInBlocksNewAccountWork() async throws {
  let signIn = SignInPort()
  await signIn.prepare()
  let receipt = ReceiptGate()
  await receipt.release.open()
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: MemoryCredentials(token: nil),
    transport: GatedTransport(receipt: receipt, failDrain: true), startAuthorization: signIn.start)
  let authorization = try await session.beginSignIn()
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.completeSignIn(authorization) }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.beginSignIn() }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.signOut() }
  #expect(signIn.starts == 1)
  #expect(receipt.calls == 1)
}

@Test(.timeLimit(.minutes(1))) func cancelledReplacementReleasesItsAdmissionGateAfterJoiningRefresh() async throws {
  let refreshReceipt = ReceiptGate()
  let loginReceipt = ReceiptGate()
  await loginReceipt.release.open()
  let signIn = SignInPort()
  await signIn.prepare()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: RefreshAndSignInTransport(refresh: GatedTransport(receipt: refreshReceipt),
      signIn: GatedTransport(receipt: loginReceipt, body: try signInBody())), startAuthorization: signIn.start)
  let refresh = Task { try await session.access() }
  await refreshReceipt.entered.wait()
  let authorization = try await session.beginSignIn()
  let login = Task { try await session.completeSignIn(authorization) }
  await refreshReceipt.cancelled.wait()
  let cleanup = Task { try await session.cancelSignIn() }
  await signIn.cancelEntered.wait()
  await refreshReceipt.release.open()
  try await cleanup.value
  _ = await refresh.result
  _ = await login.result
  // A cancelled replacement may not strand the account in replacing + idle.
  _ = try await session.beginSignIn()
  try await session.cancelSignIn()
}

@Test func signInAfterLogoutReportsAuthorizationAndCanBeLoggedOutAgain() async throws {
  let port = SignInPort()
  await port.prepare()
  let store = MemoryCredentials(token: nil)
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: ReceiptGate()), startAuthorization: port.start)
  try await session.signOut()
  let authorization = try await session.beginSignIn()
  #expect(try await session.status() == .authorizing(authorization))
  try await session.signOut()
  #expect(await port.stopped.isOpen)
  #expect(store.deletions == 2)
}

@Test(arguments: [false, true]) func callbackFailureStopsListenerAndPreservesFailedStop(failStop: Bool) async throws {
  let port = SignInPort()
  let stopped = Signal()
  let receipt = ReceiptGate()
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: MemoryCredentials(token: nil),
    transport: GatedTransport(receipt: receipt), startAuthorization: { _ in
      ChatGPTSignInSession(authorization: port.authorization, waitForCallback: { _ in
        throw ChatGPTFailure(.authorizationExpired)
      }, cancel: {
        await stopped.open()
        if failStop { throw ReceiptFailure() }
      })
    })
  let authorization = try await session.beginSignIn()
  if failStop {
    await #expect(throws: ChatGPTSignInDrainFailure.self) { try await session.completeSignIn(authorization) }
    await #expect(throws: ChatGPTSignInDrainFailure.self) { try await session.beginSignIn() }
    await #expect(throws: ChatGPTSignInDrainFailure.self) { try await session.signOut() }
  } else {
    await #expect(throws: ChatGPTFailure(.authorizationExpired)) { try await session.completeSignIn(authorization) }
    _ = try await session.beginSignIn()
    try await session.cancelSignIn()
  }
  #expect(await stopped.isOpen)
  #expect(receipt.calls == 0)
}
