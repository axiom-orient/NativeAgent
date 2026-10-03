import Foundation
import FoundationModels
import LanguageModelCore
import LanguageModelRuntime

/// A borrowed native runtime, exposed as an Apple language model. Destroying a
/// session/executor never unloads the runtime: the host's LocalBackend owns it.
@available(iOS 27.0, macOS 27.0, *)
public struct NativeRuntimeLanguageModel: FoundationModels.LanguageModel {
  public typealias Executor = NativeRuntimeExecutor
  public let executorConfiguration: NativeRuntimeExecutor.Configuration
  public let capabilities: LanguageModelCapabilities

  init(binding: NativeRuntimeBinding) {
    executorConfiguration = .init(binding: binding)
    capabilities =
      binding.runtime.capabilities.contains(.structuredOutput)
      ? LanguageModelCapabilities([.guidedGeneration]) : LanguageModelCapabilities([])
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct NativeRuntimeExecutor: FoundationModels.LanguageModelExecutor {
  public typealias Model = NativeRuntimeLanguageModel

  public struct Configuration: Sendable, Hashable {
    let binding: NativeRuntimeBinding
  }

  private let configuration: Configuration

  public init(configuration: Configuration) throws {
    self.configuration = configuration
  }

  public func prewarm(model: Model, transcript: Transcript) {
    // Intentionally empty: LocalBackend.load() already prepared residency.
    // Never start an unowned Task or reload weights from a per-session executor.
  }

  public nonisolated(nonsending) func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    try Task.checkCancellation()
    guard model.executorConfiguration == configuration else {
      throw NativeRuntimeBridgeError.modelMismatch
    }
    let nativeRequest = try project(request)
    // This is the SAME runtime used by NativeAgent, not a new client/gate.
    // Commit text only after validated EOF AND provider/native drain. The
    // native streaming API remains available to callers requiring live deltas.
    let turn = try await configuration.binding.runtime.generate(nativeRequest)
    try Task.checkCancellation()
    guard turn.toolCalls.isEmpty else { throw NativeRuntimeBridgeError.toolsUnsupported }
    if turn.usage?.outputTokens == nil {
      // Absence of a tokenizer measurement is explicit, not a measured zero.
      await channel.send(
        .response(
          action: .updateMetadata([
            "nativeOutputTokenUsage": "unknown"
          ])))
    }
    await channel.send(
      .response(
        action: .appendText(
          turn.content,
          // Zero means no token increment is reported, never an estimated byte or
          // character count. A known native output count is forwarded unchanged.
          tokenCount: turn.usage?.outputTokens ?? 0)))
  }

  func project(_ request: LanguageModelExecutorGenerationRequest) throws -> ModelRequest {
    if request.generationOptions.temperature != nil {
      throw NativeRuntimeBridgeError.unsupportedGenerationOption(.temperature)
    }
    if request.generationOptions.samplingMode != nil {
      throw NativeRuntimeBridgeError.unsupportedGenerationOption(.samplingMode)
    }
    if request.generationOptions.maximumResponseTokens != nil {
      throw NativeRuntimeBridgeError.unsupportedGenerationOption(.maximumResponseTokens)
    }
    if request.contextOptions.reasoningLevel != nil {
      throw NativeRuntimeBridgeError.unsupportedGenerationOption(.reasoningLevel)
    }
    if let mode = request.generationOptions.toolCallingMode, mode != .disallowed && mode != .allowed
    {
      throw NativeRuntimeBridgeError.unsupportedGenerationOption(.toolCallingMode)
    }
    guard request.metadata.isEmpty else {
      throw NativeRuntimeBridgeError.metadataUnsupported
    }
    guard request.enabledToolDefinitions.isEmpty else {
      throw NativeRuntimeBridgeError.toolsUnsupported
    }

    var messages: [AgentMessage] = try request.transcript.map { entry in
      switch entry {
      case .instructions(let value):
        guard value.toolDefinitions.isEmpty else { throw NativeRuntimeBridgeError.toolsUnsupported }
        return AgentMessage(id: value.id, role: .system, content: try text(value.segments))
      case .prompt(let value):
        return AgentMessage(id: value.id, role: .user, content: try text(value.segments))
      case .response(let value):
        return AgentMessage(id: value.id, role: .assistant, content: try text(value.segments))
      case .reasoning, .toolCalls, .toolOutput:
        throw NativeRuntimeBridgeError.unsupportedTranscript
      @unknown default:
        throw NativeRuntimeBridgeError.unsupportedTranscript
      }
    }
    let schema: JSONValue?
    if let source = request.schema {
      guard request.contextOptions.includeSchemaInPrompt else {
        throw NativeRuntimeBridgeError.unsupportedGenerationOption(.schemaPromptOmission)
      }
      let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(source))
      schema = encoded
      // Honor the requested prompt hint for providers that otherwise only
      // constrain decoding. Original transcript strings are not rewritten.
      let guidance = AgentMessage(
        role: .system,
        content:
          "Return a JSON object matching this output schema: " + (try encoded.canonicalString()))
      let instructionEnd = messages.prefix { $0.role == .system }.count
      messages.insert(guidance, at: instructionEnd)
    } else {
      schema = nil
    }
    return try configuration.binding.request(messages: messages, schema: schema)
  }

  private func text(_ segments: [Transcript.Segment]) throws -> String {
    try segments.map { segment in
      switch segment {
      case .text(let value):
        return value.content
      case .structure(let value):
        guard value.content.isComplete else {
          throw NativeRuntimeBridgeError.unsupportedTranscript
        }
        // Structured history has no original text bytes. Use Apple's JSON
        // representation, not description/debugDescription or prompt guessing.
        return value.content.jsonString
      default:
        throw NativeRuntimeBridgeError.unsupportedTranscript
      }
    }.joined()  // Preserve exactly; do not inject spaces or normalize whitespace.
  }
}

extension NativeAgentProviderAppleLocalAI {
  /// Host owns `runtime` through LocalBackend. Each session supplies its own
  /// logical ID and limit policy; all sessions share runtime admission.
  public static func makeLanguageModel(
    runtime: ModelRuntime,
    sessionID: String,
    limits: ModelGenerationLimits = .default
  ) -> NativeRuntimeLanguageModel {
    NativeRuntimeLanguageModel(
      binding: .init(runtime: runtime, sessionID: sessionID, limits: limits))
  }
}
