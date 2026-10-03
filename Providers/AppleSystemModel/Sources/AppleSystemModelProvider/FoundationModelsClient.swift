import Foundation
import LanguageModelCore
import LanguageModelRuntime

#if canImport(FoundationModels)
  import FoundationModels
#endif

public enum FoundationModelsAvailability: Sendable, Equatable {
  case available
  case deviceNotEligible
  case appleIntelligenceNotEnabled
  case modelNotReady
}

/// Separate EOF from producer settlement. Only the live SDK constructor is
/// public through the provider factory; injection below is internal test scope.
struct FoundationSnapshotInvocation: Sendable {
  let snapshots: AsyncThrowingStream<String, any Error>
  let cancel: @Sendable () -> Void
  let waitForCompletion: @Sendable () async throws -> Void
}

struct FoundationModelsClient: ModelClientWithOwnedInvocation, Sendable {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  private let availabilitySource: @Sendable () -> FoundationModelsAvailability
  private let responseSource: @Sendable (ModelRequest) -> FoundationSnapshotInvocation

  #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    init(
      model: SystemLanguageModel = .default,
      providerID: String = "apple.foundation-models",
      modelDescriptor: ModelDescriptor? = nil
    ) {
      self.providerID = providerID
      self.modelDescriptor =
        modelDescriptor
        ?? ModelDescriptor(
          id: "system-language-model",
          providerID: providerID,
          displayName: "Apple Intelligence",
          capabilities: [.textInput, .textOutput, .streaming])
      self.availabilitySource = { Self.availability(of: model) }
      self.responseSource = { request in Self.liveSnapshots(model: model, request: request) }
    }

  #endif
  init(
    providerID: String = "apple.foundation-models", modelDescriptor: ModelDescriptor? = nil,
    availability: @escaping @Sendable () -> FoundationModelsAvailability,
    responses: @escaping @Sendable (ModelRequest) -> FoundationSnapshotInvocation
  ) {
    self.providerID = providerID
    self.modelDescriptor = modelDescriptor
    self.availabilitySource = availability
    self.responseSource = responses
  }
  var availability: FoundationModelsAvailability { availabilitySource() }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    let owned = invocation(request: request, onStarted: {})
    return try await withTaskCancellationHandler {
      do {
        var collector = try ModelStreamCollector(request: request)
        for try await event in owned.events { try collector.receive(event) }
        try await owned.waitForCompletion()
        try Task.checkCancellation()
        return try collector.finish()
      } catch {
        try await owned.cancelAndDrain()
        if Task.isCancelled {
          throw ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
        }
        throw error
      }
    } onCancel: {
      owned.cancel()
    }
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }

  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void)
    -> ModelClientInvocation
  {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let task = Task {
      do {
        try Task.checkCancellation()
        let descriptor =
          modelDescriptor
          ?? ModelDescriptor(
            id: request.modelID ?? "system-language-model",
            providerID: providerID, capabilities: [.textInput, .textOutput, .streaming])
        _ = try ModelTextRequest(request, descriptor: descriptor)
        guard availabilitySource() == .available else {
          throw ModelGenerationFailure(
            .sourceUnavailable, "Apple on-device Foundation Models is unavailable.")
        }
        // Signal synchronously before SDK producer creation, not after a buffered event.
        onStarted()
        pair.continuation.yield(.started(descriptor: modelDescriptor))
        let native = responseSource(request)
        try await withTaskCancellationHandler {
          do {
            var accumulator = ModelTextSnapshotAccumulator(request: request)
            for try await snapshot in native.snapshots {
              try Task.checkCancellation()
              for delta in try accumulator.receive(snapshot) {
                if case .terminated = pair.continuation.yield(.textDelta(delta)) {
                  throw CancellationError()
                }
              }
            }
            try await Self.join(native)
            try Task.checkCancellation()
            pair.continuation.yield(.completed(ModelTurn(content: try accumulator.finish())))
            pair.continuation.finish()
          } catch let failure as ModelExecutorDrainFailure { throw failure } catch {
            native.cancel()
            try await Self.join(native)
            throw error
          }
        } onCancel: {
          native.cancel()
        }
      } catch let failure as ModelExecutorDrainFailure {
        pair.continuation.finish(throwing: failure)
        throw failure
      } catch {
        pair.continuation.finish(throwing: Self.mapFailure(error))
      }
    }
    pair.continuation.onTermination = { termination in
      if case .cancelled = termination { task.cancel() }
    }
    return ModelClientInvocation(
      events: pair.stream, cancel: { task.cancel() },
      waitForCompletion: { try await task.value })
  }

  private static func join(_ native: FoundationSnapshotInvocation) async throws {
    do { try await native.waitForCompletion() } catch {
      throw ModelExecutorDrainFailure("Apple SDK snapshot producer did not prove completion.")
    }
  }

  private static func mapFailure(_ error: any Error) -> any Error {
    if error is CancellationError {
      return ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
    }
    if let failure = error as? any ModelClientFailure { return failure }
    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *),
        let failure = error as? LanguageModelSession.GenerationError
      {
        return mapGenerationError(failure)
      }
    #endif
    return ModelGenerationFailure(.transportFailure, "Apple on-device model generation failed.")
  }

  #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func liveSnapshots(
      model: SystemLanguageModel,
      request: ModelRequest
    ) -> FoundationSnapshotInvocation {
      let pair = AsyncThrowingStream<String, any Error>.makeStream()
      let continuation = pair.continuation
      let task = Task {
        do {
          try Task.checkCancellation()
          // Byte bounds are enforced exactly by the common accumulator. A byte
          // count is not a token count; never invent a byte-to-token conversion.
          let options = GenerationOptions(samplingMode: .greedy)
          let conversation = try conversation(for: request)
          let session = LanguageModelSession(
            model: model,
            tools: [],
            transcript: conversation.transcript)
          let stream = session.streamResponse(
            to: conversation.prompt,
            options: options)
          for try await snapshot in stream {
            try Task.checkCancellation()
            if case .terminated = continuation.yield(snapshot.content) {
              throw CancellationError()
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
      return FoundationSnapshotInvocation(
        snapshots: pair.stream,
        cancel: { task.cancel() }, waitForCompletion: { await task.value })
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func conversation(
      for request: ModelRequest
    ) throws -> (transcript: Transcript, prompt: String) {
      let text = try ModelTextRequest(
        request,
        descriptor: ModelDescriptor(
          id: request.modelID ?? "system-language-model", providerID: "apple.foundation-models",
          capabilities: [.textInput, .textOutput, .streaming]))

      var entries: [Transcript.Entry] = []
      let instructions = text.instructions
      if !instructions.isEmpty {
        entries.append(
          .instructions(
            Transcript.Instructions(
              segments: [.text(Transcript.TextSegment(content: instructions))],
              toolDefinitions: []
            )
          )
        )
      }

      for message in text.history {
        let segment = Transcript.Segment.text(
          Transcript.TextSegment(id: "\(message.id)-text", content: message.content)
        )
        switch message.role {
        case .user:
          entries.append(
            .prompt(
              Transcript.Prompt(
                id: message.id,
                segments: [segment]
              )
            )
          )
        case .assistant:
          entries.append(
            .response(
              Transcript.Response(
                id: message.id,
                assetIDs: [],
                segments: [segment]
              )
            )
          )
        case .system:
          throw ModelGenerationFailure(
            .invalidRequest, "A system instruction crossed the validated history boundary.")
        case .tool:
          throw ModelGenerationFailure(
            .policyViolation,
            "Apple Foundation Models does not accept tool-result messages in this adapter."
          )
        }
      }

      return (Transcript(entries: entries), text.prompt)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func availability(
      of model: SystemLanguageModel
    ) -> FoundationModelsAvailability {
      switch model.availability {
      case .available: .available
      case .unavailable(.deviceNotEligible): .deviceNotEligible
      case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
      case .unavailable(.modelNotReady): .modelNotReady
      @unknown default: .modelNotReady
      }
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func mapGenerationError(
      _ error: LanguageModelSession.GenerationError
    ) -> ModelGenerationFailure {
      switch error {
      case .exceededContextWindowSize:
        ModelGenerationFailure(.limitExceeded, "Apple model context window was exceeded.")
      case .assetsUnavailable:
        ModelGenerationFailure(.sourceUnavailable, "Apple model assets are unavailable.")
      case .guardrailViolation, .refusal:
        ModelGenerationFailure(.policyViolation, "Apple model policy rejected the request.")
      case .unsupportedGuide:
        ModelGenerationFailure(.invalidRequest, "Apple model does not support the requested guide.")
      case .unsupportedLanguageOrLocale:
        ModelGenerationFailure(
          .sourceUnavailable, "Apple model does not support the active language or locale.")
      case .decodingFailure:
        ModelGenerationFailure(.malformedEvent, "Apple model response decoding failed.")
      case .rateLimited, .concurrentRequests:
        ModelGenerationFailure(.sourceUnavailable, "Apple model is temporarily unavailable.")
      @unknown default:
        ModelGenerationFailure(.transportFailure, "Apple on-device model generation failed.")
      }
    }
  #endif
}
