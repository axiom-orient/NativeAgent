import NativeAgentDomain
import Foundation
import LanguageModelRuntime

extension SessionCoordinator {
  @discardableResult
  public func startSession(
    userPrompt: String,
    systemPrompt: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    requestMetadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy = .disabled
  ) async throws -> SessionSnapshot {
    try await startSession(
      sessionID: idGenerator(),
      userPrompt: userPrompt,
      systemPrompt: systemPrompt,
      title: title,
      metadata: metadata,
      requestMetadata: requestMetadata,
      responseContinuation: responseContinuation
    )
  }

  @discardableResult
  public func startSession(
    sessionID: String,
    userPrompt: String,
    systemPrompt: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    requestMetadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy = .disabled
  ) async throws -> SessionSnapshot {
    try await startSession(
      sessionID: sessionID,
      userMessage: AgentMessage(
        id: idGenerator(),
        role: .user,
        content: userPrompt,
        createdAt: now(),
        metadata: requestMetadata
      ),
      systemPrompt: systemPrompt,
      title: title,
      metadata: metadata,
      responseContinuation: responseContinuation
    )
  }

  @discardableResult
  public func startSession(
    userContentParts: [ModelContentPart],
    systemPrompt: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    requestMetadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy = .disabled
  ) async throws -> SessionSnapshot {
    try await startSession(
      sessionID: idGenerator(),
      userContentParts: userContentParts,
      systemPrompt: systemPrompt,
      title: title,
      metadata: metadata,
      requestMetadata: requestMetadata,
      responseContinuation: responseContinuation
    )
  }

  @discardableResult
  public func startSession(
    sessionID: String,
    userContentParts: [ModelContentPart],
    systemPrompt: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    requestMetadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy = .disabled
  ) async throws -> SessionSnapshot {
    try await startSession(
      sessionID: sessionID,
      userMessage: AgentMessage(
        id: idGenerator(),
        role: .user,
        contentParts: userContentParts,
        createdAt: now(),
        metadata: requestMetadata
      ),
      systemPrompt: systemPrompt,
      title: title,
      metadata: metadata,
      responseContinuation: responseContinuation
    )
  }

  @discardableResult
  public func startSession(
    sessionID: String,
    userMessage: AgentMessage,
    systemPrompt: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy = .disabled
  ) async throws -> SessionSnapshot {
    guard sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw AgentError.invalidConfiguration("Session identifier must not be empty.")
    }
    let selectedModelID = modelRuntime.modelDescriptor.id
    try resourceValidator.validateUserMessage(userMessage)
    try await store.prepare()

