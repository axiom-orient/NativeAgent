import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@testable import NativeAgentProviderAppleLocalAI

@Suite("Borrowed native runtime projection and identity")
struct NativeRuntimeBindingTests {
  @Test func configurationUsesReferenceNotDisplayIdentity() throws {
    let first = try runtime()
    let second = try runtime()
    let a = binding(first)
    let b = binding(first)
    let c = binding(second)
    #expect(a == b)
    #expect(a != c)  // Deliberately identical ModelRuntimeID strings.
    #expect(Set([a, b, c]).count == 2)
    #expect(a != NativeRuntimeBinding(runtime: first, sessionID: "other", limits: .default))
  }

  @Test func exactHistorySchemaAndLimitsArePreserved() throws {
    let selected = try runtime(capabilities: [.textInput, .textOutput, .structuredOutput])
    let limits = try ModelGenerationLimits(maxOutputBytes: 123, maxDeadline: .seconds(4))
    let bound = NativeRuntimeBinding(runtime: selected, sessionID: "session", limits: limits)
    let messages: [AgentMessage] = [
      .init(id: "i", role: .system, content: "  literal\n"),
      .init(id: "u1", role: .user, content: "이전 질문"),
      .init(id: "a1", role: .assistant, content: "answer\n"),
      .init(id: "u2", role: .user, content: "  final\n"),
    ]
    let schema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])
    let request = try bound.request(messages: messages, schema: schema)
    #expect(request.messages == messages)
    #expect(request.modelID == selected.modelDescriptor.id)
    #expect(request.outputFormat == .jsonObject(schema: schema))
    #expect(request.maxOutputBytes == 123)
    #expect(request.deadline == .seconds(4))
    #expect(request.tools.isEmpty)
    #expect(request.metadata.isEmpty)
    #expect(try bound.request(messages: messages, schema: schema) == request)
  }

  @Test func unsupportedSchemaRejectedBeforeInvocation() async throws {
    let selected = try runtime()
    #expect(throws: ModelGenerationFailure.self) {
      _ = try binding(selected).request(
        messages: messages(), schema: .object(["type": .string("object")]))
    }
    #expect(await selected.status().phase == .idle)
  }

  @Test func emptyAndAssistantTerminalHistoryAreRejected() throws {
    let bound = binding(try runtime())
    #expect(throws: NativeRuntimeBridgeError.unsupportedTranscript) {
      _ = try bound.request(messages: [])
    }
    #expect(throws: NativeRuntimeBridgeError.unsupportedTranscript) {
      _ = try bound.request(messages: [.init(role: .assistant, content: "not a prompt")])
    }
  }

  @Test func toolAndReasoningHistoryAreNotSilentlyDiscarded() throws {
    let bound = binding(try runtime())
    #expect(throws: NativeRuntimeBridgeError.unsupportedTranscript) {
      _ = try bound.request(messages: [.init(role: .tool, content: "result")] + messages())
    }
    #expect(throws: NativeRuntimeBridgeError.unsupportedTranscript) {
      _ = try bound.request(
        messages: [.init(role: .assistant, content: "answer", reasoningSummary: "reason")]
          + messages())
    }
  }

  @Test func invalidLogicalSessionIDUsesCoreValidation() throws {
    let bound = NativeRuntimeBinding(runtime: try runtime(), sessionID: "", limits: .default)
    #expect(throws: ModelGenerationFailure.self) { _ = try bound.request(messages: messages()) }
  }

  @Test func coreInputByteLimitsAreNotBypassed() throws {
    let bound = NativeRuntimeBinding(
      runtime: try runtime(), sessionID: "session",
      limits: try ModelGenerationLimits(maxMessageBytes: 2))
    #expect(throws: ModelGenerationFailure.self) { _ = try bound.request(messages: messages()) }
  }

  @Test func nativeAndAppleBindingShareAdmissionAndClosedState() async throws {
    let native = try runtime()
    let apple = binding(native)
    let request = try apple.request(messages: messages())
    let reservation = try await native.reserve(request)
    await #expect(throws: ModelRuntimeFailure.self) {
      _ = try await apple.runtime.generate(request)
    }
    #expect(await native.release(reservation))
    #expect(try await apple.runtime.generate(request).content == "same runtime")
    try await native.shutdown()
    await #expect(throws: ModelRuntimeFailure.self) {
      _ = try await apple.runtime.generate(request)
    }
  }

  @Test func terminalProviderFailureCrossesBindingWithoutFallback() async throws {
    let selected = try runtime(failure: .init(.sourceUnavailable, "test failure"))
    let apple = binding(selected)
    do {
      _ = try await apple.runtime.generate(apple.request(messages: messages()))
      Issue.record("Failure became success")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .sourceUnavailable)
    }
    #expect(await selected.status().phase == .idle)
  }
}

private struct BindingFixture: ModelClient {
  let providerID = "test.local"
  let capabilities: ModelCapabilities
  let failure: ModelGenerationFailure?
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: capabilities)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    if let failure { throw failure }
    return ModelTurn(content: "same runtime")
  }
}
private func runtime(
  capabilities: ModelCapabilities = .textOnly, failure: ModelGenerationFailure? = nil
) throws -> ModelRuntime {
  try ModelRuntime(
    id: .init(rawValue: "same.logical.id"),
    client: BindingFixture(capabilities: capabilities, failure: failure))
}
private func binding(_ runtime: ModelRuntime) -> NativeRuntimeBinding {
  NativeRuntimeBinding(runtime: runtime, sessionID: "session", limits: .default)
}
private func messages() -> [AgentMessage] { [.init(id: "u", role: .user, content: "hello")] }
