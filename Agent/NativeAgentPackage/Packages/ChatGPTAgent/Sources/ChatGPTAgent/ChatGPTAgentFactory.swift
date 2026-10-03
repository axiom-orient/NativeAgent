import ChatGPTAccount
import ChatGPTTextProvider
import LanguageModelRuntime
import NativeAgent
import NativeAgentDomain
import NativeAgentManager
import NativeAgentSkills

/// Text-only host composition. Optional image capabilities/skills are explicitly supplied by the host.
///
/// It creates no second execution authority: `AgentManager` still owns Agent identity/provider
/// assembly, `ModelRuntime` owns model invocation lifetime, `ChatGPTAccountSession` owns auth,
/// and the Agent kernel owns approval/effects/artifacts/recovery.
public enum ChatGPTAgentFactory {
  public static func make(
    account: ChatGPTAccountSession,
    dataStore: AgentDataStore,
    id: String,
    name: String,
    soul: String,
    user: String = "",
    memory: String = "",
    modelID: String? = nil,
    additionalCapabilities: [any AgentCapability] = [],
    toolPacks: [any ToolPack] = [],
    tools: [any ToolExecutor] = [],
    promptAugmentors: [any PromptAugmentor] = [],
    skillScriptRunner: (any SkillScriptRunner)? = nil,
    skillIntentService: (any SkillIntentService)? = nil,
    approval: AgentApproval = .denyAll,
    observer: (any RuntimeObserver)? = nil,
    configuration: AgentConfiguration = AgentConfiguration(),
    runtimePolicy: ModelRuntimePolicy = .default
  ) async throws -> ManagedAgent {
    try ChatGPTRuntime.admitRuntimeCreation(for: try await account.status())
    let providers = try ModelProviderRegistry([
      try ChatGPTProviderConnector(account: account, policy: runtimePolicy)
    ])
    let manager = AgentManager(
      dataStore: dataStore,
      providers: providers,
      capabilities: additionalCapabilities,
      toolPacks: toolPacks,
      tools: tools,
      promptAugmentors: promptAugmentors,
      skillScriptRunner: skillScriptRunner,
      skillIntentService: skillIntentService,
      approval: approval,
      observer: observer,
      configuration: configuration
    )
    let selection = try ModelProviderSelection(
      providerID: ChatGPTRuntime.providerID,
      modelID: modelID
    )
    _ = try await manager.createAgent(
      id: id,
      name: name,
      provider: selection,
      soul: soul,
      user: user,
      memory: memory
    )
    return try await manager.handle(agentID: id)
  }
}
