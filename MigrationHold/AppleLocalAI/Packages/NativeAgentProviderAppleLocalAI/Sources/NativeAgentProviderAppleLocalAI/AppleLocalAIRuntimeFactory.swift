import AppleLocalAI
import FoundationModels
import LanguageModelCore
import LanguageModelRuntime

/// OS 27 opt-in. Selection, model preparation, availability, privacy consent,
/// shared residency and cleanup remain explicit caller responsibilities.
/// This does not install tools, load models, or fall back to another provider.
@available(iOS 27.0, macOS 27.0, *)
public enum NativeAgentProviderAppleLocalAI {
  @MainActor
  public static func makeRuntime(
    model: any FoundationModels.LanguageModel,
    runtimeID: ModelRuntimeID,
    providerID: String,
    modelID: String,
    displayName: String? = nil,
    policy: ModelRuntimePolicy = .default,
    cleanup: @escaping @Sendable () async throws -> Void
  ) throws -> ModelRuntime {
    guard !(model is NativeRuntimeLanguageModel) else {
      throw NativeRuntimeBridgeError.recursiveComposition
    }
    let descriptor = ModelDescriptor(
      id: modelID, providerID: providerID, displayName: displayName,
      capabilities: .textOnly
    )
    let client = try AppleLocalAITextClient(descriptor: descriptor) { request in
      try await respond(model: model, request: request)
    }
    return try ModelRuntime(id: runtimeID, client: client, descriptor: descriptor, policy: policy, cleanup: cleanup)
  }

  @MainActor
  private static func respond(
    model: any FoundationModels.LanguageModel,
    request: AppleLocalAITextRequest
  ) async throws -> String {
    try Task.checkCancellation()
    let profile = try AppleLocalAIProfile(
      model: model,
      instructions: request.instructions,
      tools: [],
      historyPolicy: .full
    )
    let history: [Transcript.Entry] = request.history.map { message in
      let segment = Transcript.Segment.text(
        Transcript.TextSegment(id: "\(message.id)-text", content: message.content)
      )
      switch message.role {
      case .user:
        return .prompt(Transcript.Prompt(id: message.id, segments: [segment]))
      case .assistant:
        return .response(Transcript.Response(id: message.id, assetIDs: [], segments: [segment]))
      case .system, .tool:
        // The pure request projection excludes these cases before .started.
        preconditionFailure("An unadmitted role crossed the native projection boundary")
      }
    }
    let session = AppleLocalAISession(profile: profile, history: history)
    var outputFailure: ModelGenerationFailure?
    do {
      // Native Prompt avoids the text initializer's whitespace normalization.
      let response = try await session.stream(
        AppleLocalAIRequest(prompt: Prompt(request.prompt)),
        onSnapshot: { snapshot in
          guard outputFailure == nil else { return }
          do { try request.validateOutput(snapshot.text) }
          catch {
            outputFailure = ModelGenerationFailure(
              .limitExceeded, "The native response exceeded the frozen output byte limit.")
            session.cancel()
          }
        }
      )
      if let outputFailure { throw outputFailure }
      try request.validateOutput(response.text)
      return response.text
    } catch {
      if let outputFailure { throw outputFailure }
      if error is CancellationError { throw CancellationError() }
      if let nativeError = error as? AppleLocalAIError, case .cancelled = nativeError {
        throw CancellationError()
      }
      if let failure = error as? ModelGenerationFailure { throw failure }
      if let failure = error as? LanguageModelSession.GenerationError {
        throw map(failure)
      }
      throw ModelGenerationFailure(.transportFailure, "The selected native model failed.")
    }
  }

  private static func map(_ error: LanguageModelSession.GenerationError) -> ModelGenerationFailure {
    switch error {
    case .exceededContextWindowSize:
      ModelGenerationFailure(.limitExceeded, "The native model context limit was exceeded.")
    case .assetsUnavailable:
      ModelGenerationFailure(.sourceUnavailable, "The selected model assets are unavailable.")
    case .guardrailViolation, .refusal:
      ModelGenerationFailure(.policyViolation, "The selected model rejected the request.")
    case .unsupportedGuide:
      ModelGenerationFailure(.invalidRequest, "The selected model does not support the guide.")
    case .unsupportedLanguageOrLocale:
      ModelGenerationFailure(.sourceUnavailable, "The selected model does not support the requested language.")
    case .decodingFailure:
      ModelGenerationFailure(.malformedEvent, "Native model response decoding failed.")
    case .rateLimited, .concurrentRequests:
      ModelGenerationFailure(.sourceUnavailable, "The selected model is temporarily unavailable.")
    @unknown default:
      ModelGenerationFailure(.transportFailure, "The selected native model failed.")
    }
  }
}
