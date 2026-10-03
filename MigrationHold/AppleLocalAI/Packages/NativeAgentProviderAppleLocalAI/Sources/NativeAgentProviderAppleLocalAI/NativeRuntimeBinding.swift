import Foundation
import LanguageModelCore
import LanguageModelRuntime

/// Fail-closed translation errors. Sampling and token budgets belong to the
/// selected native model configuration; this bridge never silently ignores them.
public enum NativeRuntimeBridgeError: Error, Sendable, Equatable {
  public enum GenerationOption: Sendable, Equatable {
    case temperature, samplingMode, maximumResponseTokens, reasoningLevel, toolCallingMode,
      schemaPromptOmission
  }
  case unsupportedGenerationOption(GenerationOption)
  case metadataUnsupported
  case unsupportedTranscript
  case toolsUnsupported
  case recursiveComposition
  case modelMismatch
}

/// Pure request projection and reference identity. No model loader, cache,
/// transcript, task, or independent invocation gate is introduced here.
struct NativeRuntimeBinding: Sendable, Hashable {
  let runtime: ModelRuntime
  let sessionID: String
  let limits: ModelGenerationLimits

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.runtime === rhs.runtime && lhs.sessionID == rhs.sessionID && lhs.limits == rhs.limits
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(runtime))
    hasher.combine(sessionID)
    hasher.combine(limits)
  }

  func request(messages: [AgentMessage], schema: JSONValue? = nil) throws -> ModelRequest {
    // Do not drop tool/media/reasoning history or decorate the caller's text.
    guard
      messages.allSatisfy({ message in
        message.role != .tool && message.toolCallID == nil && message.toolName == nil
          && message.toolCalls.isEmpty && message.reasoningSummary == nil
          && message.contentParts.allSatisfy { if case .text = $0 { true } else { false } }
      }), messages.last?.role == .user
    else {
      throw NativeRuntimeBridgeError.unsupportedTranscript
    }
    let request = ModelRequest(
      sessionID: sessionID, modelID: runtime.modelDescriptor.id,
      messages: messages, tools: [],
      outputFormat: schema.map { .jsonObject(schema: $0) } ?? .text,
      limits: limits
    )
    try request.validateGenerationContract()
    try request.validateSupportedCapabilities(runtime.capabilities)
    return request
  }
}
