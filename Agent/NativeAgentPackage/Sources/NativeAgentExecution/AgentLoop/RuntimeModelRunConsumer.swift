import NativeAgentDomain
import Foundation
import LanguageModelRuntime

/// Consumes an already-admitted `ModelRun`.
///
/// `ModelRuntime` is authoritative for event ordering, bounds, terminal
/// uniqueness, deadline, cancellation, and clean EOF. This adapter only
/// forwards transient telemetry and extracts the authoritative completed turn.
struct RuntimeModelRunConsumer: Sendable {
  let observer: (any RuntimeObserver)?
  let now: @Sendable () -> Date

  func consume(
    _ run: ModelRun,
    sessionID: String,
    providerID: String
  ) async throws -> ModelTurn {
    do {
      return try await withTaskCancellationHandler {
        var terminal: ModelTurn?
        for try await event in run.events {
          try Task.checkCancellation()
          await observer?.record(
            modelStream: ModelInvocationStreamEvent(
              sessionID: sessionID,
              providerID: providerID,
              event: event,
              createdAt: now()
            )
          )
          if case .completed(let turn) = event {
            terminal = turn
          }
        }

        // Task cancellation may terminate AsyncThrowingStream iteration by returning
        // nil before the runtime's cancellation error is observed. Cancellation is
        // therefore classified before a missing-terminal invariant.
        try Task.checkCancellation()

        guard let terminal else {
          throw AgentError.invariantViolation(
            "ModelRuntime ended without its authoritative completed turn."
          )
        }
        return terminal
      } onCancel: {
        Task { await run.cancel() }
      }
    } catch is CancellationError {
      // Join the runtime's consumption pump. A buffered adapter producer or
      // remote request may still be draining; AgentLoop preserves that outcome
      // as unresolved rather than turning local cancellation into retry authority.
      await run.cancel()
      throw CancellationError()
    }
  }
}
