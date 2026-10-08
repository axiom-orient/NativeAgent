import NativeAgentDomain
import Foundation
import LanguageModelRuntime

struct AgentLoop: Sendable {
  private let modelRuntime: ModelRuntime
  private let approvalRouter: any ApprovalRouter
  private let store: any SessionRuntimeStore
  private let registry: ToolRegistry
  private let validator: ToolCallValidator
  private let configuration: RuntimeConfiguration
  private let compactor: ContextWindowCompactor
  private let snapshotWriter: RuntimeSnapshotWriter
  private let observer: (any RuntimeObserver)?
  private let turnPromptAugmentor: (any PromptAugmentor)?
  private let now: @Sendable () -> Date
  private let idGenerator: @Sendable () -> String

  init(
    modelRuntime: ModelRuntime,
    approvalRouter: any ApprovalRouter,
    store: any SessionRuntimeStore,
    registry: ToolRegistry,
    validator: ToolCallValidator = ToolCallValidator(),
    configuration: RuntimeConfiguration,
    compactor: ContextWindowCompactor = ContextWindowCompactor(),
    snapshotWriter: RuntimeSnapshotWriter,
    turnPromptAugmentor: (any PromptAugmentor)? = nil,
    observer: (any RuntimeObserver)? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.modelRuntime = modelRuntime
    self.approvalRouter = approvalRouter
    self.store = store
    self.registry = registry
    self.validator = validator
    self.configuration = configuration
    self.compactor = compactor
    self.snapshotWriter = snapshotWriter
    self.observer = observer
    self.turnPromptAugmentor = turnPromptAugmentor
    self.now = PersistedTimestamp.clock(now)
    self.idGenerator = idGenerator
  }

