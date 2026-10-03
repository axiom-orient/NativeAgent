import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount

@Test(.timeLimit(.minutes(1))) func cancelledSignOutCallerStillJoinsCleanup() async throws {
  let receipt = ReceiptGate()
  let finished = Signal()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let refresh = Task { try await session.access(forceRefresh: true) }
  await receipt.entered.wait()
  let logout = Task {
    try await session.signOut()
    await finished.open()
  }
  await receipt.cancelled.wait()
  logout.cancel()
  _ = try await session.status()
  #expect(store.deletions == 0)
  #expect(await !finished.isOpen)
  await receipt.release.open()
  try await logout.value
  _ = await refresh.result
  #expect(store.deletions == 1)
  #expect(await finished.isOpen)
}

@Test(.timeLimit(.minutes(1))) func signOutBlocksNewAuthorizationUntilCleanupSettles() async throws {
  let receipt = ReceiptGate()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let refresh = Task { try await session.access(forceRefresh: true) }
  await receipt.entered.wait()
  let logout = Task { try await session.signOut() }
  await receipt.cancelled.wait()
  let newcomer = Task { try await session.requestAuthorization() }
  await receipt.release.open()
  try await logout.value
  _ = await refresh.result
  await #expect(throws: ChatGPTFailure(.signInRequired)) { try await newcomer.value }
  #expect(receipt.calls == 1)
}

@Test func deleteFailureBlocksAccessUntilExplicitSuccessfulSignOut() async throws {
  let receipt = ReceiptGate()
  let store = MemoryCredentials(token: expiredToken())
  store.failDelete = true
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.signOut() }
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.access() }
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.beginSignIn() }
  #expect(receipt.calls == 0)
  store.failDelete = false
  try await session.signOut()
  try await session.signOut()
  #expect(store.deletions == 2) // one failed attempt + one explicit recovery
  #expect(try await session.status() == .signedOut)
}

@Test func failedRefreshDrainCannotBeRetriedOrReportedAsSuccessfulLogout() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt, failDrain: true))
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.access() }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.access() }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.signOut() }
  #expect(try store.load() == nil) // revocation attempted; this is NOT a receipt
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.status() }
  #expect(receipt.calls == 1)
}

@Test func simultaneousExpiredCredentialReadsUseOneRefresh() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let values = try await withThrowingTaskGroup(of: ChatGPTTokenSet.self) { group in
    for _ in 0..<40 { group.addTask { try await session.access() } }
    var values: [ChatGPTTokenSet] = []
    for try await value in group { values.append(value) }
    return values
  }
  #expect(values.count == 40)
  #expect(values.allSatisfy { $0.accessToken == "new-access" })
  #expect(receipt.calls == 1)
}

@Test(arguments: [(400, "invalid_grant", true), (401, "invalid_token", true),
  (429, "rate_limited", false), (503, "unavailable", false),
  (429, "invalid_grant", false), (503, "invalid_grant", false)])
func refreshRejectionPreservesOnlyRecoverableCredentials(status: Int, code: String, deletes: Bool) async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let store = MemoryCredentials(token: expiredToken())
  let body = try JSONSerialization.data(withJSONObject: ["error": code])
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt, status: status, body: body))
  await #expect(throws: ChatGPTFailure(deletes ? .tokenRefreshFailed : .tokenRefreshUnavailable)) {
    try await session.access()
  }
  #expect((try store.load() == nil) == deletes)
}

@Test func clockInjectionControlsExpirationWithoutWallClockSleeps() async throws {
  let now = Date(timeIntervalSince1970: 100_000)
  let receipt = ReceiptGate()
  await receipt.release.open()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt), now: { now })
  let token = try await session.access()
  #expect(token.expiresAt == now.addingTimeInterval(3600))
  #expect(try await session.status() == .ready(token.account))
}

@Test func staleAuthorizationSnapshotIsInvalidAfterSignOut() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let authorization = try await session.requestAuthorization()
  try await session.signOut()
  await #expect(throws: ChatGPTFailure(.signInRequired)) { try await session.validateAuthorization(authorization) }
}

@Test func cancelledCleanupWaiterCannotCancelOwnedSharedTask() async throws {
  let entered = Signal()
  let release = Signal()
  let task = Task<Int, any Error> {
    await entered.open()
    await release.wait()
    try Task.checkCancellation()
    return 7
  }
  let operation = ChatGPTSharedOperation(task: task, cancellationOwnership: .owner)
  let waiter = Task { try await operation.value() }
  await entered.wait()
  waiter.cancel()
  await #expect(throws: CancellationError.self) { try await waiter.value }
  #expect(!task.isCancelled)
  await release.open()
  #expect(try await operation.result().get() == 7)
}

@Test func lastConsumerCancellationStillCancelsOrdinarySharedWork() async throws {
  let entered = Signal()
  let release = Signal()
  let task = Task<Int, any Error> {
    await entered.open()
    await release.wait()
    try Task.checkCancellation()
    return 7
  }
  let operation = ChatGPTSharedOperation(task: task)
  let waiter = Task { try await operation.value() }
  await entered.wait()
  waiter.cancel()
  await #expect(throws: CancellationError.self) { try await waiter.value }
  #expect(task.isCancelled)
  await release.open()
  await #expect(throws: CancellationError.self) { try await operation.result().get() }
}

@Test func failedAuthenticatedGETDrainRemainsBlockedAfterCredentialsAreDeleted() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let token = ChatGPTTokenSet(accessToken: "fresh-access", refreshToken: "refresh", idToken: "id",
    expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
    account: ChatGPTAccount(accountID: "account", plan: nil, email: nil))
  let store = MemoryCredentials(token: token)
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt, failDrain: true))
  await #expect(throws: ChatGPTTransportDrainFailure.self) {
    try await session.authenticatedGET(to: ChatGPTProtocolProfile.codexSubscription.modelsEndpoint)
  }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.signOut() }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.signOut() }
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.access() }
  #expect(try store.load() == nil)
  #expect(receipt.calls == 1)
}

@Test func refreshPersistenceFailureNeverReusesPossiblyRotatedRefreshToken() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let store = MemoryCredentials(token: expiredToken())
  store.failSave = true
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.access() }
  store.failSave = false
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.access() }
  #expect(receipt.calls == 1)
  try await session.signOut()
  #expect(try store.load() == nil)
}

@Test func permanentRejectionDeleteFailureBlocksExistingAuthorization() async throws {
  let receipt = ReceiptGate()
  await receipt.release.open()
  let token = ChatGPTTokenSet(accessToken: "fresh-access", refreshToken: "refresh", idToken: "id",
    expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
    account: ChatGPTAccount(accountID: "account", plan: nil, email: nil))
  let store = MemoryCredentials(token: token)
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt, status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
  let snapshot = try await session.requestAuthorization()
  store.failDelete = true
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.access(forceRefresh: true) }
  await #expect(throws: ChatGPTFailure(.credentialStorageFailed)) { try await session.validateAuthorization(snapshot) }
  store.failDelete = false
  try await session.signOut()
  #expect(receipt.calls == 1)
}
