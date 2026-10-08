import Foundation
import NativeAgent
@testable import NativeAgentManager
import LanguageModelCore
import LanguageModelRuntime
import NativeAgentSkills
import NativeAgentTestSupport
import Testing

@Suite(.serialized)
struct AgentManagerTests {
  @Test
  func agentDefinitionRequiresExplicitKnowledgeOwnership() throws {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let definition = try AgentDefinition(
      id: "definition",
      name: "Definition",
      provider: ModelProviderSelection(providerID: "provider.local", modelID: "model"),
      createdAt: createdAt,
      updatedAt: createdAt
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(definition)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "knowledgeOwnership")
    let missingOwnership = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(throws: DecodingError.self) {
      try decoder.decode(AgentDefinition.self, from: missingOwnership)
    }
    #expect(try decoder.decode(AgentDefinition.self, from: encoded) == definition)
  }

  @Test
  func externalKnowledgeOwnershipMakesLocalFactualMemoryImpossible() async throws {
    let root = temporaryRoot("external-knowledge")
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = AgentWorkspace(dataStore: .directory(root))
    let definition = try await workspace.create(
      id: "external",
      name: "External Knowledge",
      provider: ModelProviderSelection(providerID: "provider.local", modelID: "model"),
      soul: "Use externally owned factual knowledge.",
      user: "Prefer concise answers.",
      knowledgeOwnership: .externalKnowledgeBase
    )

    #expect(definition.knowledgeOwnership == .externalKnowledgeBase)
    let memoryURL = root.appendingPathComponent("agents/external/MEMORY.md")
    #expect(FileManager.default.fileExists(atPath: memoryURL.path) == false)

    await #expect(throws: ManagedAgentError.localMemoryDisabled) {
      _ = try await workspace.memory(agentID: "external")
    }
    await #expect(throws: ManagedAgentError.localMemoryDisabled) {
      try await workspace.setMemory(agentID: "external", "must not be written")
    }

    let prompt = try await workspace.promptSnapshot(agentID: "external")
    #expect(prompt.systemPrompt.contains("# Soul\nUse externally owned factual knowledge."))
    #expect(prompt.systemPrompt.contains("# User\nPrefer concise answers."))
    #expect(prompt.systemPrompt.contains("# Memory") == false)

    let changed = try await workspace.selectProvider(
      agentID: "external",
      provider: ModelProviderSelection(providerID: "provider.next", modelID: "model")
    )
    #expect(changed.knowledgeOwnership == .externalKnowledgeBase)
  }

  @Test
  func externalKnowledgeOwnershipRejectsInitialLocalMemory() async throws {
    let root = temporaryRoot("external-knowledge-invalid")
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = AgentWorkspace(dataStore: .directory(root))
    await #expect(throws: ManagedAgentError.localMemoryDisabled) {
      _ = try await workspace.create(
        id: "external",
        name: "External Knowledge",
        provider: ModelProviderSelection(providerID: "provider.local", modelID: "model"),
        soul: "Use externally owned factual knowledge.",
        memory: "duplicate factual owner",
        knowledgeOwnership: .externalKnowledgeBase
      )
    }
  }

  @Test
  func oneRootOwnsAgentSoulUserMemoryAndSkills() async throws {
    let root = temporaryRoot("layout")
    defer { try? FileManager.default.removeItem(at: root) }

    let client = try makeClient(
      providerID: "provider.local",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "ready")]
    )
    let registry = try ModelProviderRegistry([try connector(for: client)])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)

    let definition = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.local", modelID: "model"),
      soul: "Be exact and use only verified capabilities.",
      user: "Prefer concise answers.",
      memory: "Project alpha uses local-first state."
    )

    #expect(definition.id == "primary")
    let agentRoot = root.appendingPathComponent("agents/primary", isDirectory: true)
    #expect(
      FileManager.default.fileExists(atPath: agentRoot.appendingPathComponent("agent.json").path))
    #expect(
      FileManager.default.fileExists(atPath: agentRoot.appendingPathComponent("SOUL.md").path))
    #expect(
      FileManager.default.fileExists(atPath: agentRoot.appendingPathComponent("USER.md").path))
    #expect(
      FileManager.default.fileExists(atPath: agentRoot.appendingPathComponent("MEMORY.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: agentRoot.appendingPathComponent("skills", isDirectory: true).path))

    let run = try await manager.run(agentID: "primary", input: "hello", sessionID: "managed-layout")
    #expect(run.status == .completed)
    let request = try #require((await client.recordedRequests()).first)
    let prompt = try #require(request.messages.first(where: { $0.role == .system })?.content)
    #expect(prompt.contains("# Soul\nBe exact"))
    #expect(prompt.contains("# User\nPrefer concise answers."))
    #expect(prompt.contains("# Memory\nProject alpha uses local-first state."))
    let snapshot = try await manager.dataStore.storage.session(id: run.sessionID)
    #expect(snapshot.metadata[AgentManager.agentMetadataKey]?.stringValue == "primary")
    #expect(snapshot.metadata[AgentManager.soulSnapshotMetadataKey]?.stringValue != nil)
    #expect(snapshot.providerID == "provider.local")
    #expect(snapshot.modelID == "model")
  }

  @Test
  func providerChangeOnlyAffectsNewSessions() async throws {
    let root = temporaryRoot("provider-pin")
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try makeClient(
      providerID: "provider.first",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "first"), ModelTurn(content: "continued")]
    )
    let second = try makeClient(
      providerID: "provider.second",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "new")]
    )
    let registry = try ModelProviderRegistry([
      try connector(for: first),
      try connector(for: second),
    ])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.first", modelID: "model"),
      soul: "Use the selected provider exactly."
    )

    let initial = try await manager.run(
      agentID: "primary",
      input: "one",
      sessionID: "provider-pinned"
    )
    #expect(initial.output == "first")

    _ = try await manager.selectProvider(
      agentID: "primary",
      try ModelProviderSelection(providerID: "provider.second", modelID: "model")
    )
    let continued = try await manager.send(
      agentID: "primary",
      input: "two",
      to: initial.sessionID
    )
    #expect(continued.output == "continued")
    #expect(await first.callCount() == 2)
    #expect(await second.callCount() == 0)

    let newRun = try await manager.run(agentID: "primary", input: "new")
    #expect(newRun.output == "new")
    #expect(await second.callCount() == 1)
  }

  @Test
  func selectedSkillRevisionIsPinnedForSession() async throws {
    let root = temporaryRoot("skill-pin")
    let importRoot = temporaryRoot("skill-source")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: importRoot)
    }
    try writeSkill(
      to: importRoot,
      body: "Use this workflow and call tools only when required."
    )

    let client = try makeClient(
      providerID: "provider.skills",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "first"), ModelTurn(content: "should-not-run")]
    )
    let registry = try ModelProviderRegistry([try connector(for: client)])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.skills", modelID: "model"),
      soul: "Follow selected skills."
    )
    let library = try await manager.skillLibrary(agentID: "primary")
    let imported = try await library.importSkill(fromDirectoryURL: importRoot, selected: true)
    let installedRoot = try await library.skillDirectoryURL(for: imported)

    let first = try await manager.run(
      agentID: "primary",
      input: "start",
      sessionID: "skill-pinned"
    )
    #expect(first.status == .completed)

    try writeSkill(
      to: installedRoot,
      body: "This is a different workflow revision and must not alter an existing session."
    )

    await #expect(throws: ManagedAgentError.skillSnapshotChanged) {
      _ = try await manager.send(agentID: "primary", input: "continue", to: first.sessionID)
    }
    #expect(await client.callCount() == 1)
  }

  @Test
  func soulRevisionIsPinnedForSessionWhileMemoryCanRefresh() async throws {
    let root = temporaryRoot("soul-pin")
    defer { try? FileManager.default.removeItem(at: root) }

    let client = try makeClient(
      providerID: "provider.identity",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "first"), ModelTurn(content: "memory-refreshed")]
    )
    let registry = try ModelProviderRegistry([try connector(for: client)])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.identity", modelID: "model"),
      soul: "Keep this identity stable.",
      memory: "fact-v1"
    )

    let first = try await manager.run(
      agentID: "primary",
      input: "start",
      sessionID: "soul-pinned"
    )

    try await manager.setMemory(agentID: "primary", "fact-v2")
    let continued = try await manager.send(
      agentID: "primary",
      input: "continue",
      to: first.sessionID
    )
    #expect(continued.output == "memory-refreshed")
    #expect(await client.callCount() == 2)

    try await manager.setSoul(agentID: "primary", "This is a different identity revision.")
    await #expect(throws: ManagedAgentError.soulSnapshotChanged) {
      _ = try await manager.send(agentID: "primary", input: "continue again", to: first.sessionID)
    }
    #expect(await client.callCount() == 2)
  }

  @Test
  func selectedSkillsRequireToolCallingProvider() async throws {
    let root = temporaryRoot("skill-capability")
    let importRoot = temporaryRoot("skill-source")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: importRoot)
    }
    try writeSkill(to: importRoot, body: "Use this skill for the matching task.")

    let client = try makeClient(
      providerID: "provider.text-only",
      capabilities: [.textInput, .textOutput, .streaming],
      turns: [ModelTurn(content: "must-not-run")]
    )
    let registry = try ModelProviderRegistry([try connector(for: client)])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.text-only", modelID: "model"),
      soul: "Follow selected skills."
    )
    let library = try await manager.skillLibrary(agentID: "primary")
    _ = try await library.importSkill(fromDirectoryURL: importRoot, selected: true)

    await #expect(
      throws: ManagedAgentError.selectedProviderCannotUseSkills("provider.text-only")
    ) {
      _ = try await manager.run(agentID: "primary", input: "use the skill")
    }
    #expect(await client.callCount() == 0)
  }

  @Test
  func managedHandleOwnsSessionOperationsAndPreservesExecutionPinning() async throws {
    let root = temporaryRoot("managed-operations")
    defer { try? FileManager.default.removeItem(at: root) }

    let client = try makeClient(
      providerID: "provider.operations",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "done")]
    )
    let registry = try ModelProviderRegistry([try connector(for: client)])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.operations", modelID: "model"),
      soul: "Keep this identity stable."
    )
    _ = try await manager.createAgent(
      id: "secondary",
      name: "Secondary",
      provider: try ModelProviderSelection(providerID: "provider.operations", modelID: "model"),
      soul: "A different identity."
    )

    let primary = try await manager.handle(agentID: "primary")
    let run = try await primary.run("start", sessionID: "managed-operations-session")
    #expect(run.status == .completed)
    #expect(try await primary.session(id: run.sessionID).sessionID == run.sessionID)
    #expect(try await primary.pendingApproval(sessionID: run.sessionID) == nil)
    #expect(try await primary.inspectRecovery(sessionID: run.sessionID).requiresHostReconciliation == false)
    #expect(try await primary.availableTools().isEmpty)

    let secondary = try await manager.handle(agentID: "secondary")
    await #expect(throws: ManagedAgentError.sessionOwnedByDifferentAgent) {
      _ = try await secondary.pendingApproval(sessionID: run.sessionID)
    }

    try await primary.setSoul("This is a new identity revision.")
    #expect(try await primary.session(id: run.sessionID).sessionID == run.sessionID)
    #expect(try await primary.pendingApproval(sessionID: run.sessionID) == nil)
    await #expect(throws: ManagedAgentError.soulSnapshotChanged) {
      _ = try await primary.send("must remain blocked", to: run.sessionID)
    }
  }

  @Test
  func managedForkPreservesOwnershipAndExecutionPins() async throws {
    let root = temporaryRoot("managed-fork")
    defer { try? FileManager.default.removeItem(at: root) }

    let client = try makeClient(
      providerID: "provider.fork",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "done")]
    )
    let registry = try ModelProviderRegistry([try connector(for: client)])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: "provider.fork", modelID: "model"),
      soul: "Stable fork identity."
    )

    let managed = try await manager.handle(agentID: "primary")
    let source = try await managed.run("start", sessionID: "managed-fork-source")
    let sourceSnapshot = try await managed.session(id: source.sessionID)
    let receipt = try await managed.fork(
      sessionID: source.sessionID,
      throughMessageIndex: sourceSnapshot.messages.count,
      newSessionID: "managed-fork-target",
      identity: AgentCommandIdentity(
        operationID: "fork-1",
        expectedRevision: sourceSnapshot.revision
      )
    )

    #expect(receipt.sessionID == "managed-fork-target")
    let forked = try await managed.session(id: receipt.sessionID)
    #expect(forked.metadata[AgentManager.agentMetadataKey]?.stringValue == "primary")
    #expect(forked.metadata[AgentManager.soulSnapshotMetadataKey] ==
      sourceSnapshot.metadata[AgentManager.soulSnapshotMetadataKey])
    #expect(forked.metadata[AgentManager.skillSnapshotMetadataKey] ==
      sourceSnapshot.metadata[AgentManager.skillSnapshotMetadataKey])
    #expect(forked.providerID == sourceSnapshot.providerID)
    #expect(forked.modelID == sourceSnapshot.modelID)
    #expect(try await managed.pendingApproval(sessionID: receipt.sessionID) == nil)
  }


  @Test
  func providerIndependentRecoveryRemainsAvailableWhenProviderIsDown() async throws {
    let root = temporaryRoot("provider-down-recovery")
    defer { try? FileManager.default.removeItem(at: root) }

    let availability = ProviderAvailabilityBox()
    let client = try makeClient(
      providerID: "provider.recovery",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "done")]
    )
    let descriptor = try #require(client.modelDescriptor)
    let provider = try ModelProviderDescriptor(
      id: descriptor.providerID,
      displayName: descriptor.providerID,
      kind: .onDevice
    )
    let connector = ClosureModelProviderConnector(
      descriptor: provider,
      availability: { await availability.value() },
      models: { [descriptor] },
      acquireRuntime: { _ in .owned(try makeTestModelRuntime(client)) }
    )
    let registry = try ModelProviderRegistry([connector])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: descriptor.providerID, modelID: descriptor.id),
      soul: "Stable recovery identity."
    )

    let run = try await manager.run(
      agentID: "primary",
      input: "start",
      sessionID: "provider-down-recovery"
    )
    await availability.set(.unavailable("provider-down"))

    #expect(try await manager.pendingApproval(agentID: "primary", sessionID: run.sessionID) == nil)
    #expect(try await manager.pendingModelInvocation(agentID: "primary", sessionID: run.sessionID) == nil)
    #expect(try await manager.inspectRecovery(agentID: "primary", sessionID: run.sessionID).requiresHostReconciliation == false)
    #expect(try await manager.toolEffect(agentID: "primary", sessionID: run.sessionID, callID: "missing") == nil)
    #expect(try await manager.retryPendingExecutionClaimRelease(agentID: "primary", sessionID: run.sessionID) == false)
  }

  @Test
  func providerIndependentRecoveryRetainsPinnedSkillToolContracts() async throws {
    let root = temporaryRoot("provider-down-skill-recovery")
    let importRoot = temporaryRoot("provider-down-skill-recovery-source")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: importRoot)
    }
    try writeSkill(
      to: importRoot,
      body: "Use run_intent only after host approval."
    )

    let availability = ProviderAvailabilityBox()
    let client = try makeClient(
      providerID: "provider.skill-recovery",
      capabilities: .allKnown,
      turns: [
        ModelTurn(
          content: "",
          toolCalls: [
            ToolCall(
              id: "run-intent-approval",
              name: "run_intent",
              arguments: .object([
                "intent": .string("verify"),
                "parameters": .string("{}")
              ])
            )
          ]
        )
      ]
    )
    let descriptor = try #require(client.modelDescriptor)
    let provider = try ModelProviderDescriptor(
      id: descriptor.providerID,
      displayName: descriptor.providerID,
      kind: .onDevice
    )
    let connector = ClosureModelProviderConnector(
      descriptor: provider,
      availability: { await availability.value() },
      models: { [descriptor] },
      acquireRuntime: { _ in .owned(try makeTestModelRuntime(client)) }
    )
    let manager = AgentManager(
      dataStore: .directory(root),
      providers: try ModelProviderRegistry([connector]),
      approval: .handler { _ in
        try? await Task.sleep(for: .seconds(30))
        return .denied(reason: "test cleanup")
      }
    )
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(
        providerID: descriptor.providerID,
        modelID: descriptor.id
      ),
      soul: "Stable Skill recovery identity."
    )
    let library = try await manager.skillLibrary(agentID: "primary")
    _ = try await library.importSkill(fromDirectoryURL: importRoot, selected: true)

    let runTask = Task {
      try await manager.run(
        agentID: "primary",
        input: "exercise approval recovery",
        sessionID: "provider-down-skill-recovery"
      )
    }

    var waitingSnapshot: SessionSnapshot?
    for _ in 0..<200 {
      if let snapshot = try? await manager.dataStore.storage.session(
        id: "provider-down-skill-recovery"
      ), snapshot.status == .waiting, snapshot.waitState?.kind == .approval {
        waitingSnapshot = snapshot
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    _ = try #require(waitingSnapshot)
    await availability.set(.unavailable("provider-down"))

    let approval = try #require(
      try await manager.pendingApproval(
        agentID: "primary",
        sessionID: "provider-down-skill-recovery"
      )
    )
    #expect(approval.definition.name == "run_intent")
    #expect(approval.definition.effect == .mutation)
    #expect(approval.definition.approvalPolicy == .requireApproval)

    let inspection = try await manager.inspectRecovery(
      agentID: "primary",
      sessionID: "provider-down-skill-recovery"
    )
    let item = try #require(
      inspection.pendingToolEffects.first { $0.call.id == "run-intent-approval" }
    )
    #expect(item.definition?.name == "run_intent")
    #expect(item.disposition != .invalid)

    runTask.cancel()
    do {
      _ = try await runTask.value
      Issue.record("Cancelled approval wait unexpectedly completed.")
    } catch is CancellationError {
      // Expected: cancellation leaves the durable approval wait inspectable.
    } catch {
      Issue.record("Unexpected cancelled approval error: \(error)")
    }
  }

  @Test
  func modelFailureReconciliationRemainsAvailableWhenProviderIsDown() async throws {
    let root = temporaryRoot("provider-down-model-reconciliation")
    defer { try? FileManager.default.removeItem(at: root) }

    let availability = ProviderAvailabilityBox()
    let descriptor = ModelDescriptor(
      id: "model",
      providerID: "provider.model-recovery",
      displayName: "Recovery Model",
      capabilities: .allKnown,
      contextWindowTokens: 100_000
    )
    try descriptor.validateGenerationContract()
    let client = FailingModelClient(descriptor: descriptor)
    let provider = try ModelProviderDescriptor(
      id: descriptor.providerID,
      displayName: descriptor.providerID,
      kind: .onDevice
    )
    let connector = ClosureModelProviderConnector(
      descriptor: provider,
      availability: { await availability.value() },
      models: { [descriptor] },
      acquireRuntime: { _ in .owned(try makeTestModelRuntime(client)) }
    )
    let manager = AgentManager(
      dataStore: .directory(root),
      providers: try ModelProviderRegistry([connector])
    )
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: descriptor.providerID, modelID: descriptor.id),
      soul: "Stable model recovery identity."
    )

    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await manager.run(
        agentID: "primary",
        input: "start",
        sessionID: "provider-down-model-reconciliation"
      )
    }
    let pending = try #require(
      try await manager.pendingModelInvocation(
        agentID: "primary",
        sessionID: "provider-down-model-reconciliation"
      )
    )
    await availability.set(.unavailable("provider-down"))

    let resolved = try await manager.resolveModelInvocation(
      agentID: "primary",
      sessionID: "provider-down-model-reconciliation",
      invocationID: pending.id,
      resolution: .failed("verified provider failure")
    )
    #expect(resolved.status == .failed)
    #expect(
      try await manager.pendingModelInvocation(
        agentID: "primary",
        sessionID: "provider-down-model-reconciliation"
      ) == nil
    )
  }

  @Test
  func failedClaimReleaseIsRetryableAcrossManagerAgentAssembliesWithoutProvider() async throws {
    let root = temporaryRoot("claim-release")
    defer { try? FileManager.default.removeItem(at: root) }

    let claimStore = FailFirstReleaseClaimStore()
    let storage = AgentStorage.directory(root, executionClaimStore: claimStore)
    let availability = ProviderAvailabilityBox()
    let client = try makeClient(
      providerID: "provider.claim",
      capabilities: .allKnown,
      turns: [ModelTurn(content: "done")]
    )
    let descriptor = try #require(client.modelDescriptor)
    let provider = try ModelProviderDescriptor(
      id: descriptor.providerID,
      displayName: descriptor.providerID,
      kind: .onDevice
    )
    let connector = ClosureModelProviderConnector(
      descriptor: provider,
      availability: { await availability.value() },
      models: { [descriptor] },
      acquireRuntime: { _ in .owned(try makeTestModelRuntime(client)) }
    )
    let registry = try ModelProviderRegistry([connector])
    let manager = AgentManager(
      dataStore: AgentDataStore(rootURL: root, storage: storage),
      providers: registry
    )
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: descriptor.providerID, modelID: descriptor.id),
      soul: "Stable claim identity."
    )

    await #expect(throws: AgentError.self) {
      _ = try await manager.run(
        agentID: "primary",
        input: "start",
        sessionID: "claim-release-session"
      )
    }
    await availability.set(.unavailable("provider-down"))

    #expect(try await manager.retryPendingExecutionClaimRelease(
      agentID: "primary",
      sessionID: "claim-release-session"
    ))
    #expect(try await manager.retryPendingExecutionClaimRelease(
      agentID: "primary",
      sessionID: "claim-release-session"
    ) == false)
  }

  @Test
  func skillExecutionUsesTheSameFrozenBytesThatProducedThePinnedDigest() async throws {
    let root = temporaryRoot("skill-toctou")
    let importRoot = temporaryRoot("skill-toctou-source")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: importRoot)
    }
    let oldBody = "OLD-SNAPSHOT-WORKFLOW"
    let newBody = "NEW-LIVE-WORKFLOW"
    let oldDescription = "OLD-SNAPSHOT-DESCRIPTION"
    let newDescription = "NEW-LIVE-DESCRIPTION"
    try writeSkill(to: importRoot, body: oldBody, description: oldDescription)

    let mutation = SkillMutationBox()
    let client = try makeClient(
      providerID: "provider.skill-snapshot",
      capabilities: .allKnown,
      turns: [
        ModelTurn(
          content: "",
          toolCalls: [
            ToolCall(
              id: "load-skill-1",
              name: "load_skill",
              arguments: .object(["skill_name": .string("verify-project")])
            )
          ]
        ),
        ModelTurn(content: "done"),
      ]
    )
    let descriptor = try #require(client.modelDescriptor)
    let provider = try ModelProviderDescriptor(
      id: descriptor.providerID,
      displayName: descriptor.providerID,
      kind: .onDevice
    )
    let connector = ClosureModelProviderConnector(
      descriptor: provider,
      availability: { .available },
      models: { [descriptor] },
      acquireRuntime: { _ in try await mutation.applyIfConfigured()
        return .owned(try makeTestModelRuntime(client)) }
    )
    let registry = try ModelProviderRegistry([connector])
    let manager = AgentManager(dataStore: .directory(root), providers: registry)
    _ = try await manager.createAgent(
      id: "primary",
      name: "Primary",
      provider: try ModelProviderSelection(providerID: descriptor.providerID, modelID: descriptor.id),
      soul: "Follow the selected Skill snapshot."
    )
    let library = try await manager.skillLibrary(agentID: "primary")
    let imported = try await library.importSkill(fromDirectoryURL: importRoot, selected: true)
    let installedRoot = try await library.skillDirectoryURL(for: imported)
    await mutation.configure(
      skillRoot: installedRoot,
      body: newBody,
      description: newDescription
    )

    let run = try await manager.run(
      agentID: "primary",
      input: "use the selected skill",
      sessionID: "skill-toctou-session"
    )
    #expect(run.status == .completed)

    let requests = await client.recordedRequests()
    #expect(requests.count == 2)
    let firstSystem = requests[0].messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(firstSystem.contains(oldDescription))
    #expect(firstSystem.contains(newDescription) == false)
    let toolResultText = requests[1].messages
      .filter { $0.role == .tool }
      .map(\.content)
      .joined(separator: "\n")
    #expect(toolResultText.contains(oldBody))
    #expect(toolResultText.contains(newBody) == false)

    await #expect(throws: ManagedAgentError.skillSnapshotChanged) {
      _ = try await manager.send(agentID: "primary", input: "continue", to: run.sessionID)
    }
  }

  private func makeClient(
    providerID: String,
    capabilities: ModelCapabilities,
    turns: [ModelTurn]
  ) throws -> ScriptedModelClient {
    let descriptor = ModelDescriptor(
      id: "model",
      providerID: providerID,
      displayName: "Test Model",
      capabilities: capabilities,
      contextWindowTokens: 100_000
    )
    try descriptor.validateGenerationContract()
    return ScriptedModelClient(
      providerID: providerID,
      modelDescriptor: descriptor,
      scriptedTurns: turns
    )
  }

  private func connector(
    for client: ScriptedModelClient
  ) throws -> ClosureModelProviderConnector {
    let descriptor = try #require(client.modelDescriptor)
    let provider = try ModelProviderDescriptor(
      id: descriptor.providerID,
      displayName: descriptor.providerID,
      kind: .onDevice
    )
    return ClosureModelProviderConnector(
      descriptor: provider,
      availability: { .available },
      models: { [descriptor] },
      acquireRuntime: { _ in .owned(try makeTestModelRuntime(client)) }
    )
  }

  private func temporaryRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeAgent-AgentManager-\(label)-\(UUID().uuidString)", isDirectory: true)
  }

  private func writeSkill(
    to root: URL,
    body: String,
    description: String = "Verify a project with deterministic checks before claiming completion."
  ) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let markdown = """
      ---
      name: verify-project
      description: \(description)
      ---

      # Verify Project

      \(body)
      """
    try Data(markdown.utf8).write(
      to: root.appendingPathComponent("SKILL.md", isDirectory: false),
      options: [.atomic]
    )
  }
}