  func run(
    snapshot initialSnapshot: SessionSnapshot,
    context: ToolExecutionContext
  ) async throws -> SessionSnapshot {
    var snapshot = initialSnapshot
    let resourceValidator = RuntimeResourceValidator(limits: configuration.resourceLimits)
    let toolRuntime = makeToolRuntime(resourceValidator: resourceValidator)
    let transitions = toolRuntime.transitions
    let effectLedger = toolRuntime.effectLedger
    let toolProcessor = toolRuntime.processor
    let modelInvocationLedger = ModelInvocationLedger(store: store, now: now)
    let pendingRecovery = PendingToolCallRecovery(toolProcessor: toolProcessor)
    let transcriptRepair = TranscriptRepair(transitions: transitions, registry: registry)
    let interruptedToolRecovery = InterruptedToolExecutionRecovery(
      registry: registry,
      effectLedger: effectLedger,
      transitions: transitions,
      transcriptRepair: transcriptRepair
    )
    let responseContinuation = ResponseContinuationController(
      policy: try ResponseContinuationMetadata.policy(from: initialSnapshot.metadata)
    )
    var loopGuard = ToolCallLoopGuard(messages: initialSnapshot.messages)

    do {
      try Task.checkCancellation()
      snapshot = try await pendingRecovery.recoverPendingToolCalls(
        in: snapshot,
        context: context
      )

      let tools = registry.definitions
      let turnPrompt = try await TurnPromptProjection.make(
        snapshot: snapshot, tools: tools, augmentor: turnPromptAugmentor)
      let requestBuilder = AgentLoopRequestBuilder(
        outputFormat: configuration.outputFormat, systemPromptOverride: turnPrompt?.message,
        userPromptOverride: turnPrompt?.userMessage)
      let contextPolicy = turnPrompt?.reservingBudget(in: configuration.contextBudgetPolicy)
        ?? configuration.contextBudgetPolicy
      for _ in 0..<configuration.maxIterations {
        try Task.checkCancellation()
        if let policy = contextPolicy,
          let compaction = try compactor.compactIfNeeded(
            snapshot: snapshot,
            tools: tools,
            policy: policy,
            now: now(),
            minimumRetainedMessageIndex: turnPrompt?.minimumRetainedMessageIndex
          )
        {
          let reduction = try transitions.applyingCompaction(compaction, to: snapshot)
          snapshot = try await snapshotWriter.persist(reduction)
        }

        var requestMessages = configuration.contextBudgetPolicy == nil
          ? snapshot.messages
          : try compactor.projectedMessages(for: snapshot)

        if let policy = contextPolicy,
          try requestBuilder.requiresHardCompaction(
            snapshot: snapshot,
            messages: requestMessages,
            tools: tools
          )
        {
          let hardLimit = requestBuilder.makeRequest(
            snapshot: snapshot,
            messages: requestMessages,
            tools: tools
          ).limits.maxMessages
          var maximumProjectedMessages = min(hardLimit, requestMessages.count - 1)
          var acceptedCompaction: CompactionResult?

          while maximumProjectedMessages > 0 {
            guard let candidate = try compactor.compactForRequestContract(
              snapshot: snapshot,
              tools: tools,
              policy: policy,
              now: now(),
              maximumProjectedMessages: maximumProjectedMessages,
              minimumRetainedMessageIndex: turnPrompt?.minimumRetainedMessageIndex
            ) else {
              break
            }

            let candidateRequest = requestBuilder.makeRequest(
              snapshot: snapshot,
              messages: candidate.messages,
              tools: tools
            )
            do {
              _ = try candidateRequest.inputFootprint()
              acceptedCompaction = candidate
              break
            } catch let failure as ModelGenerationFailure {
              let stillTranscriptPressure =
                candidate.messages.count > candidateRequest.limits.maxMessages
                || failure.code == .limitExceeded
              guard stillTranscriptPressure, candidate.messages.count > 1 else {
                throw failure
              }
              maximumProjectedMessages = min(
                maximumProjectedMessages - 1,
                candidate.messages.count - 1
              )
            }
          }

          if let acceptedCompaction {
            let reduction = try transitions.applyingCompaction(acceptedCompaction, to: snapshot)
            snapshot = try await snapshotWriter.persist(reduction)
            requestMessages = try compactor.projectedMessages(for: snapshot)
          }
        }

        // ContextProjection is the single bridge from durable transcript state
        // to one exact ModelRequest. Its footprint is validated by ModelCore
        // before invocation identity is allocated or any provider effect starts.
        let projection = try requestBuilder.makeProjection(
          snapshot: snapshot,
          messages: requestMessages,
          tools: tools,
          checkpointApplied: configuration.contextBudgetPolicy != nil
        )
        let request = projection.request

        try request.validateSupportedCapabilities(modelRuntime.capabilities)
        let invocationDecision = try await modelInvocationLedger.decision(
          request: request,
          snapshot: snapshot,
          snapshotRevision: projection.sourceRevision,
          providerID: modelRuntime.providerID
        )

        let turn: ModelTurn
        let invocationRecordToComplete: EffectRecord?
        switch invocationDecision {
        case .invoke(let pending, let startedRecord):
          let reservation: ModelRunReservation
          do {
            try Task.checkCancellation()
            reservation = try await modelRuntime.reserve(request)
          } catch let failure as ModelRuntimeFailure where failure.code == .busy {
            throw AgentError.sessionBusy(snapshot.sessionID)
          }

          do {
            try await modelInvocationLedger.save(startedRecord)
          } catch {
            _ = await modelRuntime.release(reservation)
            throw error
          }

          let receivedTurn: ModelTurn
          var modelRun: ModelRun?
          do {
            try Task.checkCancellation()
            let run = try await modelRuntime.start(reservation)
            modelRun = run
            receivedTurn = try await RuntimeModelRunConsumer(
              observer: observer,
              now: now
            ).consume(
              run,
              sessionID: snapshot.sessionID,
              providerID: modelRuntime.providerID
            )
          } catch {
            if modelRun == nil {
              _ = await modelRuntime.release(reservation)
            }
            let generationFailure = error as? ModelGenerationFailure
            let cancelled = error is CancellationError || generationFailure?.code == .cancelled
            let interrupted = cancelled || generationFailure?.code == .deadlineExceeded
            // Cancelling AsyncThrowingStream consumption joins the runtime pump,
            // not necessarily an adapter's buffered producer or remote request.
            // Once a run exists, interruption cannot authorize an automatic retry.
            // Even .started may have been buffered and lost during cancellation.
            let outcomeUnknown = (modelRun != nil && interrupted)
              || (modelRun?.effectState == .started
                && EffectFailureClassifier.certainty(for: error) == .outcomeUnknown)
            if outcomeUnknown {
              snapshot = try await persistModelInvocationWait(
                pending,
                in: snapshot,
                transitions: transitions
              )
            } else {
              let persistedError: any Error = cancelled
                ? ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
                : error
              snapshot = try await persistModelInvocationFailure(
                startedRecord: startedRecord,
                error: persistedError,
                in: snapshot,
                transitions: transitions,
                ledger: modelInvocationLedger
              )
            }
            if cancelled { throw CancellationError() }
            throw error
          }

          // Provider EOF made the model outcome definitive. Failures below
          // are deterministic local validation/ledger failures and must never
          // be reclassified as an uncertain remote invocation.
          do {
            try resourceValidator.validate(turn: receivedTurn)
            turn = receivedTurn
            invocationRecordToComplete = startedRecord
          } catch {
            snapshot = try await persistModelInvocationFailure(
              startedRecord: startedRecord,
              error: error,
              in: snapshot,
              transitions: transitions,
              ledger: modelInvocationLedger
            )
            throw error
          }

        case .replay(_, let replayedTurn):
          try resourceValidator.validate(turn: replayedTurn)
          turn = replayedTurn
          invocationRecordToComplete = nil

        case .uncertain(let pending):
          let waitState = SessionWaitState.modelInvocation(
            identifier: pending.id,
            providerID: pending.providerID,
            snapshotRevision: pending.snapshotRevision,
            createdAt: pending.createdAt
          )
          let waitReduction = try transitions.markingWaiting(
            waitState,
            in: snapshot
          )
          snapshot = try await snapshotWriter.persist(
            waitReduction,
            journalEntries: [.waitEntered(waitState)]
          )
          return snapshot

        case .failed(_, let message):
          throw AgentError.modelFailure(message)
        }

        let assistantReduction = try transitions.recordingAssistantTurn(
          turn,
          containsSensitiveToolCall: registry.containsSensitiveData(in: turn.toolCalls),
          continuation: responseContinuation,
          in: snapshot
        )
        let assistantMessage = try assistantReduction.snapshot.messages.dropFirst(snapshot.messages.count).first.map { $0 } ?? {
          throw AgentError.invariantViolation(
            "Assistant turn transition did not append a durable assistant message."
          )
        }()
        let completedInvocationEffect: EffectRecord?
        do {
          completedInvocationEffect = try invocationRecordToComplete.map { startedRecord in
            try modelInvocationLedger.completedRecord(
              startedRecord: startedRecord,
              turn: turn,
              assistantMessage: assistantMessage
            )
          }
        } catch {
          if let startedRecord = invocationRecordToComplete {
            snapshot = try await persistModelInvocationFailure(
              startedRecord: startedRecord,
              error: error,
              in: snapshot,
              transitions: transitions,
              ledger: modelInvocationLedger
            )
          }
          throw error
        }
        let assistantEntries = [SessionJournal.Entry.assistantTurn(assistantMessage)]
          + (assistantReduction.snapshot.status == .completed ? [.sessionCompleted] : [])
        snapshot = try await snapshotWriter.persist(
          assistantReduction,
          effects: [completedInvocationEffect].compactMap { $0 },
          journalEntries: assistantEntries
        )

        if turn.toolCalls.isEmpty {
          if snapshot.status == .running { continue }
          return snapshot
        }

        for call in turn.toolCalls {
          try Task.checkCancellation()
          if loopGuard.shouldBlock(call) {
            snapshot = try await toolProcessor.reject(
              call,
              content: ToolCallLoopGuard.repeatedCallMessage,
              snapshot: snapshot
            )
            loopGuard.record(call, resultMessage: snapshot.messages.last)
            continue
          }
          snapshot = try await toolProcessor.process(
            call,
            snapshot: snapshot,
            context: context
          )
          loopGuard.record(call, resultMessage: snapshot.messages.last)
        }
      }

      let maxTurnsError = AgentError.maxTurnsExceeded(configuration.maxIterations)
      let failedReduction = try transitions.markingFailed(snapshot, error: maxTurnsError)
      snapshot = try await snapshotWriter.persist(
        failedReduction,
        journalEntries: [
          .sessionFailed(
            errorType: String(reflecting: type(of: maxTurnsError))
          )
        ]
      )
      throw maxTurnsError
    } catch is CancellationError {
      do {
        snapshot = try await latestDurableSnapshot(
          forRecoveryFrom: snapshot,
          resourceValidator: resourceValidator
        )
        if snapshot.status != .waiting
          && snapshot.status != .failed
          && snapshot.status != .completed
        {
          let failedReduction = try await interruptedToolRecovery.failureReduction(
            in: snapshot,
            error: CancellationError()
          )
          snapshot = try await snapshotWriter.persist(
            failedReduction,
            journalEntries: [
              .sessionFailed(
                errorType: String(reflecting: CancellationError.self)
              )
            ]
          )
        }
      } catch let recoveryError {
        throw AgentError.persistenceFailure(
          "Session \(snapshot.sessionID) was cancelled; durable cancellation recovery failed: "
            + recoveryError.localizedDescription
        )
      }
      throw CancellationError()
    } catch {
      if let agentError = error as? AgentError {
        switch agentError {
        case .persistenceFailure, .sessionBusy:
          throw agentError
        default:
          break
        }
      }

      do {
        snapshot = try await latestDurableSnapshot(
          forRecoveryFrom: snapshot,
          resourceValidator: resourceValidator
        )
        if snapshot.status != .waiting
          && snapshot.status != .failed
          && snapshot.status != .completed
        {
          let failedReduction = try await interruptedToolRecovery.failureReduction(
            in: snapshot,
            error: error
          )
          snapshot = try await snapshotWriter.persist(
            failedReduction,
            journalEntries: [
              .sessionFailed(
                errorType: String(reflecting: type(of: error))
              )
            ]
          )
        }
      } catch let recoveryError {
        throw AgentError.persistenceFailure(
          "Session \(snapshot.sessionID) failed with \(error.localizedDescription); "
            + "durable failure recovery also failed: \(recoveryError.localizedDescription)"
        )
      }
      throw error
    }
  }


