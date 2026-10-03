import Foundation
import LanguageModelCore
import Testing

@testable import AppleSystemModelProvider

#if canImport(FoundationModels)
  import FoundationModels
#endif

@Suite("Apple Foundation Models adapter")
struct FoundationModelsClientTests {
  #if canImport(FoundationModels)
    @Test func canonicalMultiTurnHistoryBecomesNativeTranscript() throws {
      let request = ModelRequest(
        sessionID: "history",
        messages: [
          .init(id: "system-1", role: .system, content: "system"),
          .init(id: "user-1", role: .user, content: "one"),
          .init(id: "assistant-1", role: .assistant, content: "answer"),
          .init(id: "user-2", role: .user, content: "two"),
        ],
        tools: [])

      let conversation = try FoundationModelsClient.conversation(for: request)
      let entries = Array(conversation.transcript)

      #expect(conversation.prompt == "two")
      #expect(entries.count == 3)
      if case .instructions(let instructions) = entries[0] {
        #expect(text(instructions.segments) == "system")
      } else {
        Issue.record("System content must remain native instructions.")
      }
      if case .prompt(let prompt) = entries[1] {
        #expect(prompt.id == "user-1")
        #expect(text(prompt.segments) == "one")
      } else {
        Issue.record("User history must remain a native prompt.")
      }
      if case .response(let response) = entries[2] {
        #expect(response.id == "assistant-1")
        #expect(text(response.segments) == "answer")
      } else {
        Issue.record("Assistant history must remain a native response.")
      }
    }

  #endif

  @Test func cumulativeSnapshotsBecomeBoundedDeltasAndOneTerminalTurn() async throws {
    let client = client { _ in snapshots(["hel", "hello"]) }
    let request = textRequest()
    var events: [ModelEvent] = []
    for try await event in client.stream(request: request) { events.append(event) }

    #expect(
      events == [
        .started(descriptor: nil),
        .textDelta("hel"),
        .textDelta("lo"),
        .completed(ModelTurn(content: "hello")),
      ])
    #expect(try await client.generate(request: request).content == "hello")
  }

  @Test func unavailableModelFailsBeforeInvocation() async throws {
    let called = InvocationFlag()
    let client = FoundationModelsClient(
      availability: { .appleIntelligenceNotEnabled },
      responses: { _ in
        called.mark()
        return .init(snapshots: snapshots(["unexpected"]), cancel: {}, waitForCompletion: {})
      })
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await client.generate(request: textRequest())
    }
    #expect(!called.value)
  }

  @Test func snapshotsMustBeMonotonicAndRespectOutputBounds() async throws {
    let nonmonotonic = client { _ in snapshots(["hello", "help"]) }
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await nonmonotonic.generate(request: textRequest())
    }

    let limits = try ModelGenerationLimits(maxOutputBytes: 4)
    let oversized = client { _ in snapshots(["hello"]) }
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await oversized.generate(
        request: ModelRequest(
          sessionID: "bounded",
          messages: [.init(role: .user, content: "hello")],
          tools: [],
          limits: limits))
    }
  }

  @Test func structuredOutputIsRejectedUntilNativeGuidedGenerationIsImplemented() async throws {
    let called = InvocationFlag()
    let schema: JSONValue = .object(["type": .string("object")])
    let request = ModelRequest(
      sessionID: "json",
      messages: [.init(role: .user, content: "json")],
      tools: [],
      outputFormat: .jsonObject(schema: schema))
    let client = self.client { _ in
      called.mark()
      return snapshots([#"{"ok":true}"#])
    }

    do {
      _ = try await client.generate(request: request)
      Issue.record("Prompt-only JSON must not be advertised as structured output.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .policyViolation)
    }
    #expect(!called.value)
  }

  @Test func mediaToolsAndToolMessagesFailBeforeInvocation() async throws {
    let called = InvocationFlag()
    let client = self.client { _ in
      called.mark()
      return snapshots(["unexpected"])
    }
    let media = AgentMessage(
      role: .user,
      contentParts: [.image(.init(mimeType: "image/png", data: Data([1])))])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await client.generate(
        request: ModelRequest(
          sessionID: "media", messages: [media], tools: []))
    }
    let tool = ModelTool(name: "lookup", description: "Lookup", inputSchema: .object([:]))
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await client.generate(
        request: ModelRequest(
          sessionID: "tool", messages: [.init(role: .user, content: "lookup")], tools: [tool]))
    }
    #expect(!called.value)
  }

  @Test func cancellationFinishesWithStableFailure() async throws {
    let client = FoundationModelsClient(
      availability: { .available },
      responses: { _ in
        let pair = AsyncThrowingStream<String, any Error>.makeStream()
        let producer = Task {
          do {
            try await Task.sleep(for: .seconds(30))
            pair.continuation.finish()
          } catch { pair.continuation.finish(throwing: error) }
        }
        return .init(
          snapshots: pair.stream, cancel: { producer.cancel() },
          waitForCompletion: { await producer.value })
      })
    let task = Task { try await client.generate(request: textRequest()) }
    await Task.yield()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancellation must fail.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .cancelled)
    }
  }

  #if canImport(FoundationModels)
    private func text(_ segments: [Transcript.Segment]) -> String? {
      guard segments.count == 1, case .text(let text) = segments[0] else { return nil }
      return text.content
    }

  #endif

  private func client(
    responses: @escaping @Sendable (ModelRequest) -> AsyncThrowingStream<String, any Error>
  ) -> FoundationModelsClient {
    FoundationModelsClient(
      availability: { .available },
      responses: { request in
        .init(snapshots: responses(request), cancel: {}, waitForCompletion: {})
      })
  }

  private func textRequest() -> ModelRequest {
    ModelRequest(
      sessionID: "apple",
      messages: [.init(role: .user, content: "hello")],
      tools: [])
  }

  private func snapshots(_ values: [String]) -> AsyncThrowingStream<String, any Error> {
    AsyncThrowingStream { continuation in
      for value in values { continuation.yield(value) }
      continuation.finish()
    }
  }
}

private final class InvocationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false
  func mark() { lock.withLock { stored = true } }
  var value: Bool { lock.withLock { stored } }
}
