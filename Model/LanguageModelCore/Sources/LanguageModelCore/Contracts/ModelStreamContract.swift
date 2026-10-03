import Foundation

public enum ModelStreamContractError: Error, Sendable, Equatable, LocalizedError {
  case missingStartedEvent
  case duplicateStartedEvent
  case missingCompletedEvent
  case duplicateCompletedEvent
  case eventAfterCompletion

  public var errorDescription: String? {
    switch self {
    case .missingStartedEvent:
      "A model stream must begin with exactly one started event."
    case .duplicateStartedEvent:
      "A model stream emitted more than one started event."
    case .missingCompletedEvent:
      "A model stream ended without exactly one completed event."
    case .duplicateCompletedEvent:
      "A model stream emitted more than one completed event."
    case .eventAfterCompletion:
      "A model stream emitted an event after its completed event."
    }
  }
}

/// Validates stream ordering, request bounds, authoritative terminal content,
/// usage, and structured-output shape in one pass.
public struct ModelStreamCollector: Sendable {
  private let request: ModelRequest
  private var contract = ModelStreamContractState()
  private var text = Data()
  private var auxiliaryOutputBytes = 0
  private var receivedTextDelta = false
  private var latestUsage: ModelUsage?

  public init(request: ModelRequest) throws {
    try request.validateGenerationContract()
    self.request = request
    text.reserveCapacity(min(request.maxOutputBytes, 4_096))
  }

  @discardableResult
  public mutating func receive(_ event: ModelEvent) throws -> ModelTurn? {
    switch event {
    case .textDelta(let delta):
      let bytes = Data(delta.utf8)
      guard bytes.count <= request.limits.maxDeltaBytes,
            bytes.count <= request.limits.maxFrameBytes else {
        throw ModelGenerationFailure(.limitExceeded, "Model delta exceeds the byte limit.")
      }
      let (count, overflow) = text.count.addingReportingOverflow(bytes.count)
      guard !overflow, count <= request.maxOutputBytes else {
        throw ModelGenerationFailure(.limitExceeded, "Model output exceeds the byte limit.")
      }
      text.append(bytes)
      receivedTextDelta = true
    case .usage(let usage):
      try usage.validate()
      latestUsage = usage
    case .reasoningDelta(let delta):
      try appendAuxiliary(delta.utf8.count)
    case .toolCallDelta(let id, let name, let argumentsDelta):
      guard ModelRequest.validID(id), name.map(ModelRequest.validToolName) ?? true else {
        throw ModelGenerationFailure(.malformedEvent, "Model tool-call delta is invalid.")
      }
      try appendAuxiliary(
        id.utf8.count + (name?.utf8.count ?? 0) + argumentsDelta.utf8.count)
    case .completed(let turn):
      if let latestUsage, let terminalUsage = turn.usage, latestUsage != terminalUsage {
        throw ModelGenerationFailure(
          .malformedEvent,
          "Stream usage conflicts with authoritative terminal usage."
        )
      }
      let effectiveTurn: ModelTurn
      if turn.usage == nil, let latestUsage {
        effectiveTurn = ModelTurn(
          contentParts: turn.contentParts,
          toolCalls: turn.toolCalls,
          metadata: turn.metadata,
          usage: latestUsage,
          responseID: turn.responseID,
          reasoningSummary: turn.reasoningSummary,
          stopReason: turn.stopReason
        )
      } else {
        effectiveTurn = turn
      }
      try effectiveTurn.validateGenerationContract(for: request)
      let final = Data(effectiveTurn.content.utf8)
      if receivedTextDelta {
        guard final == text else {
          throw ModelGenerationFailure(
            .malformedEvent,
            "Streamed text differs from authoritative final text."
          )
        }
      } else {
        text = final
      }
      return try contract.consume(.completed(effectiveTurn))
    case .started:
      break
    }
    return try contract.consume(event)
  }

  private mutating func appendAuxiliary(_ byteCount: Int) throws {
    guard byteCount <= request.limits.maxFrameBytes else {
      throw ModelGenerationFailure(.limitExceeded, "Model event exceeds the frame byte limit.")
    }
    let (sum, overflow) = auxiliaryOutputBytes.addingReportingOverflow(byteCount)
    guard !overflow, sum <= request.maxOutputBytes else {
      throw ModelGenerationFailure(.limitExceeded, "Model auxiliary output exceeds the byte limit.")
    }
    auxiliaryOutputBytes = sum
  }

  public func finish() throws -> ModelTurn {
    let turn = try contract.finish()
    if case .jsonObject = request.outputFormat {
      guard let value = try? JSONSerialization.jsonObject(with: text), value is [String: Any] else {
        throw ModelGenerationFailure(
          .malformedEvent,
          "Structured model output is not one complete JSON object."
        )
      }
    }
    return turn
  }
}

