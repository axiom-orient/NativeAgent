import Foundation
import NativeAgent
import NativeAgentDomain
import LanguageModelCore
import LanguageModelRuntime
import NativeAgentSkills

/// Stable application handle. Provider/runtime objects remain manager-owned implementation details.
public struct ManagedAgent: Sendable {
  public let id: String
  private let manager: AgentManager

  init(id: String, manager: AgentManager) {
    self.id = id
    self.manager = manager
  }

  public func definition() async throws -> AgentDefinition {
    try await manager.definition(agentID: id)
  }

  public func selectProvider(_ provider: ModelProviderSelection) async throws -> AgentDefinition {
    try await manager.selectProvider(agentID: id, provider)
  }

  public func soul() async throws -> String {
    try await manager.soul(agentID: id)
  }

  public func setSoul(_ value: String) async throws {
    try await manager.setSoul(agentID: id, value)
  }

  public func responseConfiguration() async throws -> AgentResponseConfiguration {
    try await manager.responseConfiguration(agentID: id)
  }

  public func setResponseConfiguration(_ value: AgentResponseConfiguration) async throws {
    try await manager.setResponseConfiguration(agentID: id, value)
  }

  public func user() async throws -> String {
    try await manager.user(agentID: id)
  }

  public func setUser(_ value: String) async throws {
    try await manager.setUser(agentID: id, value)
  }

  public func memory() async throws -> String {
    try await manager.memory(agentID: id)
  }

  public func setMemory(_ value: String) async throws {
    try await manager.setMemory(agentID: id, value)
  }

  public func skills() async throws -> SkillLibrary {
    try await manager.skillLibrary(agentID: id)
  }

  @discardableResult
  public func run(
    _ input: String,
    sessionID: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.run(
      agentID: id,
      input: input,
      sessionID: sessionID,
      title: title,
      metadata: metadata
    )
  }

  @discardableResult
  public func run(
    contentParts: [ModelContentPart],
    sessionID: String? = nil,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.run(
      agentID: id,
      contentParts: contentParts,
      sessionID: sessionID,
      title: title,
      metadata: metadata
    )
  }

  @discardableResult
  public func send(
    _ input: String,
    to sessionID: String,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.send(agentID: id, input: input, to: sessionID, metadata: metadata)
  }

  @discardableResult
  public func send(
    contentParts: [ModelContentPart],
    to sessionID: String,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.send(
      agentID: id,
      contentParts: contentParts,
      to: sessionID,
      metadata: metadata
    )
  }

  @discardableResult
  public func queue(
    _ input: String,
    to sessionID: String,
    identity: AgentCommandIdentity,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    try await manager.queue(
      agentID: id,
      input: input,
      to: sessionID,
      identity: identity,
      metadata: metadata
    )
  }

  @discardableResult
  public func edit(
    messageID: String,
    replacingWith input: String,
    in sessionID: String,
    identity: AgentCommandIdentity,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    try await manager.edit(
      agentID: id,
      messageID: messageID,
      replacingWith: input,
      in: sessionID,
      identity: identity,
      metadata: metadata
    )
  }

  @discardableResult
  public func retry(
    sessionID: String,
    identity: AgentCommandIdentity
  ) async throws -> AgentRun {
    try await manager.retry(agentID: id, sessionID: sessionID, identity: identity)
  }

