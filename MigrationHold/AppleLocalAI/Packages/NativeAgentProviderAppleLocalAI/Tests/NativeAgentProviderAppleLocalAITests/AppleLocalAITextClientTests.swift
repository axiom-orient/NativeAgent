import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing
@testable import NativeAgentProviderAppleLocalAI

private actor NativeEffectGate {
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<String, Never>?
  func respond() async -> String {
    entered = true
    waiters.forEach { $0.resume() }; waiters.removeAll()
    return await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() { continuation?.resume(returning: "late"); continuation = nil }
}

@Suite("AppleLocalAI text adapter contract; no native model inference")
struct AppleLocalAITextClientTests {
  private var descriptor: ModelDescriptor {
    ModelDescriptor(id: "selected", providerID: "native.local", capabilities: .textOnly)
  }
  private func request(
    _ messages: [AgentMessage] = [AgentMessage(role: .user, content: "hello")],
    capabilities: ModelCapabilities = .textOnly,
    modelID: String? = "selected",
    outputFormat: ModelOutputFormat = .text,
    maxOutputBytes: Int? = nil
  ) -> ModelRequest {
    ModelRequest(sessionID: "session", modelID: modelID, messages: messages, tools: [],
      requiredCapabilities: capabilities, outputFormat: outputFormat, maxOutputBytes: maxOutputBytes)
  }

  @Test func projectionPreservesWhitespaceUnicodeIDsAndRoles() throws {
    let history = [AgentMessage(id: "s", role: .system, content: "  system\n"),
      AgentMessage(id: "u", role: .user, content: "prior"),
      AgentMessage(id: "a", role: .assistant, content: "answer"),
      AgentMessage(id: "p", role: .user, content: "  e\u{301} 👨‍👩‍👧‍👦 한글\n")]
    let plan = try AppleLocalAITextRequest(request(history), descriptor: descriptor)
    #expect(Array(plan.prompt.utf8) == Array(history.last!.content.utf8))
    #expect(plan.instructions == "  system\n")
    #expect(plan.history == Array(history[1...2]))
  }

  @Test func unsupportedRequirementsFailBeforeStartedOrEffect() async throws {
    let client = try AppleLocalAITextClient(descriptor: descriptor) { _ in
      Issue.record("Unsupported request reached the effect"); return "invalid"
    }
    for capability: ModelCapabilities in [.streaming, .toolCalls, .imageInput, .audioInput, .reasoning, .structuredOutput] {
      var iterator = client.stream(request: request(capabilities: [.textOnly, capability])).makeAsyncIterator()
      do { _ = try await iterator.next(); Issue.record("Unsupported capability emitted an event") }
      catch let error as ModelGenerationFailure { #expect(error.code == .policyViolation) }
    }
  }

  @Test func reorderedInstructionsAndToolHistoryAreRejected() {
    for messages in [
      [AgentMessage(role: .user, content: "one"), AgentMessage(role: .system, content: "two"), AgentMessage(role: .user, content: "three")],
      [AgentMessage(role: .system, content: "one"), AgentMessage(role: .system, content: "two"), AgentMessage(role: .user, content: "three")],
      [AgentMessage(role: .tool, content: "result", toolCallID: "call"), AgentMessage(role: .user, content: "next")],
    ] {
      #expect(throws: (any Error).self) {
        _ = try AppleLocalAITextRequest(request(messages), descriptor: descriptor)
      }
    }
  }

  @Test func wrongModelAndMissingFinalUserAreRejected() {
    #expect(throws: (any Error).self) {
      _ = try AppleLocalAITextRequest(request(modelID: "other"), descriptor: descriptor)
    }
    #expect(throws: (any Error).self) {
      _ = try AppleLocalAITextRequest(request([AgentMessage(role: .assistant, content: "last")]), descriptor: descriptor)
    }
  }

  @Test func completionIsExactlyOnceAndDoesNotInventUsageOrStopReason() async throws {
    let client = try AppleLocalAITextClient(descriptor: descriptor) { _ in "한글" }
    var events: [ModelEvent] = []
    for try await event in client.stream(request: request()) { events.append(event) }
    #expect(events == [.started(descriptor: descriptor), .completed(ModelTurn(content: "한글"))])
    let turn = try await client.generate(request: request())
    #expect(turn.content == "한글")
    #expect(turn.usage == nil)
    #expect(turn.stopReason == nil)
  }

  @Test func byteLimitIsNotCharacterLimit() async throws {
    let client = try AppleLocalAITextClient(descriptor: descriptor) { _ in "한글" }
    do {
      _ = try await client.generate(request: request(maxOutputBytes: 5))
      Issue.record("Six UTF-8 bytes passed a five-byte limit")
    } catch let failure as ModelGenerationFailure { #expect(failure.code == .limitExceeded) }
    #expect(try await client.generate(request: request(maxOutputBytes: 6)).content == "한글")
  }

  @Test func originalTypedFailureSurvivesTheBoundary() async throws {
    let expected = ModelGenerationFailure(.sourceUnavailable, "not ready")
    let client = try AppleLocalAITextClient(descriptor: descriptor) { _ in throw expected }
    do { _ = try await client.generate(request: request()); Issue.record("Failure was hidden") }
    catch let actual as ModelGenerationFailure { #expect(actual == expected) }
  }

  @Test func runtimeKeepsDrainingUntilTheActualEffectReturns() async throws {
    let gate = NativeEffectGate()
    let client = try AppleLocalAITextClient(descriptor: descriptor) { _ in await gate.respond() }
    let runtime = try ModelRuntime(id: .init(rawValue: "test.runtime"), client: client)
    let run = try await runtime.start(request())
    await gate.waitUntilEntered()
    let cancellation = Task { await run.cancel() }
    for _ in 0..<1_000 {
      if await runtime.status().phase == .draining { break }
      await Task.yield()
    }
    #expect(await runtime.status().phase == .draining)
    do { _ = try await runtime.reserve(request()); Issue.record("Replacement entered before drain") }
    catch let failure as ModelRuntimeFailure { #expect(failure.code == .busy) }
    await gate.release()
    await cancellation.value
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
    #expect(await runtime.status().phase == .closed)
  }
}
