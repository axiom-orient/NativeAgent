import LanguageModelCore

extension ModelRuntime {
  /// The descriptor/executor entrypoint shares the existing admission,
  /// terminal validation, cancellation and drain authority. No second runtime.
  public init<Model: LanguageModel>(
    id: ModelRuntimeID,
    model: Model,
    policy: ModelRuntimePolicy = .default,
    cleanup: @escaping @Sendable () async throws -> Void = {}
  ) throws {
    guard Self.validIdentifier(id.rawValue) else {
      throw ModelRuntimeFailure(.invalidConfiguration, "The runtime identifier is invalid.")
    }
    try model.descriptor.validateGenerationContract()
    let executor = try Model.Executor(configuration: model.executorConfiguration)
    try self.init(
      id: id,
      client: ExecutorClient(
        model: model, executor: executor, maximumPendingEvents: policy.maximumEventCount),
      descriptor: model.descriptor,
      policy: policy,
      cleanup: {
        try await executor.shutdown()
        try await cleanup()
      }
    )
  }
}

private struct ExecutorClient<Model: LanguageModel>: ModelClientWithOwnedInvocation {
  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }
  let model: Model
  let executor: Model.Executor
  let maximumPendingEvents: Int
  var providerID: String { model.descriptor.providerID }
  var modelDescriptor: ModelDescriptor? { model.descriptor }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    let operation = invocation(request: request, onStarted: {})
    return try await withTaskCancellationHandler {
      do {
        var collector = try ModelStreamCollector(request: request)
        for try await event in operation.events { try collector.receive(event) }
        let result = try collector.finish()
        try await operation.waitForCompletion()
        try Task.checkCancellation()
        return result
      } catch {
        try await operation.cancelAndDrain()
        throw error
      }
    } onCancel: {
      operation.cancel()
    }
  }

  func invocation(
    request: ModelRequest,
    onStarted: @escaping @Sendable () -> Void
  ) -> ModelClientInvocation {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(maximumPendingEvents))
    let channel = ModelGenerationChannel(
      publish: { event in
        switch pair.continuation.yield(event) {
        case .enqueued: break
        case .terminated: throw CancellationError()
        case .dropped:
          throw ModelGenerationFailure(.limitExceeded, "The executor event buffer overflowed.")
        @unknown default:
          throw ModelGenerationFailure(.malformedEvent, "Unknown executor channel state.")
        }
      },
      onStarted: onStarted
    )
    let producer = Task {
      do {
        try Task.checkCancellation()
        try await executor.respond(to: request, model: model, streamingInto: channel)
        try Task.checkCancellation()
        pair.continuation.finish()
      } catch let failure as ModelExecutorDrainFailure {
        pair.continuation.finish(throwing: failure)
        // Propagate unproved drain through the independent settlement port.
        throw failure
      } catch {
        pair.continuation.finish(throwing: error)
      }
    }
    pair.continuation.onTermination = { termination in
      if case .cancelled = termination { producer.cancel() }
    }
    return ModelClientInvocation(
      events: pair.stream,
      cancel: { producer.cancel() },
      waitForCompletion: { try await producer.value }
    )
  }
}
