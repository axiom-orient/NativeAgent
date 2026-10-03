import Foundation

private func nativeAgentAwaitSharedTask<Value: Sendable>(
  _ task: Task<Value, any Error>
) async throws -> Value {
  try Task.checkCancellation()
  let waiter = ChatGPTTaskWaiter<Value>()
  Task {
    waiter.resolve(await task.result)
  }
  return try await withTaskCancellationHandler {
    try await waiter.value()
  } onCancel: {
    waiter.resolve(.failure(CancellationError()))
  }
}

final class ChatGPTSharedOperation<Value: Sendable>: @unchecked Sendable {
  enum CancellationOwnership { case lastWaiter, owner }

  private let task: Task<Value, any Error>
  private let cancellationOwnership: CancellationOwnership
  private let waiterLock = NSLock()
  private var waiterCount = 0

  init(task: Task<Value, any Error>, cancellationOwnership: CancellationOwnership = .lastWaiter) {
    self.task = task
    self.cancellationOwnership = cancellationOwnership
  }

  /// Owner join: a cancelled observer must not make unfinished work look settled.
  func result() async -> Result<Value, any Error> { await task.result }

  func value() async throws -> Value {
    waiterLock.withLock { waiterCount += 1 }
    do {
      let value = try await nativeAgentAwaitSharedTask(task)
      release(cancelUnderlying: false)
      return value
    } catch {
      release(cancelUnderlying: Task.isCancelled)
      throw error
    }
  }

  func cancel() {
    task.cancel()
  }

  private func release(cancelUnderlying: Bool) {
    let cancel = waiterLock.withLock {
      precondition(waiterCount > 0)
      waiterCount -= 1
      return cancelUnderlying && waiterCount == 0 && cancellationOwnership == .lastWaiter
    }
    if cancel { task.cancel() }
  }
}

private final class ChatGPTTaskWaiter<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case waiting(CheckedContinuation<Value, any Error>?)
    case resolved(Result<Value, any Error>)
  }

  private let lock = NSLock()
  private var state: State = .waiting(nil)

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let result = lock.withLock { () -> Result<Value, any Error>? in
        switch state {
        case .waiting(nil):
          state = .waiting(continuation)
          return nil
        case .waiting:
          preconditionFailure("A shared-task waiter can only be awaited once.")
        case .resolved(let result):
          return result
        }
      }
      if let result { continuation.resume(with: result) }
    }
  }

  func resolve(_ result: Result<Value, any Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
      switch state {
      case .waiting(let continuation):
        state = .resolved(result)
        return continuation
      case .resolved:
        return nil
      }
    }
    continuation?.resume(with: result)
  }
}
