import Foundation
import NativeAgent
import NativeAgentDomain
import LanguageModelCore
import LanguageModelRuntime
import NativeAgentSkills

/// Immutable composition recipe. Workspace, registry, kernel and runtime keep their own authority.
/// This value creates no tasks and owns no mutable session or provider state.
struct ManagedAgentAssembler: Sendable {
  let dataStore: AgentDataStore
  let providers: ModelProviderRegistry
  let workspace: AgentWorkspace
  let approval: AgentApproval
  let observer: (any RuntimeObserver)?
  let configuration: AgentConfiguration
  let capabilities: [any AgentCapability]
  let toolPacks: [any ToolPack]
  let tools: [any ToolExecutor]
  let promptAugmentors: [any PromptAugmentor]
  let skillScriptRunner: any SkillScriptRunner
  let skillIntentService: any SkillIntentService

  func recoveryAccess(for snapshot: SessionSnapshot) throws -> AgentRecoveryAccess {
    let skillDigest = snapshot.metadata[AgentManager.skillSnapshotMetadataKey]?.stringValue
    let recoveryDefinitions: [ToolDefinition]
    if let skillDigest, skillDigest != AgentSkillSnapshot.emptyDigest {
      recoveryDefinitions = SkillToolPack.recoveryDefinitions
    } else {
      recoveryDefinitions = []
    }
    return try AgentRecoveryAccess(
      storage: dataStore.storage,
      capabilities: capabilities,
      toolPacks: toolPacks,
      tools: tools,
      contractOnlyDefinitions: recoveryDefinitions,
      configuration: configuration
    )
  }

  func toolCatalog(agentID: String) async throws -> AgentToolCatalog {
    _ = try await workspace.definition(id: agentID)
    let skillWorkspace = try await workspace.skillWorkspace(agentID: agentID)
    let library = SkillLibrary(workspace: skillWorkspace)
    let skillSnapshot = try await AgentSkillSnapshot.make(library: library)

    var resolvedCapabilities = capabilities
    if !skillSnapshot.selectedSkills.isEmpty {
      resolvedCapabilities.append(
        SkillAgentIntegration(
          snapshot: skillSnapshot.executionSnapshot,
          secretLibrary: library,
          scriptRunner: skillScriptRunner,
          intentService: skillIntentService
        )
      )
    }

    return try AgentToolCatalog(
      capabilities: resolvedCapabilities,
      toolPacks: toolPacks,
      tools: tools,
      configuration: configuration
    )
  }

  func make(
    agentID: String,
    selection: ModelProviderSelection,
    expectedSoulSnapshot: String? = nil,
    expectedSkillSnapshot: String? = nil,
    expectedResponseSnapshot: String? = nil
  ) async throws -> ManagedAgentAssembly {
    let promptSnapshot = try await workspace.promptSnapshot(agentID: agentID)
    if let expectedSoulSnapshot, expectedSoulSnapshot != promptSnapshot.soulDigest {
      throw ManagedAgentError.soulSnapshotChanged
    }
    let response = try await workspace.responseConfiguration(agentID: agentID)
    let responseDigest = try response.snapshotDigest()
    if let expectedResponseSnapshot, expectedResponseSnapshot != responseDigest {
      throw AgentResponseError.snapshotChanged
    }
    let responseAugmentors: [any PromptAugmentor] = [
      try AgentResponsePromptAugmentor(configuration: response)
    ]
    let skillWorkspace = try await workspace.skillWorkspace(agentID: agentID)
    let library = SkillLibrary(workspace: skillWorkspace)
    let skillSnapshot = try await AgentSkillSnapshot.make(library: library)
    if let expectedSkillSnapshot, expectedSkillSnapshot != skillSnapshot.digest {
      throw ManagedAgentError.skillSnapshotChanged
    }

    if !skillSnapshot.selectedSkills.isEmpty {
      try await preflightSkillProvider(selection)
    }

    let access = try await providers.acquireRuntime(selection)
    let runtime = access.runtime
    do {
      var resolvedCapabilities = capabilities
      if !skillSnapshot.selectedSkills.isEmpty {
        guard runtime.capabilities.contains(.toolCalls) else {
          throw ManagedAgentError.selectedProviderCannotUseSkills(runtime.providerID)
        }
        resolvedCapabilities.append(
          SkillAgentIntegration(
            snapshot: skillSnapshot.executionSnapshot,
            secretLibrary: library,
            scriptRunner: skillScriptRunner,
            intentService: skillIntentService
          )
        )
      }

      let agent = try Agent(
        modelRuntime: runtime,
        storage: dataStore.storage,
        instructions: promptSnapshot.systemPrompt,
        capabilities: resolvedCapabilities,
        toolPacks: toolPacks,
        tools: tools,
        promptAugmentors: promptAugmentors,
        turnPromptAugmentors: responseAugmentors,
        approval: approval,
        observer: observer,
        configuration: configuration
      )
      return ManagedAgentAssembly(
        agent: agent,
        runtimeAccess: access,
        soulDigest: promptSnapshot.soulDigest,
        responseDigest: responseDigest,
        skillSnapshot: skillSnapshot
      )
    } catch {
      let assemblyFailure: Result<ManagedAgentAssembly, any Error> = .failure(error)
      let cleanupError: (any Error)?
      do {
        try await access.release()
        cleanupError = nil
      } catch {
        cleanupError = error
      }
      return try OperationCleanupCompletionPolicy.resolve(
        operation: assemblyFailure,
        cleanupError: cleanupError
      )
    }
  }

  private func preflightSkillProvider(_ selection: ModelProviderSelection) async throws {
    guard
      let provider = await providers.providers().first(where: { $0.id == selection.providerID }),
      provider.kind == .onDevice
    else { return }

    let catalog = try await providers.models(providerID: selection.providerID)
    if let modelID = selection.modelID {
      guard let model = catalog.first(where: { $0.id == modelID }) else {
        throw ModelGenerationFailure(.invalidRequest, "Unknown model: \(modelID)")
      }
      guard model.capabilities.contains(.toolCalls) else {
        throw ManagedAgentError.selectedProviderCannotUseSkills(selection.providerID)
      }
      return
    }

    if !catalog.isEmpty, catalog.allSatisfy({ !$0.capabilities.contains(.toolCalls) }) {
      throw ManagedAgentError.selectedProviderCannotUseSkills(selection.providerID)
    }
  }

}

struct ManagedAgentAssembly: Sendable {
  let agent: Agent
  let runtimeAccess: ModelRuntimeAccess
  let soulDigest: String
  let responseDigest: String
  let skillSnapshot: AgentSkillSnapshot
}
