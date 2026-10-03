import Foundation
import LanguageModelCore

/// Owns the lifecycle of one explicitly selected, configured model target.
///
/// `LanguageModel`/executor and existing `ModelClient` ports enter the same runtime. `ModelRuntime` adds
/// one-run-at-a-time authority, deadline/cancellation enforcement, stream
/// validation, and native-resource shutdown without introducing routing,
/// fallback, retry, or model selection.
public actor ModelRuntime {
  public nonisolated let id: ModelRuntimeID
  public nonisolated let modelDescriptor: ModelDescriptor

  public nonisolated var providerID: String { modelDescriptor.providerID }
  public nonisolated var capabilities: ModelCapabilities { modelDescriptor.capabilities }

  private enum Phase {
    case idle
    case reserved(ModelRunID)
    case running(ModelRunID)
    case draining(ModelRunID, ModelRuntimeDrainReason)
    case closing
    case closed
    case failed(ModelRuntimeFailure)
  }

  private struct ActiveRun {
    let id: ModelRunID
    let control: ModelRunControl
  }

  private struct ReservedRun {
    let id: ModelRunID
    let request: ModelRequest
  }

  private let client: any ModelClient
  private let cleanup: @Sendable () async throws -> Void
  private let policy: ModelRuntimePolicy

  private var phase: Phase = .idle
  private var reservedRun: ReservedRun?
  private var activeRun: ActiveRun?
  private var shutdownTask: Task<Void, any Error>?

  public init(
    id: ModelRuntimeID,
    client: any ModelClient,
    descriptor: ModelDescriptor? = nil,
    policy: ModelRuntimePolicy = .default,
    cleanup: @escaping @Sendable () async throws -> Void = {}
  ) throws {
    guard client.invocationSemantics == .exactRequest else {
      throw ModelRuntimeFailure(
        .invalidConfiguration,
        "ModelRuntime requires exact-request provider semantics; request-decorating clients are standalone-only."
      )
    }
    let clientDescriptor = client.modelDescriptor
    let resolvedDescriptor: ModelDescriptor
    if let descriptor {
      resolvedDescriptor = descriptor
    } else if let clientDescriptor {
      resolvedDescriptor = clientDescriptor
    } else {
      throw ModelRuntimeFailure(
        .invalidConfiguration,
        "A configured runtime requires an authoritative model descriptor."
      )
    }

    do {
      try resolvedDescriptor.validateGenerationContract()
    } catch {
      throw ModelRuntimeFailure(
        .invalidConfiguration,
        "The configured model descriptor is invalid."
      )
    }

    guard Self.validIdentifier(id.rawValue),
      resolvedDescriptor.providerID == client.providerID
    else {
      throw ModelRuntimeFailure(
        .invalidConfiguration,
        "Runtime, provider, and model identities must be valid and consistent."
      )
    }

    if let clientDescriptor, clientDescriptor != resolvedDescriptor {
      throw ModelRuntimeFailure(
        .invalidConfiguration,
        "The configured descriptor conflicts with the provider descriptor."
      )
    }

    self.id = id
    self.client = client
    self.modelDescriptor = resolvedDescriptor
    self.policy = policy
    self.cleanup = cleanup
  }

  public func status() -> ModelRuntimeStatus {
    switch phase {
    case .idle:
      return ModelRuntimeStatus(phase: .idle)
    case .reserved(let id):
      return ModelRuntimeStatus(phase: .reserved, activeRunID: id)
    case .running(let id):
      return ModelRuntimeStatus(phase: .running, activeRunID: id)
    case .draining(let id, let reason):
      return ModelRuntimeStatus(phase: .draining, activeRunID: id, drainReason: reason)
    case .closing:
      return ModelRuntimeStatus(
        phase: .closing,
        activeRunID: activeRun?.id,
        drainReason: activeRun == nil ? nil : .shutdown
      )
    case .closed:
      return ModelRuntimeStatus(phase: .closed)
    case .failed(let failure):
      return ModelRuntimeStatus(
        phase: .failed,
        activeRunID: activeRun?.id,
        failure: failure
      )
    }
  }

  /// Reserves the single invocation slot without entering provider code.
  ///
  /// Durable orchestrators use this boundary to establish runtime ownership,
  /// persist a started receipt, and only then call `start(_:)` with the returned
  /// reservation. No model-provider effect occurs while the slot is reserved.
  public func reserve(_ request: ModelRequest) throws -> ModelRunReservation {
    try Task.checkCancellation()
    switch phase {
    case .idle:
      break
    case .reserved, .running, .draining:
      throw ModelRuntimeFailure(.busy, "A model invocation is already active or draining.")
    case .closing:
      throw ModelRuntimeFailure(.closing, "The model runtime is shutting down.")
    case .closed:
      throw ModelRuntimeFailure(.closed, "The model runtime is closed.")
    case .failed(let failure):
      throw failure
    }

    try request.validateGenerationContract()
    try request.validateSupportedCapabilities(modelDescriptor.capabilities)
    if let requestedModel = request.modelID, requestedModel != modelDescriptor.id {
      throw ModelGenerationFailure(
        .invalidRequest,
        "The request model identifier does not match the selected runtime."
      )
    }

    let runID = ModelRunID()
    reservedRun = ReservedRun(id: runID, request: request)
    phase = .reserved(runID)
    return ModelRunReservation(runtimeID: id, runID: runID)
  }

  /// Releases an unstarted reservation.
  ///
  /// The identity check prevents a delayed cleanup from clearing a newer slot.
  @discardableResult
  public func release(_ reservation: ModelRunReservation) -> Bool {
    guard reservation.runtimeID == id,
      case .reserved(let activeID) = phase,
      activeID == reservation.runID,
      reservedRun?.id == reservation.runID
    else {
      return false
    }

    reservedRun = nil
    phase = .idle
    return true
  }

  /// Starts one validated model invocation immediately.
  ///
  /// This convenience reserves and consumes the slot in one actor-isolated
  /// operation. Durable callers which must persist before provider entry should
  /// use `reserve(_:)` followed by `start(_:)`.
  public func start(_ request: ModelRequest) throws -> ModelRun {
    let reservation = try reserve(request)
    do {
      return try start(reservation)
    } catch {
      _ = release(reservation)
      throw error
    }
  }

  /// Consumes one matching reservation and enters the provider adapter.
  public func start(_ reservation: ModelRunReservation) throws -> ModelRun {
    guard reservation.runtimeID == id else {
      throw ModelRuntimeFailure(
        .invalidReservation,
        "The model run reservation belongs to a different runtime."
      )
    }

    switch phase {
    case .reserved(let activeID)
    where activeID == reservation.runID && reservedRun?.id == reservation.runID:
      break
    case .closing:
      throw ModelRuntimeFailure(.closing, "The model runtime is shutting down.")
    case .closed:
      throw ModelRuntimeFailure(.closed, "The model runtime is closed.")
    case .failed(let failure):
      throw failure
    case .idle, .reserved, .running, .draining:
      throw ModelRuntimeFailure(
        .invalidReservation,
        "The model run reservation is stale or does not own the active slot."
      )
    }

    guard let reservedRun, reservedRun.id == reservation.runID else {
      throw ModelRuntimeFailure(
        .invariantViolation,
        "The reserved model invocation is missing its request."
      )
    }
    // Cancellation must not consume the caller-owned reservation or enter a provider.
    try Task.checkCancellation()
    let request = reservedRun.request
    let runID = reservedRun.id
    self.reservedRun = nil
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let control = ModelRunControl(continuation: pair.continuation)
    let selectedClient = client
    let authoritativeDescriptor = modelDescriptor
    let maximumEventCount = policy.maximumEventCount

    let pump = Task { [self, control] in
      await Self.pump(
        client: selectedClient,
        descriptor: authoritativeDescriptor,
        request: request,
        maximumEventCount: maximumEventCount,
        control: control,
        publishPostRunState: { await self.runDidDrain(runID) },
        publishDrainFailure: { await self.runDidFailToDrain(runID, failure: $0) }
      )
      control.markPumpFinished()
    }
    control.installPump(pump)

    let watchdog = Task { [self, control] in
      do {
        try await Task.sleep(for: request.deadline)
      } catch {
        return
      }
      guard !control.isPumpFinished else { return }
      self.deadlineExpired(runID)
    }
    control.installWatchdog(watchdog)

    activeRun = ActiveRun(id: runID, control: control)
    phase = .running(runID)

    pair.continuation.onTermination = { @Sendable [weak self] termination in
      guard case .cancelled = termination else { return }
      Task { await self?.cancel(runID, reason: .consumerTermination) }
    }

    return ModelRun(
      id: runID,
      events: pair.stream,
      cancel: { [self, control] in
        await self.cancel(runID, reason: .cancellation)
        await control.waitUntilPumpFinished()
      },
      effectState: { control.effectState }
    )
  }

  /// Runs one request to its authoritative completed turn.
  ///
  /// This convenience preserves the same admission, deadline, cancellation,
  /// stream-validation, and clean-EOF authority as `start(_:)`. Callers that
  /// need stream telemetry may use `onEvent` or `start(_:)` directly.
  public func generate(
    _ request: ModelRequest,
    onEvent: @escaping @Sendable (ModelEvent) -> Void = { _ in }
  ) async throws -> ModelTurn {
    let run = try start(request)
    do {
      return try await withTaskCancellationHandler {
        var terminal: ModelTurn?
        for try await event in run.events {
          try Task.checkCancellation()
          onEvent(event)
          if case .completed(let turn) = event { terminal = turn }
        }

        // Cancellation may terminate AsyncThrowingStream iteration with `nil`
        // before its terminal error is observed by the iterator. Classify the
        // task state before treating a missing turn as a runtime invariant.
        try Task.checkCancellation()
        guard let terminal else {
          throw ModelRuntimeFailure(
            .invariantViolation,
            "ModelRuntime ended without its authoritative completed turn."
          )
        }
        return terminal
      } onCancel: {
        // The handler cannot suspend. It starts cancellation immediately; the
        // async catch below provides the definitive drain completion boundary.
        Task { await run.cancel() }
      }
    } catch {
      guard Task.isCancelled else { throw error }
      await run.cancel()
      // Cancellation is not proof of native settlement. Preserve the failure
      // for THIS run; do not attribute a newer borrower's failure to this caller.
      if case .failed(let failure) = phase, activeRun?.id == run.id {
        throw failure
      }
      throw CancellationError()
    }
  }

  /// Cancels the active invocation and returns only after its provider pump has
  /// drained and the runtime has published its post-run state.
  public func cancelActiveRun() async {
    guard let activeRun else { return }
    cancel(activeRun.id, reason: .cancellation)
    await activeRun.control.waitUntilPumpFinished()
  }

  /// Cancels and drains the active invocation, then releases adapter-owned
  /// resources exactly once. A drain timeout or cleanup failure is explicit and
  /// leaves this runtime unusable; cleanup is never reported as successful when
  /// the native operation may still be running.
  public func shutdown() async throws {
    if case .closed = phase { return }
    if case .failed(let failure) = phase { throw failure }

    let task: Task<Void, any Error>
    if let existing = shutdownTask {
      task = existing
    } else {
      let active = activeRun
      reservedRun = nil
      if let active {
        phase = .closing
        _ = active.control.requestTermination(
          ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
        )
        active.control.cancelPump()
      } else {
        phase = .closing
      }

      let cleanup = self.cleanup
      let timeout = policy.shutdownDrainTimeout
      let pollInterval = policy.drainPollInterval
      let created = Task {
        if let active {
          let clock = ContinuousClock()
          let deadline = clock.now.advanced(by: timeout)
          while !active.control.isPumpFinished {
            guard clock.now < deadline else {
              throw ModelRuntimeFailure(
                .shutdownDrainTimedOut,
                "The active model invocation did not drain before shutdown."
              )
            }
            try await Task.sleep(for: pollInterval)
          }
        }
        // The pump can finish with failed native drain. Finished is not the
        // same as safe-to-release; preserve quarantine in that case.
        if case .failed(let failure) = self.phase { throw failure }
        do {
          try await cleanup()
        } catch let failure as ModelRuntimeFailure {
          throw failure
        } catch {
          throw ModelRuntimeFailure(
            .cleanupFailed,
            "Model runtime cleanup failed."
          )
        }
      }
      shutdownTask = created
      task = created
    }

    do {
      try await task.value
      phase = .closed
      reservedRun = nil
      activeRun = nil
    } catch let failure as ModelRuntimeFailure {
      phase = .failed(failure)
      reservedRun = nil
      throw failure
    } catch {
      let failure = ModelRuntimeFailure(.cleanupFailed, "Model runtime shutdown failed.")
      phase = .failed(failure)
      reservedRun = nil
      throw failure
    }
  }

  private func cancel(_ runID: ModelRunID, reason: ModelRuntimeDrainReason) {
    terminateActiveRun(
      runID,
      reason: reason,
      failure: ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
    )
  }

  private func deadlineExpired(_ runID: ModelRunID) {
    terminateActiveRun(
      runID,
      reason: .deadlineExceeded,
      failure: ModelGenerationFailure(
        .deadlineExceeded,
        "Model generation exceeded its deadline."
      )
    )
  }

  private func terminateActiveRun(
    _ runID: ModelRunID,
    reason: ModelRuntimeDrainReason,
    failure: ModelGenerationFailure
  ) {
    guard let activeRun, activeRun.id == runID else { return }
    switch phase {
    case .running:
      phase = .draining(runID, reason)
    case .reserved, .draining, .closing, .closed, .failed, .idle:
      break
    }
    _ = activeRun.control.requestTermination(failure)
    activeRun.control.cancelPump()
  }

  private func runDidDrain(_ runID: ModelRunID) {
    guard activeRun?.id == runID else { return }
    activeRun = nil
    switch phase {
    case .running(let activeID) where activeID == runID,
      .draining(let activeID, _) where activeID == runID:
      phase = .idle
    case .reserved, .closing, .closed, .failed, .idle, .running, .draining:
      break
    }
  }

  private func runDidFailToDrain(_ runID: ModelRunID, failure: ModelRuntimeFailure) {
    guard activeRun?.id == runID else { return }
    // Retain the active run/client. A failed native drain is not idle and must
    // never authorize another invocation or release resources optimistically.
    phase = .failed(failure)
  }

  private nonisolated static func pump(
    client: any ModelClient,
    descriptor: ModelDescriptor,
    request: ModelRequest,
    maximumEventCount: Int,
    control: ModelRunControl,
    publishPostRunState: @escaping @Sendable () async -> Void,
    publishDrainFailure: @escaping @Sendable (ModelRuntimeFailure) async -> Void
  ) async {
    guard !Task.isCancelled else {
      await control.finish(
        throwing: ModelGenerationFailure(.cancelled, "Model generation was cancelled."),
        after: publishPostRunState)
      return
    }
    let ownedInvocation = (client as? any ModelClientWithOwnedInvocation)?.invocation(
      request: request, onStarted: { control.markProviderEffectStarted() })
    let events = ownedInvocation?.events ?? client.stream(request: request)
    await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        var collector = try ModelStreamCollector(request: request)
        var eventCount = 0
        var pendingTerminal: ModelEvent?
        for try await providerEvent in events {
          try Task.checkCancellation()
          eventCount += 1
          guard eventCount <= maximumEventCount else {
            throw ModelGenerationFailure(
              .limitExceeded,
              "Model event count exceeds the runtime limit."
            )
          }

          let event: ModelEvent
          if case .started(let emittedDescriptor) = providerEvent {
            // Observing provider .started is itself the effect boundary. Record
            // certainty before validating the event payload so a malformed
            // started event cannot be misclassified as a definite local failure.
            control.markProviderEffectStarted()
            if let emittedDescriptor, emittedDescriptor != descriptor {
              throw ModelGenerationFailure(
                .malformedEvent,
                "The provider emitted a descriptor that conflicts with the selected runtime."
              )
            }
            event = .started(descriptor: descriptor)
          } else {
            event = providerEvent
          }

          let terminalTurn = try collector.receive(event)
          if let terminalTurn {
            // A completed event is authoritative only after provider EOF proves
            // that no extra event or trailing transport failure exists.
            pendingTerminal = .completed(terminalTurn)
            continue
          }
          guard control.yield(event) else { throw CancellationError() }
        }
        // The provider may finish its stream before its native task/teardown.
        // Do not publish completion or idle until both boundaries have settled.
        do {
          try await ownedInvocation?.waitForCompletion()
        } catch {
          ownedInvocation?.cancel()
          control.retainUnprovedInvocation(ownedInvocation)
          let failure = ModelRuntimeFailure(
            .nativeDrainFailed, "The provider did not prove native drain completion.")
          await control.finish(throwing: failure, after: { await publishDrainFailure(failure) })
          return
        }
        if let requestedTermination = control.requestedTerminationFailure {
          throw requestedTermination
        }
        try Task.checkCancellation()
        let terminalTurn = try collector.finish()
        let terminal = pendingTerminal ?? .completed(terminalTurn)
        guard
          await control.complete(
            with: terminal,
            after: publishPostRunState
          )
        else {
          throw CancellationError()
        }
      } catch {
        let terminalFailure = normalize(error, taskWasCancelled: Task.isCancelled)
        do {
          try await ownedInvocation?.cancelAndDrain()
        } catch {
          control.retainUnprovedInvocation(ownedInvocation)
          let failure = ModelRuntimeFailure(
            .nativeDrainFailed, "The provider did not prove native drain completion.")
          await control.finish(throwing: failure, after: { await publishDrainFailure(failure) })
          return
        }
        await control.finish(
          throwing: terminalFailure,
          after: publishPostRunState
        )
      }
    } onCancel: {
      ownedInvocation?.cancel()
    }
  }

  private nonisolated static func normalize(
    _ error: any Error,
    taskWasCancelled: Bool
  ) -> any Error {
    if let failure = error as? ModelGenerationFailure {
      if failure.code == .cancelled, !taskWasCancelled {
        return ModelGenerationFailure(.transportFailure, "Model transport failed.")
      }
      return failure
    }
    if let failure = error as? any ModelClientFailure { return failure }
    if let failure = error as? ModelStreamContractError {
      switch failure {
      case .missingStartedEvent, .duplicateStartedEvent, .eventAfterCompletion:
        return ModelGenerationFailure(.malformedEvent, failure.localizedDescription)
      case .missingCompletedEvent:
        return ModelGenerationFailure(.terminalMissing, failure.localizedDescription)
      case .duplicateCompletedEvent:
        return ModelGenerationFailure(.duplicateTerminal, failure.localizedDescription)
      }
    }
    if error is CancellationError {
      return taskWasCancelled
        ? ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
        : ModelGenerationFailure(.transportFailure, "Model transport failed.")
    }
    return ModelGenerationFailure(.transportFailure, "Model transport failed.")
  }

  nonisolated static func validIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= ModelRuntimeID.maximumUTF8Bytes else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      !CharacterSet.controlCharacters.contains(scalar)
        && !scalar.properties.isWhitespace
    }
  }
}
