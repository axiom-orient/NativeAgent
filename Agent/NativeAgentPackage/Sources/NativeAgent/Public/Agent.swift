import Foundation
import NativeAgentDomain
import NativeAgentExecution
import LanguageModelRuntime
import NativeAgentStore

/// UI-free, durable Agent facade for application code.
///
/// This immutable value holds one actor-isolated coordinator. The runtime
/// owns session state, tool effects, persistence, and recovery.
public struct Agent: Sendable {
  private let coordinator: SessionCoordinator
  private let instructions: String?

  public init(
    modelRuntime: ModelRuntime,
    storage: AgentStorage,
    instructions: String? = nil,
    capabilities: [any AgentCapability] = [],
    toolPacks: [any ToolPack] = [],
    tools: [any ToolExecutor] = [],
    promptAugmentors: [any PromptAugmentor] = [],
    turnPromptAugmentors: [any PromptAugmentor] = [],
    approval: AgentApproval = .denyAll,
    observer: (any RuntimeObserver)? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
  ) throws {
    self.instructions = instructions
    self.coordinator = try Self.makeCoordinator(
      modelRuntime: modelRuntime,
      storage: storage,
      capabilities: capabilities,
      toolPacks: toolPacks,
      tools: tools,
      promptAugmentors: promptAugmentors,
      turnPromptAugmentors: turnPromptAugmentors,
      approval: approval,
      observer: observer,
      configuration: configuration
    )
  }

  public init(
    modelRuntime: ModelRuntime,
    appName: String,
    appGroupIdentifier: String? = nil,
    appGroupContainerURL: URL? = nil,
    storageSubdirectoryName: String = StoreLayout.defaultSubdirectoryName,
    executionClaimStore: (any SessionExecutionClaimStore)? = nil,
    instructions: String? = nil,
    capabilities: [any AgentCapability] = [],
    toolPacks: [any ToolPack] = [],
    tools: [any ToolExecutor] = [],
    promptAugmentors: [any PromptAugmentor] = [],
    turnPromptAugmentors: [any PromptAugmentor] = [],
    approval: AgentApproval = .denyAll,
    observer: (any RuntimeObserver)? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
  ) throws {
    let storage = try AgentStorage.applicationSupport(
      appName: appName,
      appGroupIdentifier: appGroupIdentifier,
      appGroupContainerURL: appGroupContainerURL,
      subdirectoryName: storageSubdirectoryName,
      executionClaimStore: executionClaimStore
    )
    self.instructions = instructions
    self.coordinator = try Self.makeCoordinator(
      modelRuntime: modelRuntime,
      storage: storage,
      capabilities: capabilities,
      toolPacks: toolPacks,
      tools: tools,
      promptAugmentors: promptAugmentors,
      turnPromptAugmentors: turnPromptAugmentors,
      approval: approval,
      observer: observer,
      configuration: configuration
    )
  }

  @discardableResult
  public func run(
    _ input: String,
    sessionID: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    requestMetadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let snapshot: SessionSnapshot
    if let sessionID {
      snapshot = try await coordinator.startSession(
        sessionID: sessionID,
        userPrompt: input,
        systemPrompt: instructions,
        title: title,
        metadata: metadata,
        requestMetadata: requestMetadata
      )
    } else {
      snapshot = try await coordinator.startSession(
        userPrompt: input,
        systemPrompt: instructions,
        title: title,
        metadata: metadata,
        requestMetadata: requestMetadata
      )
    }
    return AgentRun(snapshot: snapshot)
  }

