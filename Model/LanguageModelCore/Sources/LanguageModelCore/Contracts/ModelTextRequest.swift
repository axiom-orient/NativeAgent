import Foundation

/// Projection of an admitted frozen request, not a second conversation store.
public struct ModelTextRequest: Sendable {
  public let instructions: String
  public let history: [AgentMessage]
  public let prompt: String
  public let maximumOutputBytes: Int

  public init(_ request: ModelRequest, descriptor: ModelDescriptor) throws {
    try request.validateGenerationContract()
    try descriptor.validateGenerationContract()
    if let requested = request.modelID, requested != descriptor.id {
      throw ModelGenerationFailure(.invalidRequest, "The request selects a different model.")
    }
    guard
      request.effectiveRequiredCapabilities.isSubset(of: [.textInput, .textOutput, .streaming]),
      request.tools.isEmpty, !request.containsNonTextContent,
      request.outputFormat == .text
    else {
      throw ModelGenerationFailure(
        .policyViolation,
        "This adapter admits text-only requests without tools, media, reasoning, or structured output."
      )
    }
    guard let last = request.messages.last, last.role == .user, !last.content.isEmpty else {
      throw ModelGenerationFailure(.invalidRequest, "A nonempty final user message is required.")
    }
    for (index, message) in request.messages.enumerated() {
      guard message.role != .tool, message.toolCalls.isEmpty,
        message.toolCallID == nil, message.toolName == nil,
        message.reasoningSummary == nil
      else {
        throw ModelGenerationFailure(
          .policyViolation, "Tool and reasoning history cannot be projected by this adapter.")
      }
      if message.role == .system && index != 0 {
        throw ModelGenerationFailure(
          .policyViolation,
          "Only one leading system message is supported; roles are never reordered.")
      }
    }
    instructions = request.messages.first?.role == .system ? request.messages[0].content : ""
    history = Array(request.messages.dropLast().filter { $0.role != .system })
    prompt = last.content
    maximumOutputBytes = min(request.maxOutputBytes, request.limits.maxOutputBytes)
  }

  public func validateOutput(_ text: String) throws {
    guard text.utf8.count <= maximumOutputBytes else {
      throw ModelGenerationFailure(
        .limitExceeded, "The native response exceeded the frozen output byte limit.")
    }
  }
}
