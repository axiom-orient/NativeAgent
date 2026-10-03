import Foundation
import NativeAgent
import NativeAgentDomain
import LanguageModelCore
import LanguageModelRuntime
import NativeAgentSkills

/// Host-facing authority for Agent identity, provider selection and one coherent data root.
///
/// The manager does not replace the durable `Agent` kernel. It resolves one explicit provider,
/// assembles Soul + curated memory + a pinned Skill catalog, then delegates execution to `Agent`.
public actor AgentManager {
  public static let agentMetadataKey = "native-agent.agent.id"
  public static let soulSnapshotMetadataKey = "native-agent.agent.soul.sha256"
  public static let responseSnapshotMetadataKey = "native-agent.agent.response.sha256"
  public static let skillSnapshotMetadataKey = "native-agent.agent.skills.sha256"

  public let dataStore: AgentDataStore
  public let providers: ModelProviderRegistry
  private let workspace: AgentWorkspace

  private let assembler: ManagedAgentAssembler

  public init(
    dataStore: AgentDataStore,
    providers: ModelProviderRegistry,
    capabilities: [any AgentCapability] = [],
    toolPacks: [any ToolPack] = [],
    tools: [any ToolExecutor] = [],
    promptAugmentors: [any PromptAugmentor] = [],
    skillScriptRunner: (any SkillScriptRunner)? = nil,
    skillIntentService: (any SkillIntentService)? = nil,
    approval: AgentApproval = .denyAll,
    observer: (any RuntimeObserver)? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
  ) {
    self.dataStore = dataStore
    self.providers = providers
    let workspace = AgentWorkspace(dataStore: dataStore)
    self.workspace = workspace
    self.assembler = ManagedAgentAssembler(
      dataStore: dataStore,
      providers: providers,
      workspace: workspace,
      approval: approval,
      observer: observer,
      configuration: configuration,
      capabilities: capabilities,
      toolPacks: toolPacks,
      tools: tools,
      promptAugmentors: promptAugmentors,
      skillScriptRunner: skillScriptRunner ?? DisabledManagedSkillScriptRunner(),
      skillIntentService: skillIntentService ?? SkillIntentRouterService()
    )
  }

  public func createAgent(
    id: String,
    name: String,
    provider: ModelProviderSelection,
    soul: String = AgentSoul.default,
    user: String = "",
    memory: String = "",
    knowledgeOwnership: AgentKnowledgeOwnership = .localCuratedMemory,
    response: AgentResponseConfiguration = .standard
  ) async throws -> AgentDefinition {
    guard await providers.providers().contains(where: { $0.id == provider.providerID }) else {
      throw ModelGenerationFailure(
        .sourceUnavailable, "Unknown model provider: \(provider.providerID)")
    }
    return try await workspace.create(
      id: id,
      name: name,
      provider: provider,
      soul: soul,
      user: user,
      memory: memory,
      knowledgeOwnership: knowledgeOwnership,
      response: response
    )
  }

  public func agents() async throws -> [AgentDefinition] {
    try await workspace.definitions()
  }

  public func definition(agentID: String) async throws -> AgentDefinition {
    try await workspace.definition(id: agentID)
  }

  public func selectProvider(
    agentID: String,
    _ provider: ModelProviderSelection
  ) async throws -> AgentDefinition {
    guard await providers.providers().contains(where: { $0.id == provider.providerID }) else {
      throw ModelGenerationFailure(
        .sourceUnavailable, "Unknown model provider: \(provider.providerID)")
    }
    return try await workspace.selectProvider(agentID: agentID, provider: provider)
  }

  public func setSoul(agentID: String, _ value: String) async throws {
    try await workspace.setSoul(agentID: agentID, value)
  }

  public func soul(agentID: String) async throws -> String {
    try await workspace.soul(agentID: agentID)
  }

  public func responseConfiguration(agentID: String) async throws -> AgentResponseConfiguration {
    try await workspace.responseConfiguration(agentID: agentID)
  }

  public func setResponseConfiguration(
    agentID: String, _ value: AgentResponseConfiguration
  ) async throws {
    try await workspace.setResponseConfiguration(agentID: agentID, value)
  }

  public func setUser(agentID: String, _ value: String) async throws {
    try await workspace.setUser(agentID: agentID, value)
  }

  public func user(agentID: String) async throws -> String {
    try await workspace.user(agentID: agentID)
  }

  public func setMemory(agentID: String, _ value: String) async throws {
    try await workspace.setMemory(agentID: agentID, value)
  }

  public func memory(agentID: String) async throws -> String {
    try await workspace.memory(agentID: agentID)
  }

  public func providerCatalog() async -> [ModelProviderDescriptor] {
    await providers.providers()
  }

  public func modelCatalog(providerID: String) async throws -> [ModelDescriptor] {
    try await providers.models(providerID: providerID)
  }

  public func handle(agentID: String) async throws -> ManagedAgent {
    _ = try await workspace.definition(id: agentID)
    return ManagedAgent(id: agentID, manager: self)
  }

  @discardableResult
  public func run(
    agentID: String,
    input: String,
    sessionID: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await currentAssembly(agentID: agentID)
    return try await withAssembly(assembly) { assembly in
      let prepared = try ManagedRunMetadata(
        caller: metadata,
        agentID: agentID,
        soulDigest: assembly.soulDigest,
        skillDigest: assembly.skillSnapshot.digest,
        responseDigest: assembly.responseDigest
      )
      return try await assembly.agent.run(
        input,
        sessionID: sessionID,
        title: title,
        metadata: prepared.session,
        requestMetadata: prepared.request
      )
    }
  }

  /// Starts a managed session with provider-neutral typed content while preserving the same
  /// Agent identity/provider/Soul/Skill metadata contract as text input.
  @discardableResult
  public func run(
    agentID: String,
    contentParts: [ModelContentPart],
    sessionID: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await currentAssembly(agentID: agentID)
    return try await withAssembly(assembly) { assembly in
      let prepared = try ManagedRunMetadata(
        caller: metadata,
        agentID: agentID,
        soulDigest: assembly.soulDigest,
        skillDigest: assembly.skillSnapshot.digest,
        responseDigest: assembly.responseDigest
      )
      return try await assembly.agent.run(
        contentParts: contentParts,
        sessionID: sessionID,
        title: title,
        metadata: prepared.session,
        requestMetadata: prepared.request
      )
    }
  }

  @discardableResult
  public func send(
    agentID: String,
    input: String,
    to sessionID: String,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.send(
        input,
        to: sessionID,
        metadata: try ManagedRunMetadata.validateCaller(metadata)
      )
    }
  }

  /// Appends typed content to an existing managed session after validating its pinned execution
  /// identity.
  @discardableResult
  public func send(
    agentID: String,
    contentParts: [ModelContentPart],
    to sessionID: String,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.send(
        contentParts: contentParts,
        to: sessionID,
        metadata: try ManagedRunMetadata.validateCaller(metadata)
      )
    }
  }

  @discardableResult
  public func queue(
    agentID: String,
    input: String,
    to sessionID: String,
    identity: AgentCommandIdentity,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.queue(
        input,
        to: sessionID,
        identity: identity,
        metadata: try ManagedRunMetadata.validateCaller(metadata)
      )
    }
  }

  @discardableResult
  public func edit(
    agentID: String,
    messageID: String,
    replacingWith input: String,
    in sessionID: String,
    identity: AgentCommandIdentity,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.edit(
        messageID: messageID,
        replacingWith: input,
        in: sessionID,
        identity: identity,
        metadata: try ManagedRunMetadata.validateCaller(metadata)
      )
    }
  }

  @discardableResult
  public func retry(
    agentID: String,
    sessionID: String,
    identity: AgentCommandIdentity
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.retry(sessionID: sessionID, identity: identity)
    }
  }

  /// Forks a managed session without losing its Agent ownership or pinned execution identity.
  /// The durable kernel owns fork idempotency; the manager only supplies the reserved managed
  /// metadata that a raw fork intentionally does not infer.
  @discardableResult
  public func fork(
    agentID: String,
    sessionID: String,
    throughMessageIndex: Int,
    newSessionID: String,
    identity: AgentCommandIdentity,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      var metadata = try ManagedRunMetadata.validateCaller(metadata)
      metadata[Self.agentMetadataKey] = .string(agentID)
      metadata[Self.soulSnapshotMetadataKey] = .string(assembly.soulDigest)
      metadata[Self.skillSnapshotMetadataKey] = .string(assembly.skillSnapshot.digest)
      metadata[Self.responseSnapshotMetadataKey] = .string(assembly.responseDigest)
      return try await assembly.agent.fork(
        sessionID: sessionID,
        throughMessageIndex: throughMessageIndex,
        newSessionID: newSessionID,
        identity: identity,
        title: title,
        metadata: metadata
      )
    }
  }

  /// Loads a managed session after verifying its Agent ownership. This read path intentionally
  /// remains available when Soul/Skill snapshots drift so a host can inspect why continuation is
  /// blocked; every advancing operation below uses `pinnedAssembly` instead.
  public func session(agentID: String, id sessionID: String) async throws -> SessionSnapshot {
    try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
  }

  public func messages(
    agentID: String,
    sessionID: String,
    offset: Int = 0,
    limit: Int = 100
  ) async throws -> SessionMessagePage {
    _ = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await dataStore.storage.messages(
      sessionID: sessionID,
      offset: offset,
      limit: limit
    )
  }

  @discardableResult
  public func resume(agentID: String, sessionID: String) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.resume(sessionID: sessionID)
    }
  }

  public func pendingApproval(
    agentID: String,
    sessionID: String
  ) async throws -> ApprovalRequest? {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await assembler.recoveryAccess(for: snapshot).pendingApproval(sessionID: sessionID)
  }

  @discardableResult
  public func waitForSignal(
    agentID: String,
    sessionID: String,
    identifier: String,
    details: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.waitForSignal(
        sessionID: sessionID,
        identifier: identifier,
        details: details
      )
    }
  }

  @discardableResult
  public func resumeSignalWait(
    agentID: String,
    sessionID: String,
    identifier: String,
    payload: JSONValue = .null,
    userPrompt: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.resumeSignalWait(
        sessionID: sessionID,
        identifier: identifier,
        payload: payload,
        userPrompt: userPrompt,
        metadata: try ManagedRunMetadata.validateCaller(metadata)
      )
    }
  }

  @discardableResult
  public func waitUntil(
    agentID: String,
    sessionID: String,
    resumeAt: Date,
    identifier: String = UUID().uuidString,
    details: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.waitUntil(
        sessionID: sessionID,
        resumeAt: resumeAt,
        identifier: identifier,
        details: details
      )
    }
  }

  @discardableResult
  public func resumeTimeWait(
    agentID: String,
    sessionID: String,
    asOf: Date? = nil,
    userPrompt: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.resumeTimeWait(
        sessionID: sessionID,
        asOf: asOf,
        userPrompt: userPrompt,
        metadata: try ManagedRunMetadata.validateCaller(metadata)
      )
    }
  }

  @discardableResult
  public func timeoutWait(
    agentID: String,
    sessionID: String,
    identifier: String,
    reason: String = "Pending wait timed out."
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.timeoutWait(
        sessionID: sessionID,
        identifier: identifier,
        reason: reason
      )
    }
  }

  public func pendingModelInvocation(
    agentID: String,
    sessionID: String
  ) async throws -> AgentPendingModelInvocation? {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await assembler.recoveryAccess(for: snapshot).pendingModelInvocation(sessionID: sessionID)
  }

  @discardableResult
  public func resolveModelInvocation(
    agentID: String,
    sessionID: String,
    invocationID: String,
    resolution: AgentModelInvocationResolution
  ) async throws -> AgentRun {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    let reconciliation = try await assembler.recoveryAccess(for: snapshot).resolveModelInvocation(
      sessionID: sessionID,
      invocationID: invocationID,
      resolution: resolution
    )
    guard reconciliation.requiresContinuation else { return reconciliation.run }
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.resume(sessionID: sessionID)
    }
  }

  public func inspectRecovery(
    agentID: String,
    sessionID: String
  ) async throws -> AgentRecoveryInspection {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await assembler.recoveryAccess(for: snapshot).inspectRecovery(sessionID: sessionID)
  }

  @discardableResult
  public func resolveToolEffect(
    agentID: String,
    sessionID: String,
    callID: String,
    resolution: AgentToolEffectResolution,
    continueRunning: Bool = true
  ) async throws -> AgentRun {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    let reconciled = try await assembler.recoveryAccess(for: snapshot).resolveToolEffect(
      sessionID: sessionID,
      callID: callID,
      resolution: resolution
    )
    guard continueRunning else { return reconciled }
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.resume(sessionID: sessionID)
    }
  }

  @discardableResult
  public func retryPendingExecutionClaimRelease(
    agentID: String,
    sessionID: String
  ) async throws -> Bool {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await assembler.recoveryAccess(for: snapshot).retryPendingExecutionClaimRelease(sessionID: sessionID)
  }

  @discardableResult
  public func resolveApproval(
    agentID: String,
    sessionID: String,
    requestID: String,
    decision: ApprovalDecision
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.resolveApproval(
        sessionID: sessionID,
        requestID: requestID,
        decision: decision
      )
    }
  }

  public func loadArtifact(
    agentID: String,
    sessionID: String,
    artifactID: String
  ) async throws -> Data {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await assembler.recoveryAccess(for: snapshot).loadArtifact(sessionID: sessionID, artifactID: artifactID)
  }

  @discardableResult
  public func executeTool(
    agentID: String,
    _ call: ToolCall,
    in sessionID: String
  ) async throws -> AgentRun {
    let assembly = try await pinnedAssembly(agentID: agentID, sessionID: sessionID)
    return try await withAssembly(assembly) { assembly in
      try await assembly.agent.executeTool(call, in: sessionID)
    }
  }

  public func availableTools(agentID: String) async throws -> [ToolDefinition] {
    try await assembler.toolCatalog(agentID: agentID).definitions
  }

  public func discoverTools(
    agentID: String,
    intent: String,
    limit: Int = 8
  ) async throws -> [ToolCapabilitySummary] {
    try await assembler.toolCatalog(agentID: agentID).discover(intent: intent, limit: limit)
  }

  public func toolContract(
    agentID: String,
    named name: String
  ) async throws -> ToolDefinition? {
    try await assembler.toolCatalog(agentID: agentID).contract(named: name)
  }

  public func toolEffect(
    agentID: String,
    sessionID: String,
    callID: String
  ) async throws -> EffectRecord? {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    return try await assembler.recoveryAccess(for: snapshot).toolEffect(sessionID: sessionID, callID: callID)
  }

  public func skillLibrary(agentID: String) async throws -> SkillLibrary {
    let skillWorkspace = try await workspace.skillWorkspace(agentID: agentID)
    return SkillLibrary(workspace: skillWorkspace)
  }


  /// Per-operation access is always released. Existing connectors transfer an
  /// owned wrapper and retain their shutdown behavior; LocalBackend connectors
  /// lend the host's runtime without transferring shutdown authority. Operation
  /// and cleanup failures remain separate and neither becomes fake success.
  private func withAssembly<Value>(
    _ assembly: ManagedAgentAssembly,
    operation: (ManagedAgentAssembly) async throws -> Value
  ) async throws -> Value {
    let operationResult: Result<Value, any Error>
    do {
      operationResult = .success(try await operation(assembly))
    } catch {
      operationResult = .failure(error)
    }

    let cleanupError: (any Error)?
    do {
      try await assembly.runtimeAccess.release()
      cleanupError = nil
    } catch {
      cleanupError = error
    }

    return try OperationCleanupCompletionPolicy.resolve(
      operation: operationResult,
      cleanupError: cleanupError
    )
  }

  private func currentAssembly(agentID: String) async throws -> ManagedAgentAssembly {
    let definition = try await workspace.definition(id: agentID)
    return try await assembler.make(agentID: agentID, selection: definition.provider)
  }

  private func ownedSessionSnapshot(
    agentID: String,
    sessionID: String
  ) async throws -> SessionSnapshot {
    let snapshot = try await dataStore.storage.session(id: sessionID)
    guard snapshot.metadata[Self.agentMetadataKey]?.stringValue == agentID else {
      throw ManagedAgentError.sessionOwnedByDifferentAgent
    }
    return snapshot
  }

  private func pinnedAssembly(
    agentID: String,
    sessionID: String
  ) async throws -> ManagedAgentAssembly {
    let snapshot = try await ownedSessionSnapshot(agentID: agentID, sessionID: sessionID)
    guard let providerID = snapshot.providerID, let modelID = snapshot.modelID else {
      throw ManagedAgentError.sessionMissingProviderIdentity
    }
    guard let expectedSoulSnapshot = snapshot.metadata[Self.soulSnapshotMetadataKey]?.stringValue
    else {
      throw ManagedAgentError.soulSnapshotChanged
    }
    guard let expectedSkillSnapshot = snapshot.metadata[Self.skillSnapshotMetadataKey]?.stringValue
    else {
      throw ManagedAgentError.skillSnapshotChanged
    }
    guard let expectedResponseSnapshot = snapshot.metadata[Self.responseSnapshotMetadataKey]?.stringValue else {
      throw AgentResponseError.snapshotChanged
    }
    let selection = try ModelProviderSelection(providerID: providerID, modelID: modelID)
    return try await assembler.make(
      agentID: agentID,
      selection: selection,
      expectedSoulSnapshot: expectedSoulSnapshot,
      expectedSkillSnapshot: expectedSkillSnapshot,
      expectedResponseSnapshot: expectedResponseSnapshot
    )
  }


}

private struct DisabledManagedSkillScriptRunner: SkillScriptRunner {
  func run(
    skill: ManagedSkill,
    scriptURL: URL,
    readAccessURL: URL?,
    inputJSON: String,
    secret: String?,
    context: ToolExecutionContext
  ) async throws -> SkillScriptResponse {
    throw AgentError.unsupportedSurface(
      "Skill script execution is not configured for managed Agent \(context.sessionID)."
    )
  }
}
