import AppleLocalAICore

/// Native effect lifecycle only. The transcript remains in LanguageModelSession.
/// Keep task ownership out of the pure AppleLocalAICore module.
@MainActor
final class OperationController {
  private(set) var lifecycle: OperationLifecycle = .idle
  private var cancelActiveEffect: (@Sendable () -> Void)?

  var isBusy: Bool { lifecycle.isBusy }

  func cancel() {
    guard case .running(let operation) = lifecycle else { return }
    do {
      try lifecycle.requestCancellation(operation)
      cancelActiveEffect?()
    } catch {
      preconditionFailure("Invalid cancellation transition: \(error)")
    }
  }

  func perform<Value: Sendable>(
    _ effect: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let operation = OperationID()
    try lifecycle.start(operation)
    // Exactly one settlement, including cancellation after a native success.
    defer { settle(operation) }

    let task = Task { @MainActor in
      try Task.checkCancellation()
      return try await effect()
    }
    cancelActiveEffect = { task.cancel() }

    do {
      let value = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      // A provider is allowed to ignore cancellation. Its late result is not.
      try Task.checkCancellation()
      guard lifecycle != .cancelling(operation) else { throw CancellationError() }
      return value
    } catch {
      if Task.isCancelled || lifecycle == .cancelling(operation) || error is CancellationError {
        throw CancellationError()
      }
      throw error
    }
  }

  private func settle(_ operation: OperationID) {
    defer { cancelActiveEffect = nil }
    do {
      switch lifecycle {
      case .running:
        try lifecycle.finish(operation)
      case .cancelling:
        try lifecycle.settleCancellation(operation)
      case .idle:
        preconditionFailure("Operation settled after lifecycle became idle")
      }
    } catch {
      preconditionFailure("Invalid operation settlement: \(error)")
    }
  }
}