  @discardableResult
  public func fork(
    sessionID: String,
    throughMessageIndex: Int,
    newSessionID: String,
    identity: AgentCommandIdentity,
    title: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentCommandReceipt {
    try await manager.fork(
      agentID: id,
      sessionID: sessionID,
      throughMessageIndex: throughMessageIndex,
      newSessionID: newSessionID,
      identity: identity,
      title: title,
      metadata: metadata
    )
  }

  public func session(id sessionID: String) async throws -> SessionSnapshot {
    try await manager.session(agentID: id, id: sessionID)
  }

  public func messages(
    sessionID: String,
    offset: Int = 0,
    limit: Int = 100
  ) async throws -> SessionMessagePage {
    try await manager.messages(
      agentID: id,
      sessionID: sessionID,
      offset: offset,
      limit: limit
    )
  }

  @discardableResult
  public func resume(sessionID: String) async throws -> AgentRun {
    try await manager.resume(agentID: id, sessionID: sessionID)
  }

  public func pendingApproval(sessionID: String) async throws -> ApprovalRequest? {
    try await manager.pendingApproval(agentID: id, sessionID: sessionID)
  }

  @discardableResult
  public func waitForSignal(
    sessionID: String,
    identifier: String,
    details: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.waitForSignal(
      agentID: id,
      sessionID: sessionID,
      identifier: identifier,
      details: details
    )
  }

  @discardableResult
  public func resumeSignalWait(
    sessionID: String,
    identifier: String,
    payload: JSONValue = .null,
    userPrompt: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.resumeSignalWait(
      agentID: id,
      sessionID: sessionID,
      identifier: identifier,
      payload: payload,
      userPrompt: userPrompt,
      metadata: metadata
    )
  }

  @discardableResult
  public func waitUntil(
    sessionID: String,
    resumeAt: Date,
    identifier: String = UUID().uuidString,
    details: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.waitUntil(
      agentID: id,
      sessionID: sessionID,
      resumeAt: resumeAt,
      identifier: identifier,
      details: details
    )
  }

  @discardableResult
  public func resumeTimeWait(
    sessionID: String,
    asOf: Date? = nil,
    userPrompt: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) async throws -> AgentRun {
    try await manager.resumeTimeWait(
      agentID: id,
      sessionID: sessionID,
      asOf: asOf,
      userPrompt: userPrompt,
      metadata: metadata
    )
  }

  @discardableResult
  public func timeoutWait(
    sessionID: String,
    identifier: String,
    reason: String = "Pending wait timed out."
  ) async throws -> AgentRun {
    try await manager.timeoutWait(
      agentID: id,
      sessionID: sessionID,
      identifier: identifier,
      reason: reason
    )
  }

  public func pendingModelInvocation(
    sessionID: String
  ) async throws -> AgentPendingModelInvocation? {
    try await manager.pendingModelInvocation(agentID: id, sessionID: sessionID)
  }

  @discardableResult
  public func resolveModelInvocation(
    sessionID: String,
    invocationID: String,
    resolution: AgentModelInvocationResolution
  ) async throws -> AgentRun {
    try await manager.resolveModelInvocation(
      agentID: id,
      sessionID: sessionID,
      invocationID: invocationID,
      resolution: resolution
    )
  }

  public func inspectRecovery(sessionID: String) async throws -> AgentRecoveryInspection {
    try await manager.inspectRecovery(agentID: id, sessionID: sessionID)
  }

  @discardableResult
  public func resolveToolEffect(
    sessionID: String,
    callID: String,
    resolution: AgentToolEffectResolution,
    continueRunning: Bool = true
  ) async throws -> AgentRun {
    try await manager.resolveToolEffect(
      agentID: id,
      sessionID: sessionID,
      callID: callID,
      resolution: resolution,
      continueRunning: continueRunning
    )
  }

  @discardableResult
  public func retryPendingExecutionClaimRelease(sessionID: String) async throws -> Bool {
    try await manager.retryPendingExecutionClaimRelease(agentID: id, sessionID: sessionID)
  }

  @discardableResult
  public func resolveApproval(
    sessionID: String,
    requestID: String,
    decision: ApprovalDecision
  ) async throws -> AgentRun {
    try await manager.resolveApproval(
      agentID: id,
      sessionID: sessionID,
      requestID: requestID,
      decision: decision
    )
  }

  public func loadArtifact(
    sessionID: String,
    artifactID: String
  ) async throws -> Data {
    try await manager.loadArtifact(agentID: id, sessionID: sessionID, artifactID: artifactID)
  }

  @discardableResult
  public func executeTool(
    _ call: ToolCall,
    in sessionID: String
  ) async throws -> AgentRun {
    try await manager.executeTool(agentID: id, call, in: sessionID)
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try await manager.availableTools(agentID: id)
  }

  public func discoverTools(
    intent: String,
    limit: Int = 8
  ) async throws -> [ToolCapabilitySummary] {
    try await manager.discoverTools(agentID: id, intent: intent, limit: limit)
  }

  public func toolContract(named name: String) async throws -> ToolDefinition? {
    try await manager.toolContract(agentID: id, named: name)
  }

  public func toolEffect(
    sessionID: String,
    callID: String
  ) async throws -> EffectRecord? {
    try await manager.toolEffect(agentID: id, sessionID: sessionID, callID: callID)
  }
}
