import Foundation
import LanguageModelCore

final class ModelRunControl: @unchecked Sendable {
  private let lock = NSLock()
  private let continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation
  private var pumpTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var terminalDelivered = false
  private var providerEffectState: ModelRunEffectState = .notStarted
  private var requestedTermination: ModelGenerationFailure?
  // A failed pump must not release its native operation merely by returning.
  // The failed runtime retains this control and therefore the exact producer.
  private var unprovedInvocation: ModelClientInvocation?
  private var pumpFinished = false
  private var pumpWaiters: [CheckedContinuation<Void, Never>] = []

  init(continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation) {
    self.continuation = continuation
  }

  func installPump(_ task: Task<Void, Never>) {
    lock.lock()
    pumpTask = task
    let shouldCancel = terminalDelivered || requestedTermination != nil
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  func installWatchdog(_ task: Task<Void, Never>) {
    lock.lock()
    watchdogTask = task
    let shouldCancel = terminalDelivered || requestedTermination != nil || pumpFinished
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  /// Marks the provider effect boundary as soon as the runtime observes the
  /// authoritative started event. Payload validation follows; the transition
  /// itself is monotonic.
  func markProviderEffectStarted() {
    lock.lock()
    providerEffectState = .started
    lock.unlock()
  }

  var effectState: ModelRunEffectState {
    lock.lock()
    defer { lock.unlock() }
    return providerEffectState
  }

  @discardableResult
  func yield(_ event: ModelEvent) -> Bool {
    lock.lock()
    let shouldReject = terminalDelivered || requestedTermination != nil
    lock.unlock()
    guard !shouldReject else { return false }

    switch continuation.yield(event) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      return false
    @unknown default:
      return false
    }
  }

  /// Reserves the authoritative completed event, publishes the runtime's
  /// post-run state, and only then exposes completion to the consumer.
  /// Cancellation cannot replace success after the terminal decision wins.
  @discardableResult
  func complete(
    with event: ModelEvent,
    after publishPostRunState: @escaping @Sendable () async -> Void
  ) async -> Bool {
    guard let reservation = reserveCompletion() else { return false }

    reservation.watchdog?.cancel()
    await publishPostRunState()
    guard case .enqueued = continuation.yield(event) else {
      continuation.finish()
      return false
    }
    continuation.finish()
    return true
  }

  /// Records a caller-owned terminal request without publishing it until the
  /// provider-consumption pump has unwound. This is local task completion,
  /// not proof that a buffered producer/native task or remote effect has ended.
  /// Providers retain native drain ownership; durable callers retain uncertainty.
  @discardableResult
  func requestTermination(_ failure: ModelGenerationFailure) -> Bool {
    lock.lock()
    guard !terminalDelivered, requestedTermination == nil else {
      lock.unlock()
      return false
    }
    requestedTermination = failure
    let watchdog = watchdogTask
    lock.unlock()

    watchdog?.cancel()
    return true
  }

  var requestedTerminationFailure: ModelGenerationFailure? {
    lock.lock()
    defer { lock.unlock() }
    return requestedTermination
  }

  /// Reserves the authoritative failure, publishes the runtime's post-run
  /// state, and only then exposes the failure to the consumer. A cancellation
  /// or deadline already accepted by the control remains authoritative.
  @discardableResult
  func finish(
    throwing error: (any Error)? = nil,
    after publishPostRunState: @escaping @Sendable () async -> Void
  ) async -> Bool {
    guard let reservation = reserveFailure(fallback: error) else { return false }

    reservation.watchdog?.cancel()
    await publishPostRunState()
    if let error = reservation.error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
    return true
  }

  private struct TerminalReservation {
    let watchdog: Task<Void, Never>?
    let error: (any Error)?
  }

  private func reserveCompletion() -> TerminalReservation? {
    lock.lock()
    guard !terminalDelivered, requestedTermination == nil else {
      lock.unlock()
      return nil
    }
    terminalDelivered = true
    let reservation = TerminalReservation(watchdog: watchdogTask, error: nil)
    lock.unlock()
    return reservation
  }

  private func reserveFailure(fallback: (any Error)?) -> TerminalReservation? {
    lock.lock()
    guard !terminalDelivered else {
      lock.unlock()
      return nil
    }
    terminalDelivered = true
    let reservation = TerminalReservation(
      watchdog: watchdogTask,
      error: requestedTermination ?? fallback
    )
    lock.unlock()
    return reservation
  }

  func cancelPump() {
    lock.lock()
    let task = pumpTask
    lock.unlock()
    task?.cancel()
  }

  func retainUnprovedInvocation(_ invocation: ModelClientInvocation?) {
    lock.lock()
    unprovedInvocation = invocation
    lock.unlock()
  }

  func markPumpFinished() {
    lock.lock()
    pumpFinished = true
    let watchdog = watchdogTask
    let waiters = pumpWaiters
    pumpWaiters.removeAll(keepingCapacity: false)
    pumpTask = nil
    watchdogTask = nil
    lock.unlock()
    watchdog?.cancel()
    for waiter in waiters { waiter.resume() }
  }

  func waitUntilPumpFinished() async {
    if isPumpFinished { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if pumpFinished {
        lock.unlock()
        continuation.resume()
      } else {
        pumpWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  var isPumpFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pumpFinished
  }
}
