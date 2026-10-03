import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount

private final class FailedNativeOperation: Sendable {}

private final class WeakNativeOperations: @unchecked Sendable {
  private let lock = NSLock()
  private weak var first: FailedNativeOperation?
  private weak var second: FailedNativeOperation?
  let firstReceipt = ReceiptGate()
  let secondReceipt = ReceiptGate()
  private var count = 0
  func make() -> (FailedNativeOperation, ReceiptGate) {
    lock.withLock {
      let operation = FailedNativeOperation()
      count += 1
      if count == 1 { first = operation; return (operation, firstReceipt) }
      second = operation; return (operation, secondReceipt)
    }
  }
  var allRetained: Bool { lock.withLock { first != nil && second != nil } }
}

private struct ParallelFailingTransport: ChatGPTTransport {
  let owners: WeakNativeOperations
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws -> ChatGPTTransportInvocation {
    let (owner, gate) = owners.make()
    return ChatGPTTransportInvocation(events: AsyncThrowingStream { stream in
      stream.yield(.response(statusCode: 200, headers: [:]))
      stream.yield(.body(Data("{}".utf8)))
      stream.finish()
    }, cancel: {}, waitForCompletion: {
      await gate.entered.open()
      await gate.release.wait()
      _ = owner
      throw ReceiptFailure()
    })
  }
}

@Test(.timeLimit(.minutes(1))) func accountRetainsEveryAlreadyAdmittedFailedOperation() async throws {
  let owners = WeakNativeOperations()
  let token = ChatGPTTokenSet(accessToken: "fresh-access", refreshToken: "refresh", idToken: "id",
    expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
    account: ChatGPTAccount(accountID: "account", plan: nil, email: nil))
  let session = ChatGPTAccountSession(profile: .codexSubscription, store: MemoryCredentials(token: token),
    transport: ParallelFailingTransport(owners: owners))
  let first = Task { () -> Bool in
    do { _ = try await session.authenticatedGET(to: ChatGPTProtocolProfile.codexSubscription.modelsEndpoint); return false }
    catch { return error is ChatGPTTransportDrainFailure }
  }
  await owners.firstReceipt.entered.wait()
  let second = Task { () -> Bool in
    do { _ = try await session.authenticatedGET(to: ChatGPTProtocolProfile.codexSubscription.modelsEndpoint); return false }
    catch { return error is ChatGPTTransportDrainFailure }
  }
  await owners.secondReceipt.entered.wait()
  await owners.firstReceipt.release.open()
  #expect(await first.value)
  await owners.secondReceipt.release.open()
  #expect(await second.value)
  // Tasks only retain Bool, so the account must own BOTH unproved native operations.
  #expect(owners.allRetained)
  await #expect(throws: ChatGPTTransportDrainFailure.self) { try await session.signOut() }
  #expect(owners.allRetained)
}
