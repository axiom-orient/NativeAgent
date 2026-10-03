import Foundation

/// Retained until runtime shutdown and resident release are both proven.
private struct LocalBackendResource: Sendable {
  let runtime: ModelRuntime
  let releaseResident: @Sendable () async throws -> Void

  init(
    runtime: ModelRuntime,
    releaseResident: @escaping @Sendable () async throws -> Void
  ) {
    self.runtime = runtime
    self.releaseResident = releaseResident
  }
}

public enum LocalBackendStatus: Sendable, Equatable {
  case unloaded
  case loading
  case ready(ModelRuntimeID)
  case closing
  case closed
  case failed(LocalBackendFailure)
}

public enum LocalBackendFailure: Error, LocalizedError, Sendable, Equatable {
  case closing
  case closed
  case loadCleanupFailed
  case runtimeShutdownFailed
  case residentReleaseFailed

  public var errorDescription: String? {
    switch self {
    case .closing: "The local backend is shutting down."
    case .closed: "The local backend is closed."
    case .loadCleanupFailed:
      "Load failed and partial resident cleanup failed; the backend is quarantined."
    case .runtimeShutdownFailed:
      "ModelRuntime shutdown failed; resident resources remain quarantined."
    case .residentReleaseFailed: "Resident release failed; resources remain quarantined."
    }
  }
}

/// Host-owned lifetime for one explicitly selected local backend configuration.
///
/// Construct once, then pass the SAME loaded ModelRuntime to NativeAgent and
/// the Apple session adapter. This actor coalesces loading and owns shutdown;
/// ModelRuntime alone owns invocation admission. No routing, fallback, model
/// download, singleton cache, or implicit retry lives here.
///
/// Cancelling a load waiter does not cancel the shared load. Its result remains
/// owned here, but is never returned successfully to that cancelled waiter.
/// `shutdown()` is the only operation allowed to cancel the shared load. It
/// joins even a late successful load, closes ModelRuntime, and only then
/// releases the resident. A failed drain/release is sticky and retains resources.
public actor LocalBackend {
  private enum State {
    case unloaded
    case loading(UUID, Task<LocalBackendResource, any Error>)
    case ready(LocalBackendResource)
    case closing(Task<CloseOutcome, Never>)
    case closed
    case failedLoading(LocalBackendFailure)
    case failed(LocalBackendFailure, LocalBackendResource)
  }

  private enum PendingResource: Sendable {
    case loaded(LocalBackendResource)
    case loading(Task<LocalBackendResource, any Error>)
  }

  private enum CloseOutcome: Sendable {
    case closed
    case failedLoading(LocalBackendFailure)
    case failed(LocalBackendFailure, LocalBackendResource)
  }

  private let loader: @Sendable () async throws -> ModelRuntime
  private let releaseResident: @Sendable () async throws -> Void
  private var state: State = .unloaded

  /// `releaseResident` also cleans a partially completed load. It must join
  /// native loading/generation before freeing resources, and must throw when
  /// safe release cannot be established. It is never called on an unloaded
  /// backend which has not attempted a load.
  public init(
    load: @escaping @Sendable () async throws -> ModelRuntime,
    releaseResident: @escaping @Sendable () async throws -> Void
  ) {
    self.loader = load
    self.releaseResident = releaseResident
  }

  public func status() -> LocalBackendStatus {
    switch state {
    case .unloaded: .unloaded
    case .loading: .loading
    case .ready(let resource): .ready(resource.runtime.id)
    case .closing: .closing
    case .closed: .closed
    case .failedLoading(let failure), .failed(let failure, _): .failed(failure)
    }
  }

  /// Every successful caller receives the identical ModelRuntime instance.
  /// Borrowers must not independently shut it down or unload its provider.
  public func load() async throws -> ModelRuntime {
    try Task.checkCancellation()
    let token: UUID
    let task: Task<LocalBackendResource, any Error>
    switch state {
    case .unloaded:
      token = UUID()
      let loader = self.loader
      let release = self.releaseResident
      task = Task {
        do {
          return LocalBackendResource(runtime: try await loader(), releaseResident: release)
        } catch {
          let loadError = error
          // Teardown is owner work, not cancellable waiter work. In particular,
          // shutdown cancellation must not skip cleanup of a partial load.
          do { try await Task.detached { try await release() }.value } catch {
            throw LocalBackendFailure.loadCleanupFailed
          }
          throw loadError
        }
      }
      state = .loading(token, task)
    case .loading(let existingToken, let existingTask):
      token = existingToken
      task = existingTask
    case .ready(let resource):
      return resource.runtime
    case .closing: throw LocalBackendFailure.closing
    case .closed: throw LocalBackendFailure.closed
    case .failedLoading(let failure), .failed(let failure, _): throw failure
    }

    do {
      let resource = try await task.value
      switch state {
      case .loading(let currentToken, _) where currentToken == token:
        state = .ready(resource)
      case .ready(let current) where current.runtime === resource.runtime:
        break
      case .closing: throw LocalBackendFailure.closing
      case .closed: throw LocalBackendFailure.closed
      case .failedLoading(let failure), .failed(let failure, _): throw failure
      default:
        // No path reopens or replaces a successful load behind a waiter.
        throw ModelRuntimeFailure(.invariantViolation, "The local backend load lost its ownership.")
      }
      try Task.checkCancellation()
      return resource.runtime
    } catch {
      if case .loading(let currentToken, _) = state, currentToken == token {
        if error as? LocalBackendFailure == .loadCleanupFailed {
          state = .failedLoading(.loadCleanupFailed)
        } else {
          state = .unloaded  // Explicit retry only after proven partial cleanup.
        }
      }
      // A failed cleanup is authoritative even when this waiter was cancelled.
      // Hiding it as cancellation would make an unsafe resident look retryable.
      if error as? LocalBackendFailure == .loadCleanupFailed { throw error }
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  /// Idempotent host close. Cancellation of a waiting caller never cancels
  /// teardown. A runtime drain failure prevents resident release entirely.
  public func shutdown() async throws {
    let task: Task<CloseOutcome, Never>
    switch state {
    case .unloaded:
      state = .closed
      return
    case .closed:
      return
    case .failedLoading(let failure), .failed(let failure, _):
      throw failure
    case .closing(let existing):
      task = existing
    case .loading(_, let loading):
      loading.cancel()
      task = Task { await Self.close(.loading(loading)) }
      state = .closing(task)
    case .ready(let resource):
      task = Task { await Self.close(.loaded(resource)) }
      state = .closing(task)
    }

    switch await task.value {
    case .closed:
      state = .closed
    case .failedLoading(let failure):
      state = .failedLoading(failure)
      throw failure
    case .failed(let failure, let resource):
      state = .failed(failure, resource)
      throw failure
    }
  }

  private static func close(_ pending: PendingResource) async -> CloseOutcome {
    let resource: LocalBackendResource
    switch pending {
    case .loaded(let loaded): resource = loaded
    case .loading(let task):
      switch await task.result {
      case .success(let loaded): resource = loaded
      case .failure(let error):
        return error as? LocalBackendFailure == .loadCleanupFailed
          ? .failedLoading(.loadCleanupFailed) : .closed
      }
    }
    do {
      try await resource.runtime.shutdown()
    } catch {
      return .failed(.runtimeShutdownFailed, resource)
    }
    do {
      try await resource.releaseResident()
      return .closed
    } catch {
      return .failed(.residentReleaseFailed, resource)
    }
  }
}
