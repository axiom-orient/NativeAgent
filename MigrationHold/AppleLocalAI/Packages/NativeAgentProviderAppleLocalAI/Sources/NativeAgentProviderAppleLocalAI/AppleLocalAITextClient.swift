import Foundation
import LanguageModelCore

/// Projection of an admitted frozen request, not a second conversation store.
struct AppleLocalAITextRequest: Sendable {
  let instructions: String
  let history: [AgentMessage]
  let prompt: String
  let maximumOutputBytes: Int

  init(_ request: ModelRequest, descriptor: ModelDescriptor) throws {
    try request.validateGenerationContract()
    try descriptor.validateGenerationContract()
    if let requested = request.modelID, requested != descriptor.id {
      throw ModelGenerationFailure(.invalidRequest, "The request selects a different model.")
    }
    guard request.effectiveRequiredCapabilities.isSubset(of: .textOnly),
      request.tools.isEmpty, !request.containsNonTextContent,
      request.outputFormat == .text
    else {
      throw ModelGenerationFailure(.policyViolation,
        "This adapter admits text-only requests without tools, media, reasoning, or structured output.")
    }
    guard let last = request.messages.last, last.role == .user, !last.content.isEmpty else {
      throw ModelGenerationFailure(.invalidRequest, "A nonempty final user message is required.")
    }
    for (index, message) in request.messages.enumerated() {
      guard message.role != .tool, message.toolCalls.isEmpty,
        message.toolCallID == nil, message.toolName == nil,
        message.reasoningSummary == nil
      else {
        throw ModelGenerationFailure(.policyViolation, "Tool and reasoning history cannot be projected by this adapter.")
      }
      if message.role == .system && index != 0 {
        throw ModelGenerationFailure(.policyViolation, "Only one leading system message is supported; roles are never reordered.")
      }
    }
    instructions = request.messages.first?.role == .system ? request.messages[0].content : ""
    history = Array(request.messages.dropLast().filter { $0.role != .system })
    prompt = last.content
    maximumOutputBytes = min(request.maxOutputBytes, request.limits.maxOutputBytes)
  }

  func validateOutput(_ text: String) throws {
    guard text.utf8.count <= maximumOutputBytes else {
      throw ModelGenerationFailure(.limitExceeded, "The native response exceeded the frozen output byte limit.")
    }
  }
}

/// The native effect is injected only inside this package. The public factory
/// always installs the real AppleLocalAISession implementation.
struct AppleLocalAITextClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  private let descriptor: ModelDescriptor
  private let respond: @Sendable (AppleLocalAITextRequest) async throws -> String

  init(
    descriptor: ModelDescriptor,
    respond: @escaping @Sendable (AppleLocalAITextRequest) async throws -> String
  ) throws {
    try descriptor.validateGenerationContract()
    guard descriptor.capabilities == .textOnly else {
      throw ModelGenerationFailure(.invalidRequest, "This adapter may advertise only text input and output.")
    }
    self.providerID = descriptor.providerID
    self.modelDescriptor = descriptor
    self.descriptor = descriptor
    self.respond = respond
  }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    let invocation = AppleLocalAITextInvocation(request: request, descriptor: descriptor, respond: respond)
    // Deliberately pull-based. Cancellation cannot report native drain merely
    // because a buffered AsyncThrowingStream terminated before its producer.
    return AsyncThrowingStream(unfolding: { try await invocation.next() })
  }
}

private actor AppleLocalAITextInvocation {
  private enum Phase {
    case preflight
    case invoke(AppleLocalAITextRequest)
    case finished
  }
  private var phase: Phase = .preflight
  private let request: ModelRequest
  private let descriptor: ModelDescriptor
  private let respond: @Sendable (AppleLocalAITextRequest) async throws -> String

  init(
    request: ModelRequest,
    descriptor: ModelDescriptor,
    respond: @escaping @Sendable (AppleLocalAITextRequest) async throws -> String
  ) {
    self.request = request
    self.descriptor = descriptor
    self.respond = respond
  }

  func next() async throws -> ModelEvent? {
    do {
      try Task.checkCancellation()
      switch phase {
      case .preflight:
        let projection = try AppleLocalAITextRequest(request, descriptor: descriptor)
        phase = .invoke(projection)
        return .started(descriptor: descriptor)
      case .invoke(let projection):
        phase = .finished
        let text = try await respond(projection)
        try Task.checkCancellation()
        try projection.validateOutput(text)
        // No tokenizer-based usage or stop reason has been independently
        // qualified for every native conformer. Do not invent either value.
        return .completed(ModelTurn(content: text))
      case .finished:
        return nil
      }
    } catch is CancellationError {
      phase = .finished
      throw ModelGenerationFailure(.cancelled, "Native model generation was cancelled.")
    } catch {
      phase = .finished
      throw error
    }
  }
}