/// Stateful validator for the provider/runtime streaming boundary.
/// A valid stream is `started`, zero or more deltas/usage events, one
/// `completed`, and then EOF. Failures are represented by the throwing stream.
public struct ModelStreamContractState: Sendable {
  private enum Phase: Sendable {
    case awaitingStart
    case running
    case completed
  }

  private var phase: Phase = .awaitingStart
  private var terminalTurn: ModelTurn?

  public init() {}

  @discardableResult
  public mutating func consume(_ event: ModelEvent) throws -> ModelTurn? {
    switch (phase, event) {
    case (.awaitingStart, .started):
      phase = .running
      return nil
    case (.awaitingStart, _):
      throw ModelStreamContractError.missingStartedEvent
    case (.running, .started):
      throw ModelStreamContractError.duplicateStartedEvent
    case (.running, .completed(let turn)):
      phase = .completed
      terminalTurn = turn
      return turn
    case (.running, _):
      return nil
    case (.completed, .completed):
      throw ModelStreamContractError.duplicateCompletedEvent
    case (.completed, _):
      throw ModelStreamContractError.eventAfterCompletion
    }
  }

  public func finish() throws -> ModelTurn {
    switch phase {
    case .awaitingStart:
      throw ModelStreamContractError.missingStartedEvent
    case .running:
      throw ModelStreamContractError.missingCompletedEvent
    case .completed:
      guard let terminalTurn else {
        throw ModelStreamContractError.missingCompletedEvent
      }
      return terminalTurn
    }
  }
}

public enum ModelStreamContract {
  public static func completedTurn(
    from stream: AsyncThrowingStream<ModelEvent, any Error>
  ) async throws -> ModelTurn {
    try Task.checkCancellation()
    var state = ModelStreamContractState()
    for try await event in stream {
      try Task.checkCancellation()
      try state.consume(event)
    }
    try Task.checkCancellation()
    return try state.finish()
  }

  /// Collects a bounded model stream with cancellation and a caller-owned
  /// deadline. A provider cancellation that was not initiated by the caller
  /// is treated as a transport failure.
  public static func completedTurn(
    from stream: AsyncThrowingStream<ModelEvent, any Error>,
    request: ModelRequest
  ) async throws -> ModelTurn {
    do {
      try Task.checkCancellation()
      return try await withThrowingTaskGroup(of: ModelTurn.self) { group in
        group.addTask {
          var collector = try ModelStreamCollector(request: request)
          var iterator = stream.makeAsyncIterator()
          while true {
            let event: ModelEvent?
            do {
              event = try await iterator.next()
            } catch is CancellationError {
              guard Task.isCancelled else {
                throw ModelGenerationFailure(
                  .transportFailure,
                  "Model transport failed."
                )
              }
              throw CancellationError()
            } catch let failure as ModelGenerationFailure {
              if failure.code == .cancelled, !Task.isCancelled {
                throw ModelGenerationFailure(.transportFailure, "Model transport failed.")
              }
              throw failure.code == .transportFailure
                ? ModelGenerationFailure(.transportFailure, "Model transport failed.")
                : failure
            } catch {
              throw ModelGenerationFailure(.transportFailure, "Model transport failed.")
            }
            guard let event else { break }
            try Task.checkCancellation()
            try collector.receive(event)
          }
          try Task.checkCancellation()
          return try collector.finish()
        }
        group.addTask {
          try await Task.sleep(for: request.deadline)
          throw ModelGenerationFailure(
            .deadlineExceeded,
            "Model generation exceeded its deadline."
          )
        }
        guard let result = try await group.next() else {
          throw ModelGenerationFailure(
            .terminalMissing,
            "Model generation produced no result."
          )
        }
        group.cancelAll()
        return result
      }
    } catch is CancellationError {
      throw ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
    } catch let failure as ModelGenerationFailure {
      throw failure
    } catch let failure as ModelStreamContractError {
      switch failure {
      case .missingStartedEvent:
        throw ModelGenerationFailure(.malformedEvent, failure.localizedDescription)
      case .duplicateStartedEvent, .eventAfterCompletion:
        throw ModelGenerationFailure(.malformedEvent, failure.localizedDescription)
      case .missingCompletedEvent:
        throw ModelGenerationFailure(.terminalMissing, failure.localizedDescription)
      case .duplicateCompletedEvent:
        throw ModelGenerationFailure(.duplicateTerminal, failure.localizedDescription)
      }
    } catch {
      throw ModelGenerationFailure(.transportFailure, "Model transport failed.")
    }
  }
}
