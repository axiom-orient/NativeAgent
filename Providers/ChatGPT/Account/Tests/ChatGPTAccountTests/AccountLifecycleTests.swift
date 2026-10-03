import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount

@Test func signOutJoinsRefreshBeforeDeletingCredentials() async throws {
  let receipt = ReceiptGate()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let refresh = Task { try await session.access(forceRefresh: true) }
  await receipt.entered.wait()
  let logout = Task { try await session.signOut() }
  await receipt.cancelled.wait()
  _ = try await session.status() // actor barrier: cancellation admission has run
  #expect(store.deletions == 0, "Credential deletion must follow the owned producer receipt")
  await receipt.release.open()
  try await logout.value
  _ = await refresh.result
  #expect(store.deletions == 1)
  #expect(try store.load() == nil)
}

@Test func concurrentSignOutsShareCleanup() async throws {
  let receipt = ReceiptGate()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let refresh = Task { try await session.access(forceRefresh: true) }
  await receipt.entered.wait()
  let first = Task { try await session.signOut() }
  await receipt.cancelled.wait()
  let second = Task { try await session.signOut() }
  await receipt.release.open()
  try await first.value
  try await second.value
  _ = await refresh.result
  #expect(store.deletions == 1, "Repeated sign-out must not repeat a completed deletion")
}

@Test func cancelledAccessDoesNotStartRefresh() async throws {
  let receipt = ReceiptGate()
  let gate = Signal()
  let store = MemoryCredentials(token: expiredToken())
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: store,
    transport: GatedTransport(receipt: receipt))
  let task = Task {
    await gate.wait()
    return try await session.access(forceRefresh: true)
  }
  task.cancel()
  await gate.open()
  await receipt.release.open()
  _ = await task.result
  #expect(receipt.calls == 0)
}