  /// Records and executes one host-issued tool call through the canonical tool path.
  /// This method never invokes the model. The caller must provide a running session.
  func processHostToolCall(
    _ call: ToolCall,
    snapshot initialSnapshot: SessionSnapshot,
    context: ToolExecutionContext
  ) async throws -> SessionSnapshot {
    guard initialSnapshot.status == .running else {
      throw AgentError.invariantViolation(
        "Host-issued tool execution requires a running session."
      )
    }
    let resourceValidator = RuntimeResourceValidator(limits: configuration.resourceLimits)
    try resourceValidator.validate(snapshot: initialSnapshot)
    let toolRuntime = makeToolRuntime(resourceValidator: resourceValidator)

    let turn = ModelTurn(
      content: "",
      toolCalls: [call],
      metadata: ["hostIssuedToolCall": .bool(true)]
    )
    let assistantReduction = try toolRuntime.transitions.appendingAssistantTurn(
      turn,
      containsSensitiveToolCall: registry.containsSensitiveData(in: [call]),
      to: initialSnapshot
    )
    let assistantEntries = assistantReduction.snapshot.messages.last.map {
      [SessionJournal.Entry.assistantTurn($0)]
    } ?? []
    let recordedSnapshot = try await snapshotWriter.persist(
      assistantReduction,
      journalEntries: assistantEntries
    )

    return try await processRecordedHostToolCall(
      call,
      snapshot: recordedSnapshot,
      context: context
    )
  }