  /// Starts a durable session with typed provider-neutral content.
  @discardableResult
  public func run(
    contentParts: [ModelContentPart],
    sessionID: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:],
    requestMetadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let snapshot: SessionSnapshot
    if let sessionID {
      snapshot = try await coordinator.startSession(
        sessionID: sessionID,
        userContentParts: contentParts,
        systemPrompt: instructions,
        title: title,
        metadata: metadata,
        requestMetadata: requestMetadata
      )
    } else {
      snapshot = try await coordinator.startSession(
        userContentParts: contentParts,
        systemPrompt: instructions,
        title: title,
        metadata: metadata,
        requestMetadata: requestMetadata
      )
    }
    return AgentRun(snapshot: snapshot)
  }

  @discardableResult
  public func send(
    _ input: String,
    to sessionID: String,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.continueSession(
        sessionID: sessionID,
        userPrompt: input,
        requestMetadata: metadata
      )
    )
  }

  /// Durably appends ordered user work without starting execution.
  @discardableResult
  public func queue(
    _ input: String,
    to sessionID: String,
    identity: AgentCommandIdentity,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    try await coordinator.queueCommand(
      sessionID: sessionID,
      input: input,
      identity: identity,
      metadata: metadata
    )
  }

  /// Records a correction as a new user revision; existing effects remain immutable.
  @discardableResult
  public func edit(
    messageID: String,
    replacingWith input: String,
    in sessionID: String,
    identity: AgentCommandIdentity,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    try await coordinator.editCommand(
      sessionID: sessionID,
      messageID: messageID,
      input: input,
      identity: identity,
      metadata: metadata
    )
  }

  /// Continues a failed session only when no uncertain effect needs reconciliation.
  @discardableResult
  public func retry(
    sessionID: String,
    identity: AgentCommandIdentity
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.retryCommand(
        sessionID: sessionID,
        identity: identity
      ))
  }

  /// Creates an isolated session from a bounded transcript prefix.
  @discardableResult
  public func fork(
    sessionID: String,
    throughMessageIndex: Int,
    newSessionID: String,
    identity: AgentCommandIdentity,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    try await coordinator.forkCommand(
      sessionID: sessionID,
      throughMessageIndex: throughMessageIndex,
      newSessionID: newSessionID,
      identity: identity,
      title: title,
      metadata: metadata
    )
  }

  /// Appends typed user content to an existing durable session.
  @discardableResult
  public func send(
    contentParts: [ModelContentPart],
    to sessionID: String,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.continueSession(
        sessionID: sessionID,
        userContentParts: contentParts,
        requestMetadata: metadata
      )
    )
  }

  @discardableResult
  public func resume(sessionID: String) async throws -> AgentRun {
    AgentRun(snapshot: try await coordinator.run(sessionID: sessionID))
  }

  public func session(id sessionID: String) async throws -> SessionSnapshot {
    try await coordinator.loadSession(sessionID: sessionID)
  }

  public func sessions(
    limit: Int = 100,
    offset: Int = 0
  ) async throws -> [SessionSummary] {
    try await coordinator.listSessionSummaries(limit: limit, offset: offset)
  }

  public func messages(
    sessionID: String,
    offset: Int = 0,
    limit: Int = 100
  ) async throws -> SessionMessagePage {
    try await coordinator.loadSessionMessages(
      sessionID: sessionID,
      offset: offset,
      limit: limit
    )
  }

  public func pendingApproval(sessionID: String) async throws -> ApprovalRequest? {
    try await coordinator.pendingApprovalRequest(sessionID: sessionID)
  }

  /// Durably pauses a running session until the host supplies a matching signal.
  @discardableResult
  public func waitForSignal(
    sessionID: String,
    identifier: String,
    details: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.waitForSignal(
        sessionID: sessionID,
        identifier: identifier,
        details: details
      )
    )
  }

  /// Supplies a matching external signal and resumes Agent execution.
  @discardableResult
  public func resumeSignalWait(
    sessionID: String,
    identifier: String,
    payload: JSONValue = .null,
    userPrompt: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.resumeSignalWait(
        sessionID: sessionID,
        identifier: identifier,
        payload: payload,
        userPrompt: userPrompt,
        requestMetadata: metadata
      )
    )
  }

  /// Durably pauses a running session until the specified deadline.
  @discardableResult
  public func waitUntil(
    sessionID: String,
    resumeAt: Date,
    identifier: String = UUID().uuidString,
    details: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.waitUntil(
        sessionID: sessionID,
        resumeAt: resumeAt,
        identifier: identifier,
        details: details
      )
    )
  }

  /// Resumes a due time wait. A future deadline remains fail-closed as waiting.
  @discardableResult
  public func resumeTimeWait(
    sessionID: String,
    asOf: Date? = nil,
    userPrompt: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.resumeTimeWait(
        sessionID: sessionID,
        asOf: asOf,
        userPrompt: userPrompt,
        requestMetadata: metadata
      )
    )
  }

  /// Converts a still-pending wait into a durable failed session.
  @discardableResult
  public func timeoutWait(
    sessionID: String,
    identifier: String,
    reason: String = "Pending wait timed out."
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.timeoutWait(
        sessionID: sessionID,
        identifier: identifier,
        reason: reason
      )
    )
  }

  public func pendingModelInvocation(
    sessionID: String
  ) async throws -> AgentPendingModelInvocation? {
    try await coordinator.pendingModelInvocation(sessionID: sessionID)
      .map(AgentPendingModelInvocation.init)
  }

  /// Resolves a provider call whose remote outcome is uncertain after interruption.
  /// NativeAgent never performs a blind retry; retry must be explicitly authorized here.
  @discardableResult
  public func resolveModelInvocation(
    sessionID: String,
    invocationID: String,
    resolution: AgentModelInvocationResolution
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.resolvePendingModelInvocation(
        sessionID: sessionID,
        invocationID: invocationID,
        resolution: resolution.runtimeValue
      )
    )
  }

  /// Inspects pending tool calls and durable effect receipts without executing a tool.
  public func inspectRecovery(
    sessionID: String
  ) async throws -> AgentRecoveryInspection {
    AgentRecoveryInspection(
      try await coordinator.inspectRecovery(sessionID: sessionID)
    )
  }

  /// Resolves an uncertain mutating tool effect without invoking its executor.
  /// By default the Agent then resumes model execution from the reconciled result.
  @discardableResult
  public func resolveToolEffect(
    sessionID: String,
    callID: String,
    resolution: AgentToolEffectResolution,
    continueRunning: Bool = true
  ) async throws -> AgentRun {
    let resolved = try await coordinator.resolvePendingToolEffect(
      sessionID: sessionID,
      callID: callID,
      resolution: resolution.runtimeValue
    )
    guard continueRunning else {
      return AgentRun(snapshot: resolved)
    }
    return AgentRun(snapshot: try await coordinator.run(sessionID: sessionID))
  }

  /// Retries release of an execution claim that remained owned after a store failure.
  @discardableResult
  public func retryPendingExecutionClaimRelease(
    sessionID: String
  ) async throws -> Bool {
    try await coordinator.retryPendingExecutionClaimRelease(sessionID: sessionID)
  }

  @discardableResult
  public func resolveApproval(
    sessionID: String,
    requestID: String,
    decision: ApprovalDecision
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.resolvePendingApproval(
        sessionID: sessionID,
        requestID: requestID,
        decision: decision
      )
    )
  }

  public func loadArtifact(
    sessionID: String,
    artifactID: String
  ) async throws -> Data {
    try await coordinator.loadArtifact(
      sessionID: sessionID,
      artifactID: artifactID
    )
  }

  /// Executes one host-issued tool call without a model invocation.
  /// Validation, approval, effect receipts, artifacts, and journal semantics are
  /// identical to model-issued tool execution. The session must be running.
  @discardableResult
  public func executeTool(
    _ call: ToolCall,
    in sessionID: String
  ) async throws -> AgentRun {
    AgentRun(
      snapshot: try await coordinator.executeToolCall(call, sessionID: sessionID)
    )
  }

  public func availableTools() async -> [ToolDefinition] {
    await coordinator.availableTools()
  }

  public func discoverTools(
    intent: String,
    limit: Int = 8
  ) async throws -> [ToolCapabilitySummary] {
    try await coordinator.discoverTools(intent: intent, limit: limit)
  }

  public func toolContract(named name: String) async -> ToolDefinition? {
    await coordinator.toolContract(named: name)
  }

  /// Reads the durable receipt for a mutating tool call without executing it.
  public func toolEffect(
    sessionID: String,
    callID: String
  ) async throws -> EffectRecord? {
    try await coordinator.toolEffect(sessionID: sessionID, callID: callID)
  }

  private static func makeCoordinator(
    modelRuntime: ModelRuntime,
    storage: AgentStorage,
    capabilities: [any AgentCapability],
    toolPacks: [any ToolPack],
    tools: [any ToolExecutor],
    promptAugmentors: [any PromptAugmentor],
    turnPromptAugmentors: [any PromptAugmentor],
    approval: AgentApproval,
    observer: (any RuntimeObserver)?,
    configuration: AgentConfiguration
  ) throws -> SessionCoordinator {
    let packs = assembledToolPacks(
      capabilities: capabilities,
      toolPacks: toolPacks,
      tools: tools
    )

    let assembledPromptAugmentors: [any PromptAugmentor] =
      [InstructionAssemblyPromptAugmentor()]
      + capabilities.map { $0 as any PromptAugmentor }
      + promptAugmentors

    return try SessionCoordinator(
      modelRuntime: modelRuntime,
      approvalRouter: approval.router,
      runtimeStore: storage.store,
      executionClaimStore: storage.executionClaimStore,
      executionAuthority: storage.executionAuthority,
      toolPacks: packs,
      configuration: configuration.runtimeConfiguration(for: modelRuntime.modelDescriptor),
      promptAugmentor: PromptAugmentorChain(assembledPromptAugmentors),
      turnPromptAugmentor: turnPromptAugmentors.isEmpty ? nil : PromptAugmentorChain(turnPromptAugmentors),
      observer: observer
    )
  }
  package static func assembledToolPacks(
    capabilities: [any AgentCapability],
    toolPacks: [any ToolPack],
    tools: [any ToolExecutor]
  ) -> [any ToolPack] {
    var packs: [any ToolPack] = capabilities.map { $0 as any ToolPack } + toolPacks
    if tools.isEmpty == false { packs.append(AgentToolPack(tools: tools)) }
    return packs
  }

}
