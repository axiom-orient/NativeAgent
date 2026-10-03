@testable import ChatGPTText
@testable import ChatGPTImage
import Foundation
import Testing

@Suite struct ChatGPTImageErrorTests {
  @Test func invalidRequestRetainsOnlySafeDiagnostics() {
    let body = Data(#"{"error":{"code":"invalid_request","message":"private request text"}}"#.utf8)
    let failure = ChatGPTImageWireCodec.rejection(
      status: 400,
      headers: ["X-Codex-Imagegen-Request-Id": "img-123"],
      body: body)

    #expect(failure.code == .invalidRequest)
    #expect(failure.httpStatusCode == 400)
    #expect(failure.responseCode == "invalid_request")
    #expect(failure.responseReason == nil)
    #expect(failure.requestID == "img-123")
    #expect(failure.diagnosticDescription?.contains("private request text") == false)
  }

  @Test func forbiddenIsNotMisreportedAsSignedOut() {
    let body = Data(
      #"{"error":{"message":"This image route is not enabled for this account."}}"#.utf8)
    let failure = ChatGPTImageWireCodec.rejection(status: 403, headers: [:], body: body)

    #expect(failure.code == .serviceRejected)
    #expect(failure.httpStatusCode == 403)
    #expect(failure.responseReason == "This image route is not enabled for this account.")
  }

  @Test func rejectionClassificationKeepsKnownCausesDistinct() {
    #expect(rejection(401).code == .authenticationRequired)
    #expect(rejection(403).code == .serviceRejected)
    #expect(rejection(413).code == .limitExceeded)
    #expect(rejection(429).code == .rateLimited)
    #expect(rejection(503).code == .serviceRejected)
  }

  @Test func requestIDLookupIsCaseInsensitiveAndBounded() {
    #expect(ChatGPTImageWireCodec.requestID(["OpenAI-Request-ID": " req-123 "]) == "req-123")
    #expect(ChatGPTImageWireCodec.requestID(["x-request-id": String(repeating: "a", count: 129)]) == nil)
  }

  private func rejection(_ status: Int) -> ChatGPTImageFailure {
    ChatGPTImageWireCodec.rejection(status: status, headers: [:], body: Data())
  }
}

@Suite struct ChatGPTRateLimitProjectionTests {
  @Test func externallyConstructedRateLimitWindowCannotOverflow() {
    #expect(ChatGPTRateLimitWindow(usedPercent: .min).remainingPercent == 100)
    #expect(ChatGPTRateLimitWindow(usedPercent: .max).remainingPercent == 0)
    #expect(ChatGPTRateLimitWindow(usedPercent: 25).remainingPercent == 75)
  }
}
