import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_spi(Service) import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
import Testing

/// Exact codec/policy tests; no login, remote service, or model execution is claimed.
@Suite struct ChatGPTWireBoundaryTests {
  @Test func serviceLeaseOriginRejectsCredentialLeakTargets() throws {
    let profile = ChatGPTProtocolProfile.codexSubscription
    try profile.validateServiceEndpoint(profile.modelsEndpoint)
    try profile.validateServiceEndpoint(profile.imageGenerationsEndpoint)
    for value in ["http://chatgpt.com/backend-api/codex/responses",
                  "https://example.org/backend-api/codex/responses",
                  "https://chatgpt.com.evil.example/responses",
                  "https://chatgpt.com:444/backend-api/codex/responses",
                  "https://user:password@chatgpt.com/backend-api/codex/responses",
                  "https://chatgpt.com/backend-api/codex/responses#fragment"] {
      #expect(throws: ChatGPTFailure.self) {
        try profile.validateServiceEndpoint(URL(string: value)!)
      }
    }
  }
  @Test func retryBudgetPreservesSingleRefreshOnly() {
    #expect(ChatGPTSubscriptionRetryPolicy.authenticationAttemptCount == 2)
    #expect(ChatGPTSubscriptionRetryPolicy.permitsAuthenticationRefresh(after: 0))
    #expect(!ChatGPTSubscriptionRetryPolicy.permitsAuthenticationRefresh(after: 1))
  }
  @Test func sseHandlesSplitUTF8AndMultilineData() throws {
    var parser = try ChatGPTSSEParser(maxEventBytes: 256)
    let bytes = Data("data: 한글\ndata: second\n\n".utf8)
    var events: [ChatGPTSSEEvent] = []
    for byte in bytes { events += try parser.feed(Data([byte])) }
    #expect(events.map(\.data) == ["한글\nsecond"])
  }
  @Test func sseDiscardsUnterminatedEvent() throws {
    var parser = try ChatGPTSSEParser(maxEventBytes: 256)
    #expect(try parser.feed(Data("data: unfinished".utf8)).isEmpty)
    #expect(try parser.feed(Data(), finish: true).isEmpty)
  }
  @Test func sseBoundsEventCountAndFrameBytes() throws {
    var parser = try ChatGPTSSEParser(maxEventBytes: 32, maxEvents: 1)
    #expect(try parser.feed(Data("data: first\n\n".utf8)).count == 1)
    #expect(throws: ChatGPTWireError.self) {
      try parser.feed(Data("data: second\n\n".utf8))
    }
    var small = try ChatGPTSSEParser(maxEventBytes: 8)
    #expect(throws: ChatGPTWireError.self) {
      try small.feed(Data("data: very long content\n\n".utf8))
    }
  }
  @Test func imageOwnsBytesWithoutModelCoreProjection() {
    let bytes = Data([0, 1, 2, 255])
    let image = ChatGPTImageContent(mimeType: "image/png", data: bytes, filename: "a.png")
    #expect(image.data == bytes && image.filename == "a.png")
  }
  @Test func imageCodecRejectsEmptyPromptAndOversizedBody() throws {
    #expect(throws: ChatGPTImageFailure.self) {
      try ChatGPTImageWireCodec.encodeGenerationRequest(
        prompt: " ", background: .auto, quality: .auto, size: "auto",
        model: ChatGPTImageLimits.model, maximumRequestBytes: 4096)
    }
    #expect(throws: ChatGPTImageFailure.self) {
      try ChatGPTImageWireCodec.encodeGenerationRequest(
        prompt: "draw a bird", background: .auto, quality: .auto, size: "auto",
        model: ChatGPTImageLimits.model, maximumRequestBytes: 1)
    }
    let body = try ChatGPTImageWireCodec.encodeGenerationRequest(
      prompt: "draw a bird", background: .auto, quality: .low, size: "1024x1024",
      model: ChatGPTImageLimits.model, maximumRequestBytes: 4096)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == ChatGPTImageLimits.model)
  }
  @Test func imageCodecRejectsMissingOrInvalidPNG() {
    for json in ["{}", "[]", "{\"data\":[{\"b64_json\":\"bm90LXBuZw==\"}]}"] {
      #expect(throws: (any Error).self) {
        try ChatGPTImageWireCodec.decodeResponse(
          Data(json.utf8), maximumImageBytes: 1024,
          maximumPNGPixelCount: 1024, maximumPNGDecodedBytes: 4096)
      }
    }
  }
  @Test func responseRejectsBodyBeforeHeadAndDuplicateHead() async throws {
    for elements: [ChatGPTTransportElement] in [
      [.body(Data([1]))],
      [.response(statusCode: 200, headers: [:]), .response(statusCode: 200, headers: [:])]
    ] {
      await #expect(throws: ChatGPTImageFailure.self) {
        try await ChatGPTImageWireCodec.response(
          transport: WireFixture(elements: elements),
          request: URLRequest(url: URL(string: "https://example.invalid")!), maximumBytes: 16)
      }
    }
  }
  @Test func responseEnforcesCumulativeByteBudget() async throws {
    await #expect(throws: ChatGPTImageFailure.self) {
      try await ChatGPTImageWireCodec.response(
        transport: WireFixture(elements: [
          .response(statusCode: 200, headers: [:]), .body(Data([1, 2])), .body(Data([3, 4]))]),
        request: URLRequest(url: URL(string: "https://example.invalid")!), maximumBytes: 3)
    }
  }
}
private struct WireFixture: ChatGPTTransport {
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws -> ChatGPTTransportInvocation {
    // All fixture values are produced synchronously before stream() returns. No I/O/task exists.
    ChatGPTTransportInvocation(
      events: try await stream(request, maxResponseBytes: maxResponseBytes),
      cancel: {}, waitForCompletion: {})
  }
  let elements: [ChatGPTTransportElement]
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error> {
    AsyncThrowingStream { continuation in
      for element in elements { continuation.yield(element) }
      continuation.finish()
    }
  }
}
