import Foundation
import MLXModelRegistry
import LanguageModelCore

/// Provider-neutral text/tool adapter. Media is rejected before native generation.
/// Native residency and cancellation remain owned by MLXTextRuntime.
struct MLXTextModelClient: ModelClientWithOwnedInvocation, Sendable {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  private let runtime: MLXTextRuntime
  private let model: MLXModel
  private let fixedSpecification: MLXModelSpecification?

  init(
    runtime: MLXTextRuntime,
    model: MLXModel,
    providerID: String = "mlx.text",
    modelDescriptor: ModelDescriptor? = nil
  ) {
    self.runtime = runtime
    self.model = model
    self.fixedSpecification = nil
    self.providerID = providerID
    self.modelDescriptor = modelDescriptor
  }

  init(
    runtime: MLXTextRuntime,
    specification: MLXModelSpecification,
    providerID: String = "mlx.text",
    modelDescriptor: ModelDescriptor? = nil
  ) {
    self.runtime = runtime
    self.model = specification.model
    self.fixedSpecification = specification
    self.providerID = providerID
    self.modelDescriptor = modelDescriptor
  }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }

  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void)
    -> ModelClientInvocation
  {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let continuation = pair.continuation
    let task = Task {
      do {
        try Task.checkCancellation()
          try Self.validate(request)
          if case .terminated = continuation.yield(.started(descriptor: modelDescriptor)) {
            throw CancellationError()
        }
        onStarted()
        try Task.checkCancellation()
        if let fixedSpecification {
            try await runtime.generate(
              specification: fixedSpecification,
              request: request,
              emit: { continuation.yield($0) })
          } else {
            try await runtime.generate(model: model, request: request) {
              continuation.yield($0)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.normalize(error))
        }
    }
    continuation.onTermination = { _ in task.cancel() }
    return ModelClientInvocation(
      events: pair.stream,
      cancel: { task.cancel() },
      waitForCompletion: {
        _ = await task.result
        try await runtime.waitForNativeDrain()
      }
    )
  }

  private static func validate(_ request: ModelRequest) throws {
    try request.validateGenerationContract()
    if case .jsonObject(let schema) = request.outputFormat {
      guard schema.objectValue?["type"]?.stringValue == "object" else {
        throw ModelGenerationFailure(
          .invalidRequest, "MLX structured output requires an object schema.")
      }
      try MLXOutputSchema.validateSchema(schema)
    }
    guard
      request.effectiveRequiredCapabilities.isSubset(of: [
        .textInput, .textOutput, .streaming, .toolCalls, .structuredOutput,
      ]),
      !request.containsNonTextContent
    else {
      throw ModelGenerationFailure(
        .invalidRequest,
        "MLX supports text and tool messages; media is unsupported.")
    }

  }

  private static func normalize(_ error: any Error) -> ModelGenerationFailure {
    if let failure = error as? ModelGenerationFailure { return failure }
    if error is CancellationError {
      return ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
    }
    guard let error = error as? MLXTextError else {
      return ModelGenerationFailure(.transportFailure, "MLX text generation failed.")
    }
    switch error {
    case .invalidModel:
      return ModelGenerationFailure(.invalidRequest, "The MLX text model is invalid.")
    case .modelMissing, .busy, .invalidArtifact:
      return ModelGenerationFailure(.sourceUnavailable, "The MLX text model is unavailable.")
    case .insufficientDisk:
      return ModelGenerationFailure(.limitExceeded, "MLX text storage is insufficient.")
    case .invalidRuntimeOutput:
      return ModelGenerationFailure(.malformedEvent, "MLX text output is invalid.")
    }
  }
}