  /// Resumes a host-issued tool call that is already durably present in the transcript.
  /// Approval continuation uses this path so host work cannot accidentally enter model inference.
  func processRecordedHostToolCall(
    _ call: ToolCall,
    snapshot initialSnapshot: SessionSnapshot,
    context: ToolExecutionContext
  ) async throws -> SessionSnapshot {
    guard initialSnapshot.status == .running else {
      throw AgentError.invariantViolation(
        "Host-issued tool execution requires a running session."
      )
    }
    let resourceValidator = RuntimeResourceValidator(limits: configuration.resourceLimits)
    try resourceValidator.validate(snapshot: initialSnapshot)
    let toolRuntime = makeToolRuntime(resourceValidator: resourceValidator)
    var snapshot = initialSnapshot
    let transcriptRepair = TranscriptRepair(transitions: toolRuntime.transitions, registry: registry)
    let interruptedToolRecovery = InterruptedToolExecutionRecovery(
      registry: registry,
      effectLedger: toolRuntime.effectLedger,
      transitions: toolRuntime.transitions,
      transcriptRepair: transcriptRepair
    )

    do {
      return try await toolRuntime.processor.process(
        call,
        snapshot: snapshot,
        context: context
      )
    } catch is CancellationError {
      do {
        snapshot = try await latestDurableSnapshot(
          forRecoveryFrom: snapshot,
          resourceValidator: resourceValidator
        )
        if snapshot.status != .waiting
          && snapshot.status != .failed
          && snapshot.status != .completed
        {
          let failedReduction = try await interruptedToolRecovery.failureReduction(
            in: snapshot,
            error: CancellationError()
          )
          _ = try await snapshotWriter.persist(
            failedReduction,
            journalEntries: [
              .sessionFailed(errorType: String(reflecting: CancellationError.self))
            ]
          )
        }
      } catch let recoveryError {
        throw AgentError.persistenceFailure(
          "Host-issued tool call in session \(snapshot.sessionID) was cancelled; "
            + "durable cancellation recovery failed: \(recoveryError.localizedDescription)"
        )
      }
      throw CancellationError()
    } catch {
      if let agentError = error as? AgentError {
        switch agentError {
        case .persistenceFailure, .sessionBusy:
          throw agentError
        default:
          break
        }
      }

      do {
        snapshot = try await latestDurableSnapshot(
          forRecoveryFrom: snapshot,
          resourceValidator: resourceValidator
        )
        if snapshot.status != .waiting
          && snapshot.status != .failed
          && snapshot.status != .completed
        {
          let failedReduction = try await interruptedToolRecovery.failureReduction(
            in: snapshot,
            error: error
          )
          _ = try await snapshotWriter.persist(
            failedReduction,
            journalEntries: [
              .sessionFailed(errorType: String(reflecting: type(of: error)))
            ]
          )
        }
      } catch let recoveryError {
        throw AgentError.persistenceFailure(
          "Host-issued tool call in session \(snapshot.sessionID) failed with \(error.localizedDescription); "
            + "durable failure recovery also failed: \(recoveryError.localizedDescription)"
        )
      }
      throw error
    }
  }

