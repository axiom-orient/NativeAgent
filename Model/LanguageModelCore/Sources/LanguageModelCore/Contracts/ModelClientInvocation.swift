import Foundation

/// One provider call and its producer/native settlement boundary.
/// Buffered stream EOF is not proof that native work has stopped.
public struct ModelClientInvocation: Sendable {
  public let events: AsyncThrowingStream<ModelEvent, any Error>
  /// Synchronous signal only. It is safe from a task cancellation handler.
  public let cancel: @Sendable () -> Void
  /// Joins both the producer and native teardown, even for a cancelled caller.
  /// Must be idempotent: a cancelled terminal race may join more than once.
  /// Never starts a new generation, retries, or silently releases live resources.
  public let waitForCompletion: @Sendable () async throws -> Void

  public init(
    events: AsyncThrowingStream<ModelEvent, any Error>,
    cancel: @escaping @Sendable () -> Void,
    waitForCompletion: @escaping @Sendable () async throws -> Void
  ) {
    self.events = events
    self.cancel = cancel
    self.waitForCompletion = waitForCompletion
  }

  public func cancelAndDrain() async throws {
    cancel()
    try await waitForCompletion()
  }
}

/// An actual I/O boundary, not a replacement for ModelClient semantics.
/// Use for adapters with a buffered producer or independently running native
/// operation. ModelRuntime joins this before publishing idle/completion.
public protocol ModelClientWithOwnedInvocation: ModelClient {
  /// Signal after provider validation, before native I/O. A buffered .started
  /// event may not be consumed before cancellation; effect certainty must not
  /// depend on draining the event buffer. The .started event is still required.
  func invocation(
    request: ModelRequest,
    onStarted: @escaping @Sendable () -> Void
  ) -> ModelClientInvocation
}
