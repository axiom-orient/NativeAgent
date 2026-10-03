import Foundation
import LanguageModelCore

/// Host-owned reuse scope. One executor configuration maps to one runtime and
/// therefore one admission slot. It never routes requests or changes providers.
/// Runtime/session users borrow entries; only the host shuts this store down.
public actor ModelExecutorStore {
  private struct Key: Hashable {
    let executorType: ObjectIdentifier
    let configuration: AnyHashable
  }
  private enum Phase {
    case open
    case closing(Task<Void, any Error>)
    case closed
    case failed(ModelRuntimeFailure)
  }

  private let policy: ModelRuntimePolicy
  private var entries: [Key: ModelRuntime] = [:]
  private var phase: Phase = .open

  public init(policy: ModelRuntimePolicy = .default) { self.policy = policy }

  public func runtime<Model: LanguageModel>(for model: Model) throws -> ModelRuntime {
    try Task.checkCancellation()
    switch phase {
    case .open: break
    case .closing: throw ModelRuntimeFailure(.closing, "The executor store is closing.")
    case .closed: throw ModelRuntimeFailure(.closed, "The executor store is closed.")
    case .failed(let failure): throw failure
    }
    let key = Key(
      executorType: ObjectIdentifier(Model.Executor.self),
      configuration: AnyHashable(model.executorConfiguration)
    )
    if let runtime = entries[key] {
      guard runtime.modelDescriptor == model.descriptor else {
        throw ModelRuntimeFailure(
          .invalidConfiguration,
          "One executor configuration cannot advertise conflicting descriptors.")
      }
      return runtime
    }
    let runtime = try ModelRuntime(
      id: ModelRuntimeID(rawValue: UUID().uuidString), model: model, policy: policy)
    entries[key] = runtime
    return runtime
  }

  public func shutdown() async throws {
    let task: Task<Void, any Error>
    switch phase {
    case .closed: return
    case .failed(let failure): throw failure
    case .closing(let current): task = current
    case .open:
      let runtimes = Array(entries.values)
      task = Task {
        var firstFailure: ModelRuntimeFailure?
        // Attempt every independent entry. A failed entry remains quarantined;
        // it must not prevent unrelated entries from draining safely.
        for runtime in runtimes {
          do { try await runtime.shutdown() } catch {
            if firstFailure == nil {
              firstFailure =
                (error as? ModelRuntimeFailure)
                ?? ModelRuntimeFailure(.cleanupFailed, "Executor store cleanup failed.")
            }
          }
        }
        if let firstFailure { throw firstFailure }
      }
      phase = .closing(task)
    }
    do {
      try await task.value
      entries.removeAll()
      phase = .closed
    } catch {
      let failure =
        (error as? ModelRuntimeFailure)
        ?? ModelRuntimeFailure(.cleanupFailed, "Executor store cleanup failed.")
      phase = .failed(failure)
      throw failure
    }
  }
}