  private func makeToolRuntime(
    resourceValidator: RuntimeResourceValidator
  ) -> AgentLoopToolRuntime {
    let transitions = AgentLoopSnapshotTransitions(
      now: now,
      idGenerator: idGenerator,
      maximumFailureMessageUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
    )
    let effectStore: any EffectLedgerStore = store
    let effectLedger = ToolEffectLedger(store: effectStore, now: now)
    let approvalLedger = ApprovalEffectLedger(store: effectStore, now: now)
    let toolResultHandler = AgentLoopToolResultHandler(
      store: store,
      transitions: transitions,
      resourceValidator: resourceValidator,
      now: now
    )
    let processor = AgentLoopToolProcessor(
      approvalRouter: approvalRouter,
      store: store,
      registry: registry,
      validator: validator,
      transitions: transitions,
      toolResultHandler: toolResultHandler,
      snapshotWriter: snapshotWriter,
      effectLedger: effectLedger,
      approvalLedger: approvalLedger,
      observer: observer,
      now: now
    )
    return AgentLoopToolRuntime(
      transitions: transitions,
      effectLedger: effectLedger,
      processor: processor
    )
  }

  private func persistModelInvocationFailure(
    startedRecord: EffectRecord,
    error: any Error,
    in snapshot: SessionSnapshot,
    transitions: AgentLoopSnapshotTransitions,
    ledger: ModelInvocationLedger
  ) async throws -> SessionSnapshot {
    let boundedError = RuntimeSessionFailure.boundedMessage(
      error.localizedDescription,
      maximumUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
    ).message
    let failedInvocationEffect = try ledger.failedRecord(
      startedRecord: startedRecord,
      error: boundedError
    )
    let reduction = try transitions.markingFailed(snapshot, error: error)
    return try await snapshotWriter.persist(
      reduction,
      effects: [failedInvocationEffect],
      journalEntries: [
        .sessionFailed(
          errorType: String(reflecting: type(of: error))
        )
      ]
    )
  }

  private func persistModelInvocationWait(
    _ pending: PendingModelInvocation,
    in snapshot: SessionSnapshot,
    transitions: AgentLoopSnapshotTransitions
  ) async throws -> SessionSnapshot {
    let waitState = SessionWaitState.modelInvocation(
      identifier: pending.id,
      providerID: pending.providerID,
      snapshotRevision: pending.snapshotRevision,
      createdAt: pending.createdAt
    )
    let waitReduction = try transitions.markingWaiting(
      waitState,
      in: snapshot
    )
    return try await snapshotWriter.persist(
      waitReduction,
      journalEntries: [.waitEntered(waitState)]
    )
  }

  private func latestDurableSnapshot(
    forRecoveryFrom current: SessionSnapshot,
    resourceValidator: RuntimeResourceValidator
  ) async throws -> SessionSnapshot {
    guard let persisted = try await store.loadSnapshot(sessionID: current.sessionID) else {
      throw AgentError.persistenceFailure(
        "Session \(current.sessionID) disappeared before failure recovery."
      )
    }
    guard persisted.sessionID == current.sessionID,
      persisted.revision >= current.revision
    else {
      throw AgentError.persistenceFailure(
        "Session \(current.sessionID) recovery loaded revision \(persisted.revision), "
          + "older than in-memory revision \(current.revision)."
      )
    }
    try resourceValidator.validate(snapshot: persisted)
    return persisted
  }
}


private struct AgentLoopToolRuntime: Sendable {
  let transitions: AgentLoopSnapshotTransitions
  let effectLedger: ToolEffectLedger
  let processor: AgentLoopToolProcessor
}
