import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable @_spi(Service) import ChatGPTAccount

@Test(arguments: ["", "space id", "line\r\ninjected:yes", "tab\t", "del\u{7f}", "unicode한", String(repeating: "x", count: 513)])
func unsafeAccountHeaderValuesAreRejected(value: String) {
  #expect(throws: ChatGPTFailure(.malformedResponse)) { try expiredToken(accountID: value).validate() }
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
func nonfiniteCredentialExpirationIsRejected(seconds: Double) {
  let token = ChatGPTTokenSet(accessToken: "access", refreshToken: "refresh", idToken: "id",
    expiresAt: Date(timeIntervalSinceReferenceDate: seconds), account: expiredToken().account)
  #expect(throws: ChatGPTFailure(.malformedResponse)) { try token.validate() }
}

@Test(arguments: [0.0, 59, -1, Double.infinity, Double.nan, 31_536_001])
func invalidExpirationDurationIsRejected(seconds: Double) {
  #expect(throws: ChatGPTFailure(.malformedResponse)) {
    try ChatGPTClaims.expiration(accessToken: "opaque", expiresIn: seconds)
  }
}

@Test(arguments: [60.0, 31_536_000])
func expirationBoundaryIsDeterministic(seconds: Double) throws {
  let now = Date(timeIntervalSince1970: 100_000)
  #expect(try ChatGPTClaims.expiration(accessToken: "opaque", expiresIn: seconds, now: now)
    == now.addingTimeInterval(seconds))
}

@Test func transportReceiptFailureIsJoinedOnceAndOverridesParsingFailure() async throws {
  let counter = JoinCounter()
  let operation = ChatGPTTransportInvocation(events: AsyncThrowingStream { $0.finish() },
    cancel: {}, waitForCompletion: { counter.increment(); throw ReceiptFailure() })
  await #expect(throws: ChatGPTTransportDrainFailure.self) {
    try await operation.consuming { _ -> Int in throw ChatGPTFailure(.malformedResponse) }
  }
  #expect(counter.count == 1)
}

private final class JoinCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}
