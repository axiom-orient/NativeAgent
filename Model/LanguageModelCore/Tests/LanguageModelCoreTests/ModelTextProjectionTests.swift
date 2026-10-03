import LanguageModelCore
import Testing

@Suite("Exact text projection")
struct ModelTextProjectionTests {
  @Test func whitespaceAndHistoryOrderAreUnchanged() throws {
    let request = ModelRequest(
      sessionID: "text",
      messages: [
        .init(role: .system, content: " rules\n"), .init(role: .user, content: "one"),
        .init(role: .assistant, content: "two"), .init(role: .user, content: "  three\n"),
      ], tools: [])
    let value = try ModelTextRequest(request, descriptor: descriptor)
    #expect(value.instructions == " rules\n")
    #expect(value.history.map(\.content) == ["one", "two"])
    #expect(value.prompt == "  three\n")
  }
  @Test func midTranscriptInstructionsAndReasoningCannotBeSilentlyDropped() throws {
    let inputs: [[AgentMessage]] = [
      [
        .init(role: .user, content: "one"), .init(role: .system, content: "late"),
        .init(role: .user, content: "two"),
      ],
      [
        .init(role: .assistant, content: "answer", reasoningSummary: "reason"),
        .init(role: .user, content: "next"),
      ],
    ]
    for messages in inputs {
      #expect(throws: ModelGenerationFailure.self) {
        _ = try ModelTextRequest(
          ModelRequest(sessionID: "text", messages: messages, tools: []), descriptor: descriptor)
      }
    }
  }
  @Test func appendedCombiningMarkUsesBytePrefixNotCharacterCount() throws {
    var accumulator = ModelTextSnapshotAccumulator(request: request())
    #expect(try accumulator.receive("e") == ["e"])
    #expect(try accumulator.receive("e\u{301}") == ["\u{301}"])
    #expect(try accumulator.finish().utf8.elementsEqual("e\u{301}".utf8))
  }
  @Test func canonicallyEquivalentRewriteIsNotAnExactExtension() throws {
    var accumulator = ModelTextSnapshotAccumulator(request: request())
    _ = try accumulator.receive("e\u{301}")
    #expect(throws: ModelGenerationFailure.self) { _ = try accumulator.receive("\u{e9}") }
  }
  @Test func noSnapshotIsNotAnEmptySuccessfulResponse() throws {
    let accumulator = ModelTextSnapshotAccumulator(request: request())
    #expect(throws: ModelGenerationFailure.self) { _ = try accumulator.finish() }
  }
  @Test func cumulativeByteLimitIsEnforcedBeforeBuffering() throws {
    var accumulator = ModelTextSnapshotAccumulator(request: request(maximum: 4))
    _ = try accumulator.receive("abc")
    #expect(throws: ModelGenerationFailure.self) { _ = try accumulator.receive("abcde") }
    #expect(try accumulator.finish() == "abc")
  }
  private var descriptor: ModelDescriptor {
    .init(id: "model", providerID: "test", capabilities: .textOnly)
  }
  private func request(maximum: Int = 100) -> ModelRequest {
    .init(
      sessionID: "text", messages: [.init(role: .user, content: "hi")], tools: [],
      maxOutputBytes: maximum)
  }
}