@Test
func independentAgentWorkspacesSerializeSharedRootMutation() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("NativeAgent-AgentManager-writer-fence-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let dataStore = AgentDataStore.directory(root)
  let first = AgentWorkspace(dataStore: dataStore)
  let second = AgentWorkspace(dataStore: dataStore)
  let provider = try ModelProviderSelection(providerID: "provider.local", modelID: "model")

  let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
    group.addTask {
      do {
        _ = try await first.create(
          id: "primary",
          name: "Primary",
          provider: provider,
          soul: "Stable identity."
        )
        return true
      } catch ManagedAgentError.alreadyExists("primary") {
        return false
      } catch {
        return false
      }
    }
    group.addTask {
      do {
        _ = try await second.create(
          id: "primary",
          name: "Primary",
          provider: provider,
          soul: "Stable identity."
        )
        return true
      } catch ManagedAgentError.alreadyExists("primary") {
        return false
      } catch {
        return false
      }
    }

    var values: [Bool] = []
    for await value in group { values.append(value) }
    return values
  }

  #expect(outcomes.filter { $0 }.count == 1)
  #expect(try await first.definitions().map(\.id) == ["primary"])
  let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
  let leftovers = try FileManager.default.contentsOfDirectory(atPath: agentsRoot.path)
    .filter { $0.hasPrefix(".creating-") }
  #expect(leftovers.isEmpty)
}

