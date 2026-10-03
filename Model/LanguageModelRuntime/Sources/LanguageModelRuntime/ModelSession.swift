import LanguageModelCore

/// Optional conversation context. Native admission/producer lifetime still belongs
/// exclusively to ModelRuntime. The session owns only committed transcript and
/// the delivery task for its own request; it never cancels another borrower's run.
public actor ModelSession {
  public enum Status: Sendable { case ready, generating, closing, closed, failed }
  public nonisolated let id: String
  private let access: ModelRuntimeAccess
  private var ledger: SessionLedger
  private struct Operation {
    let generation: UInt64
    let task: Task<ModelTurn, any Error>
  }
  // Resource handles, not additional lifecycle flags. Ledger is the state authority.
  private var operation: Operation?
  private var closeTask: Task<Void, any Error>?

  public init(id: String, runtime: ModelRuntimeAccess, transcript: [AgentMessage] = []) {
    self.id = id
    self.access = runtime
    self.ledger = SessionLedger(transcript: transcript)
  }

  public var transcript: [AgentMessage] { ledger.transcript }
  public var status: Status {
    switch ledger.phase {
    case .ready: .ready
    case .generating: .generating
    case .closing: .closing
    case .closed: .closed
    case .failed: .failed
    }
  }

  public func respond(
    to messages: [AgentMessage], tools: [ModelTool] = [],
    outputFormat: ModelOutputFormat = .text,
    maxOutputBytes: Int? = nil, deadline: Duration? = nil,
    limits: ModelGenerationLimits = .default
  ) async throws -> ModelTurn {
    let task = try begin(
      messages: messages, tools: tools, outputFormat: outputFormat,
      maxOutputBytes: maxOutputBytes, deadline: deadline, limits: limits,
      onEvent: { _ in }, onCompletion: { _ in })
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Deltas are provisional. `.completed` is emitted only after runtime drain
  /// AND transcript commit. Abandoning/cancelling iteration cancels this task.
  public func stream(
    to messages: [AgentMessage], tools: [ModelTool] = [],
    outputFormat: ModelOutputFormat = .text,
    maxOutputBytes: Int? = nil, deadline: Duration? = nil,
    limits: ModelGenerationLimits = .default
  ) throws -> AsyncThrowingStream<ModelEvent, any Error> {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let task = try begin(
      messages: messages, tools: tools, outputFormat: outputFormat,
      maxOutputBytes: maxOutputBytes, deadline: deadline, limits: limits,
      onEvent: { event in
        // Never publish a terminal before the session commits its transcript.
        if case .completed = event { return }
        pair.continuation.yield(event)
      },
      onCompletion: { result in
        switch result {
        case .success(let turn):
          pair.continuation.yield(.completed(turn))
          pair.continuation.finish()
        case .failure(let error): pair.continuation.finish(throwing: error)
        }
      })
    pair.continuation.onTermination = { termination in
      if case .cancelled = termination { task.cancel() }
    }
    return pair.stream
  }

  public func cancel() async throws {
    guard let operation else { return }
    operation.task.cancel()
    try await Self.joinCancellation(operation.task)
  }

  /// Closes intake first, cancels/joins only this session's delivery task, then
  /// releases owned runtime access. Borrowed close never unloads shared weights.
  /// Failed release remains observable on every subsequent close call.
  public func close() async throws {
    let task: Task<Void, any Error>
    if let existing = closeTask {
      task = existing
    } else {
      ledger = try SessionLedger.reduce(state: ledger, event: .close).0
      let operation = operation
      let access = access
      operation?.task.cancel()
      task = Task {
        var generationFailure: (any Error)?
        if let operation {
          do { try await Self.joinCancellation(operation.task) } catch { generationFailure = error }
        }
        // Owned runtime shutdown independently checks drain proof. Never skip it
        // because a settled generation failed for an unrelated provider reason.
        try await access.release()
        if let generationFailure { throw generationFailure }
      }
      closeTask = task
    }
    do {
      try await task.value
      ledger = try SessionLedger.reduce(state: ledger, event: .didClose).0
    } catch {
      ledger = try SessionLedger.reduce(state: ledger, event: .closeFailed).0
      throw error
    }
  }

  private func begin(
    messages: [AgentMessage], tools: [ModelTool], outputFormat: ModelOutputFormat,
    maxOutputBytes: Int?, deadline: Duration?, limits: ModelGenerationLimits,
    onEvent: @escaping @Sendable (ModelEvent) -> Void,
    onCompletion: @escaping @Sendable (Result<ModelTurn, any Error>) -> Void
  ) throws -> Task<ModelTurn, any Error> {
    try Task.checkCancellation()
    let (next, effect) = try SessionLedger.reduce(state: ledger, event: .begin(messages))
    guard case .generate(let generation, let contents) = effect else {
      throw ModelRuntimeFailure(.invariantViolation, "Conversation admission produced no request.")
    }
    let request = ModelRequest(
      sessionID: id, modelID: access.runtime.modelDescriptor.id,
      messages: contents, tools: tools, outputFormat: outputFormat,
      maxOutputBytes: maxOutputBytes, deadline: deadline, limits: limits)
    // Use the canonical validator, before changing state or creating tasks.
    try request.validateGenerationContract()
    ledger = next
    let runtime = access.runtime
    let task = Task {
      do {
        let turn = try await runtime.generate(request, onEvent: onEvent)
        try Task.checkCancellation()
        let (next, effect) = try SessionLedger.reduce(
          state: ledger, event: .succeeded(generation, turn))
        guard effect == nil else { throw CancellationError() }
        ledger = next
        if operation?.generation == generation { operation = nil }
        onCompletion(.success(turn))
        return turn
      } catch {
        ledger = try SessionLedger.reduce(state: ledger, event: .failed(generation)).0
        if operation?.generation == generation { operation = nil }
        onCompletion(.failure(error))
        throw error
      }
    }
    operation = Operation(generation: generation, task: task)
    return task
  }

  private static func joinCancellation(_ task: Task<ModelTurn, any Error>) async throws {
    do { _ = try await task.value } catch is CancellationError { return } catch let error
      as ModelGenerationFailure where error.code == .cancelled
    { return }
  }
}