    return try await withSessionExecution(sessionID: sessionID) {
      guard try await store.loadSessionRuntimeAdmission(sessionID: sessionID) == nil else {
        throw AgentError.invariantViolation(
          "Session identifier already exists: \(sessionID)."
        )
      }
      let timestamp = now()
      let sessionMetadata = ResponseContinuationMetadata.applying(
        policy: responseContinuation,
        to: metadata
      )
      let augmentedSystemPrompt = try await promptAugmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
          sessionID: sessionID,
          basePrompt: systemPrompt,
          userPrompt: userMessage.content,
          title: title,
          modelID: selectedModelID,
          metadata: sessionMetadata,
          availableTools: registry.definitions
        )
      )

      let snapshot = SessionSnapshotTransitions.makeStartedSession(
        input: SessionStartInput(
          sessionID: sessionID,
          userMessage: userMessage,
          systemPrompt: augmentedSystemPrompt,
          title: title,
          modelID: selectedModelID,
          metadata: sessionMetadata,
          providerID: modelRuntime.providerID,
          timestamp: timestamp
        ),
        idGenerator: idGenerator
      )
      try await snapshotWriter.create(snapshot)

      return try await advanceLoadedSnapshot(snapshot)
    }
  }

  @discardableResult
  public func continueSession(
    sessionID: String,
    userPrompt: String,
    requestMetadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy? = nil
  ) async throws -> SessionSnapshot {
    try await continueSession(
      sessionID: sessionID,
      userMessage: AgentMessage(
        id: idGenerator(),
        role: .user,
        content: userPrompt,
        createdAt: now(),
        metadata: requestMetadata
      ),
      responseContinuation: responseContinuation
    )
  }

  @discardableResult
  public func continueSession(
    sessionID: String,
    userContentParts: [ModelContentPart],
    requestMetadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy? = nil
  ) async throws -> SessionSnapshot {
    try await continueSession(
      sessionID: sessionID,
      userMessage: AgentMessage(
        id: idGenerator(),
        role: .user,
        contentParts: userContentParts,
        createdAt: now(),
        metadata: requestMetadata
      ),
      responseContinuation: responseContinuation
    )
  }

  @discardableResult
  public func continueSession(
    sessionID: String,
    userMessage: AgentMessage,
    responseContinuation: ResponseContinuationPolicy? = nil
  ) async throws -> SessionSnapshot {
    try resourceValidator.validateUserMessage(userMessage)

    return try await withSessionExecution(sessionID: sessionID) {
      var loadedSnapshot = try await loadExistingSnapshotForAdvancement(
        sessionID: sessionID
      )
      loadedSnapshot = try await prepareRunnableSnapshot(loadedSnapshot)
      loadedSnapshot = try SessionSnapshotTransitions.replacingMetadata(
        ResponseContinuationMetadata.applying(
          policy: responseContinuation,
          to: loadedSnapshot.metadata
        ),
        in: loadedSnapshot
      )

      let reduction = try SessionSnapshotTransitions.appendingUserMessage(
        userMessage,
        to: loadedSnapshot,
        timestamp: now()
      )
      let persistedSnapshot = try await snapshotWriter.persist(reduction)
      return try await advanceLoadedSnapshot(persistedSnapshot)
    }
  }

  @discardableResult
  public func run(sessionID: String) async throws -> SessionSnapshot {
    try await withSessionExecution(sessionID: sessionID) {
      let loadedSnapshot = try await loadExistingSnapshotForAdvancement(
        sessionID: sessionID
      )
      let snapshot = try await prepareRunnableSnapshot(loadedSnapshot)
      return try await advanceLoadedSnapshot(snapshot)
    }
  }

  public func loadSession(sessionID: String) async throws -> SessionSnapshot {
    try await loadExistingSnapshot(sessionID: sessionID)
  }

  public func loadSessionSummary(sessionID: String) async throws -> SessionSummary {
    if let summaryStore = store as? any SessionSummaryLookupStore {
      guard let summary = try await summaryStore.loadSessionSummary(sessionID: sessionID) else {
        throw AgentError.sessionNotFound(sessionID)
      }
      return summary
    }
    return SessionSummary(snapshot: try await loadExistingSnapshot(sessionID: sessionID))
  }

  public func listSessionSummaries(
    limit: Int = 100,
    offset: Int = 0
  ) async throws -> [SessionSummary] {
    try SessionReadLimits.validatePage(limit: limit, offset: offset)
    guard let summaryStore = store as? any SessionSummaryStore else {
      throw AgentError.unsupportedSurface(
        "Bounded session listing requires a SessionSummaryStore."
      )
    }
    return try await summaryStore.listSessionSummaries(
      limit: limit,
      offset: offset
    )
  }

  public func loadSessionMessages(
    sessionID: String,
    offset: Int = 0,
    limit: Int = 100
  ) async throws -> SessionMessagePage {
    try SessionReadLimits.validatePage(limit: limit, offset: offset)
    guard let messageStore = store as? any SessionMessagePageStore else {
      throw AgentError.unsupportedSurface(
        "Bounded session messages require a SessionMessagePageStore."
      )
    }
    return try await messageStore.loadSessionMessages(
      sessionID: sessionID,
      offset: offset,
      limit: limit
    )
  }

  public func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
    try await store.loadArtifact(sessionID: sessionID, artifactID: artifactID)
  }

  func loadExistingSnapshot(sessionID: String) async throws -> SessionSnapshot {
    guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
      throw AgentError.sessionNotFound(sessionID)
    }
    try resourceValidator.validate(snapshot: snapshot)
    return snapshot
  }

  func loadExistingSnapshotForAdvancement(
    sessionID: String
  ) async throws -> SessionSnapshot {
    guard let admission = try await store.loadSessionRuntimeAdmission(sessionID: sessionID) else {
      throw AgentError.sessionNotFound(sessionID)
    }
    try resourceValidator.validate(admission: admission)

    guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
      throw AgentError.persistenceFailure(
        "Session \(sessionID) disappeared between runtime admission and hydration."
      )
    }
    guard snapshot.revision == admission.revision else {
      throw AgentError.persistenceFailure(
        "Session \(sessionID) changed between runtime admission and hydration."
      )
    }
    try await snapshotWriter.registerLoadedSnapshotForAdvancement(snapshot)
    return snapshot
  }

  func prepareRunnableSnapshot(_ snapshot: SessionSnapshot) async throws -> SessionSnapshot {
    let inspection = try await inspectRecovery(snapshot: snapshot)
    guard inspection.requiresHostReconciliation == false,
      inspection.pendingToolEffects.contains(where: { $0.disposition == .invalid }) == false
    else {
      throw AgentError.invariantViolation(
        "Session advancement is blocked until pending tool effects requiring host reconciliation are resolved."
      )
    }

    guard snapshot.status == .waiting else {
      return snapshot
    }

    guard let waitState = snapshot.waitState else {
      throw AgentError.sessionWaiting(snapshot.sessionID)
    }

    switch waitState.kind {
    case .time:
      guard let resumeAt = waitState.resumeAt, resumeAt <= now() else {
        throw AgentError.sessionWaiting(snapshot.sessionID)
      }
      return try await clearWait(snapshot)
    case .approval, .modelInvocation, .signal:
      throw AgentError.sessionWaiting(snapshot.sessionID)
    }
  }
}