private actor FailingModelClient: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

  nonisolated let providerID: String
  nonisolated let modelDescriptor: ModelDescriptor?

  init(descriptor: ModelDescriptor) {
    self.providerID = descriptor.providerID
    self.modelDescriptor = descriptor
  }

  func generate(request: ModelRequest) throws -> ModelTurn {
    throw ModelGenerationFailure(.sourceUnavailable, "injected uncertain provider failure")
  }
}

private actor ProviderAvailabilityBox {
  private var availability: ModelProviderAvailability = .available

  func value() -> ModelProviderAvailability { availability }
  func set(_ value: ModelProviderAvailability) { availability = value }
}

private actor FailFirstReleaseClaimStore: SessionExecutionClaimStore {
  private var active: [String: SessionExecutionClaim] = [:]
  private var shouldFailRelease = true

  func acquireExecutionClaim(sessionID: String) throws -> SessionExecutionClaim {
    if active[sessionID] != nil { throw AgentError.sessionBusy(sessionID) }
    let claim = SessionExecutionClaim(sessionID: sessionID, claimID: UUID().uuidString)
    active[sessionID] = claim
    return claim
  }

  func releaseExecutionClaim(_ claim: SessionExecutionClaim) throws {
    guard active[claim.sessionID] == claim else {
      throw AgentError.invariantViolation("Execution claim identity mismatch.")
    }
    if shouldFailRelease {
      shouldFailRelease = false
      throw AgentError.persistenceFailure("injected release failure")
    }
    active.removeValue(forKey: claim.sessionID)
  }
}

private actor SkillMutationBox {
  private var skillRoot: URL?
  private var body = ""
  private var description = ""

  func configure(skillRoot: URL, body: String, description: String) {
    self.skillRoot = skillRoot
    self.body = body
    self.description = description
  }

  func applyIfConfigured() throws {
    guard let skillRoot else { return }
    let markdown = """
      ---
      name: verify-project
      description: \(description)
      ---

      # Verify Project

      \(body)
      """
    try Data(markdown.utf8).write(
      to: skillRoot.appendingPathComponent("SKILL.md", isDirectory: false),
      options: [.atomic]
    )
    self.skillRoot = nil
  }
}
