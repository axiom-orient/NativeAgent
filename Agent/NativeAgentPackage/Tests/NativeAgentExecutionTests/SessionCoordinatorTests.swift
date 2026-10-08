import NativeAgentTestSupport
import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
@testable import NativeAgentTools

private func makeRuntimeTempRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
}

private actor ModelInvocationCancellationGate {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

@Test
func invalidToolCallLeavesToolErrorMessageWithoutExecuting() async throws {
  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(
      content: "I'll try a write.",
      toolCalls: [
        ToolCall(
          id: "call-1",
          name: "files.writeText",
          arguments: ["path": "invalid.txt"]
        )
      ]
    ),
    ModelTurn(content: "done"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [
      FilesToolPack(rootURL: tempRoot.appendingPathComponent("user-files", isDirectory: true))
    ]
  )

  let snapshot = try await coordinator.startSession(userPrompt: "write invalid")
  let lastToolMessage = try #require(snapshot.messages.last { $0.role == .tool })

  #expect(lastToolMessage.metadata["isError"]?.boolValue == true)
  #expect(lastToolMessage.metadata["errorCode"]?.stringValue == ToolFailureCode.invalidInput.rawValue)
  #expect(
    FileManager.default.fileExists(
      atPath: tempRoot.appendingPathComponent("user-files/invalid.txt").path) == false)
}

@Test
func assistantToolCallsArePersistedInTranscript() async throws {
  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(
      content: "",
      toolCalls: [
        ToolCall(
          id: "call-1",
          name: "files.list",
          arguments: ["path": ""],
          metadata: ["provider.gemini.thought_signature": .string("signed")])
      ]
    ),
    ModelTurn(content: "done"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [
      FilesToolPack(rootURL: tempRoot.appendingPathComponent("user-files", isDirectory: true))
    ]
  )

  let snapshot = try await coordinator.startSession(userPrompt: "list files")
  let firstAssistant = try #require(
    snapshot.messages.first { $0.role == .assistant && !$0.toolCalls.isEmpty })
  #expect(firstAssistant.toolCalls.map(\.name) == ["files.list"])
  #expect(
    firstAssistant.toolCalls.first?.metadata["provider.gemini.thought_signature"]
      == .string("signed"))
}

@Test
func deniedApprovalPreventsExecutionAndPersistsToolMessage() async throws {
  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(
      content: "I'll try a write.",
      toolCalls: [
        ToolCall(
          id: "call-1",
          name: "files.writeText",
          arguments: ["path": "blocked.txt", "content": "secret"]
        )
      ]
    ),
    ModelTurn(content: "stopped"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: DenyAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [
      FilesToolPack(rootURL: tempRoot.appendingPathComponent("user-files", isDirectory: true))
    ]
  )

  let snapshot = try await coordinator.startSession(userPrompt: "write blocked.txt")
  let deniedMessage = try #require(snapshot.messages.last { $0.role == .tool })

  #expect(
    FileManager.default.fileExists(
      atPath: tempRoot.appendingPathComponent("user-files/blocked.txt").path) == false)
  #expect(deniedMessage.metadata["isError"]?.boolValue == true)
  #expect(deniedMessage.metadata["errorCode"]?.stringValue == ToolFailureCode.permissionDenied.rawValue)
}

@Test
func longSessionCompactionPreservesTranscriptAndPersistsContextCheckpoint() async throws {
  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let longMessage = String(repeating: "abcdefghij", count: 300)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(content: "assistant-0 \(longMessage)"),
    ModelTurn(content: "assistant-1 \(longMessage)"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      maxIterations: 4,
      contextBudgetPolicy: ContextBudgetPolicy(
        windowTokens: 600,
        triggerRatio: 0.50,
        targetRatio: 0.30,
        keepRecentMessages: 1,
        maxSummaryCharacters: 300
      )
    )
  )

  var snapshot = try await coordinator.startSession(
    userPrompt: "first \(longMessage)", systemPrompt: "system prompt \(longMessage)")
  snapshot = try await coordinator.continueSession(
    sessionID: snapshot.sessionID, userPrompt: "second \(longMessage)")

  #expect(snapshot.messages.count == 5)
  #expect(
    snapshot.messages.contains(where: {
      $0.metadata["syntheticSummary"]?.boolValue == true
    }) == false)
  #expect(
    snapshot.contextCheckpoint?.summaryMessage.metadata["syntheticSummary"]?.boolValue == true)

  let requests = await provider.recordedRequests()
  #expect(requests.count == 2)
  #expect(requests[1].messages.count < snapshot.messages.count)
  #expect(
    requests[1].messages.contains(where: {
      $0.metadata["syntheticSummary"]?.boolValue == true
    }))

  let reloaded = try await coordinator.loadSession(sessionID: snapshot.sessionID)
  #expect(reloaded.messages == snapshot.messages)
  #expect(reloaded.contextCheckpoint == snapshot.contextCheckpoint)
}

@Test
func exactModelMessageLimitForcesCompactionBelowApproximateTokenTrigger() throws {
  let messages = (0..<33).map { index in
    AgentMessage(
      role: index.isMultiple(of: 2) ? .user : .assistant,
      content: "m\(index)"
    )
  }
  let snapshot = SessionSnapshot(sessionID: "hard-context-limit", messages: messages)
  let policy = ContextBudgetPolicy(
    windowTokens: 100_000,
    triggerRatio: 0.95,
    targetRatio: 0.80,
    keepRecentMessages: 24,
    maxSummaryCharacters: 512
  )
  let compactor = ContextWindowCompactor()
  let builder = AgentLoopRequestBuilder()

  #expect(
    try compactor.compactIfNeeded(
      snapshot: snapshot,
      tools: [],
      policy: policy
    ) == nil
  )
  #expect(
    try builder.requiresHardCompaction(
      snapshot: snapshot,
      messages: snapshot.messages,
      tools: []
    )
  )

  let forced = try #require(
    try compactor.compactForRequestContract(
      snapshot: snapshot,
      tools: [],
      policy: policy,
      now: Date(timeIntervalSince1970: 1_700_000_000),
      maximumProjectedMessages: ModelGenerationLimits.default.maxMessages
    )
  )
  let request = builder.makeRequest(
    snapshot: snapshot,
    messages: forced.messages,
    tools: []
  )
  let footprint = try request.inputFootprint()
  #expect(footprint.messageCount <= request.limits.maxMessages)
  #expect(forced.messages.count < snapshot.messages.count)
  #expect(forced.messages.last?.id == snapshot.messages.last?.id)
}

@Test
func compactorRejectsCheckpointOutsideDurableTranscript() throws {
  let snapshot = SessionSnapshot(
    sessionID: "invalid-context-checkpoint",
    messages: [AgentMessage(role: .user, content: "hello")],
    contextCheckpoint: SessionContextCheckpoint(
      preservedSystemMessageCount: 0,
      coveredMessageCount: 2,
      summaryMessage: AgentMessage(role: .assistant, content: "summary")
    )
  )

  #expect(throws: AgentError.self) {
    _ = try ContextWindowCompactor().compactIfNeeded(
      snapshot: snapshot,
      tools: [],
      policy: ContextBudgetPolicy(windowTokens: 1_000)
    )
  }
}

@Test
func hardCompactionDoesNotHideAnOversizedNewestMessage() throws {
  let oversized = String(
    repeating: "x",
    count: ModelGenerationLimits.default.maxMessageBytes + 1
  )
  let snapshot = SessionSnapshot(
    sessionID: "hard-context-unsolved",
    messages: [
      AgentMessage(role: .user, content: "old"),
      AgentMessage(role: .assistant, content: "older"),
      AgentMessage(role: .user, content: oversized),
    ]
  )
  let builder = AgentLoopRequestBuilder()

  #expect(throws: ModelGenerationFailure.self) {
    _ = try builder.requiresHardCompaction(
      snapshot: snapshot,
      messages: snapshot.messages,
      tools: []
    )
  }
}

@Test
func duplicateToolNamesAreRejected() async throws {
  struct DuplicateToolPack: ToolPack {
    let packID = "dup"
    func executors() -> [any ToolExecutor] {
      [FakeExecutor(name: "dup.echo"), FakeExecutor(name: "dup.echo")]
    }
  }

  struct FakeExecutor: ToolExecutor {
    let definition: ToolDefinition

    init(name: String) {
      self.definition = ToolDefinition(
        name: name,
        description: "dup",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic
      )
    }

    func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
      .text(callID: call.id, toolName: call.name, content: "ok")
    }
  }

  let store = ApplicationSupportSessionStore(
    rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  let provider = ScriptedModelClient()

  var threw = false
  do {
    _ = try SessionCoordinator(
      modelClient: provider,
      approvalRouter: AllowAllApprovalRouter(),
      runtimeStore: store,
      toolPacks: [DuplicateToolPack()]
    )
  } catch {
    threw = true
  }

  #expect(threw)
}

@Test
func toolsAreRejectedAtConstructionWhenModelDoesNotAdvertiseToolCalls() throws {
  let root = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: root)
  let providerID = "provider.test.text-only"
  let provider = ScriptedModelClient(
    providerID: providerID,
    modelDescriptor: ModelDescriptor(
      id: "text-only",
      providerID: providerID,
      capabilities: [.textInput, .textOutput, .streaming]
    )
  )

  #expect(throws: AgentError.self) {
    _ = try SessionCoordinator(
      modelClient: provider,
      approvalRouter: AllowAllApprovalRouter(),
      runtimeStore: store,
      toolPacks: [
        FilesToolPack(rootURL: root.appendingPathComponent("files", isDirectory: true))
      ]
    )
  }
}

@Test
func continuingCompletedSessionResumesTranscript() async throws {
  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(content: "first"),
    ModelTurn(content: "second"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: []
  )

  let first = try await coordinator.startSession(userPrompt: "one")
  #expect(first.status == .completed)

  let second = try await coordinator.continueSession(sessionID: first.sessionID, userPrompt: "two")
  #expect(second.status == .completed)
  #expect(second.messages.map(\.content).contains("one"))
  #expect(second.messages.map(\.content).contains("two"))
}

@Test
func resumingCompletedSessionDoesNotReinvokeProvider() async throws {
  let tempRoot = makeRuntimeTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(content: "first"),
    ModelTurn(content: "must not run")
  ])
  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: []
  )

  let completed = try await coordinator.startSession(userPrompt: "one")
  #expect(completed.status == .completed)
  #expect(await provider.callCount() == 1)

  await #expect(throws: AgentError.invariantViolation(
    "Session \(completed.sessionID) cannot advance from completed; explicit continuation or retry is required."
  )) {
    _ = try await coordinator.run(sessionID: completed.sessionID)
  }

  #expect(await provider.callCount() == 1)
  #expect(try await coordinator.loadSession(sessionID: completed.sessionID) == completed)
}

@Test
func resumingFailedSessionRequiresExplicitRetryIdentity() async throws {
  let tempRoot = makeRuntimeTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "must not run")])
  let timestamp = Date(timeIntervalSince1970: 1_726_001_700)
  let failed = SessionSnapshot(
    sessionID: "failed-resume-session",
    status: .failed,
    createdAt: timestamp,
    updatedAt: timestamp,
    failure: SessionFailure(
      code: "test_failure",
      message: "initial model failure",
      occurredAt: timestamp
    )
  )
  try await store.createSession(failed, events: [], effects: [])
  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: []
  )

  await #expect(throws: AgentError.invariantViolation(
    "Session \(failed.sessionID) cannot advance from failed; explicit continuation or retry is required."
  )) {
    _ = try await coordinator.run(sessionID: failed.sessionID)
  }

  #expect(try await coordinator.loadSession(sessionID: failed.sessionID) == failed)
  #expect(await provider.callCount() == 0)
}

@Test
func cancellationAfterModelInvocationStartsRequiresReconciliation() async throws {
  struct CancelOnGenerateProvider: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

    let providerID = "provider.cancel"
    let gate: ModelInvocationCancellationGate

    func generate(request: ModelRequest) async throws -> ModelTurn {
      await gate.markStarted()
      try await Task.sleep(for: .seconds(30))
      return ModelTurn(content: "late")
    }
  }

  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let gate = ModelInvocationCancellationGate()
  let coordinator = try SessionCoordinator(
    modelClient: CancelOnGenerateProvider(gate: gate),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    idGenerator: { "session-cancelled" }
  )

  let operation = Task {
    try await coordinator.startSession(userPrompt: "cancel me")
  }
  await gate.waitUntilStarted()
  operation.cancel()
  await #expect(throws: CancellationError.self) {
    _ = try await operation.value
  }

  let snapshot = try await coordinator.loadSession(sessionID: "session-cancelled")
  #expect(snapshot.status == .waiting)
  #expect(snapshot.waitState?.kind == .modelInvocation)
  #expect(snapshot.failure == nil)
  #expect(try await coordinator.pendingModelInvocation(sessionID: snapshot.sessionID) != nil)
}

@Test
func blankAugmentedSystemPromptIsNotPersisted() async throws {
  struct BlankPromptAugmentor: PromptAugmentor {
    func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
      "   \n   "
    }
  }

  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(content: "ok")
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    promptAugmentor: BlankPromptAugmentor()
  )

  let snapshot = try await coordinator.startSession(userPrompt: "hello", systemPrompt: "base")
  #expect(snapshot.messages.first?.role == .user)
  #expect(snapshot.messages.contains(where: { $0.role == .system }) == false)
}

@Test
func compactionPreservesSystemAuthorityAndUsesExtractiveProjection() throws {
  let longText = String(repeating: "abcdefghij", count: 80)
  let compactor = ContextWindowCompactor()
  let messages = [
    AgentMessage(role: .system, content: "leading-system \(longText)"),
    AgentMessage(role: .user, content: "old-user \(longText)"),
    AgentMessage(role: .assistant, content: "old-assistant \(longText)"),
    AgentMessage(role: .system, content: "mid-system \(longText)"),
    AgentMessage(role: .user, content: "recent-user \(longText)"),
  ]

  let compacted = try compactor.compactIfNeeded(
    messages: messages,
    tools: [],
    policy: ContextBudgetPolicy(
      windowTokens: 1_000,
      triggerRatio: 0.85,
      targetRatio: 0.30,
      keepRecentMessages: 2,
      maxSummaryCharacters: 2_000,
      preserveSystemMessages: true
    )
  )
  let result = try #require(compacted)

  #expect(result.messages.first?.role == .system)
  let projection = try #require(result.messages.dropFirst().first)
  #expect(projection.metadata["syntheticSummary"]?.boolValue == true)
  #expect(projection.metadata["contextProjection"]?.stringValue == "extractive.v1")
  #expect(projection.content.contains("old-user"))
  #expect(projection.content.contains("old-assistant"))
  #expect(result.checkpoint?.preservedSystemMessageCount == 1)
  #expect(result.messages.contains { $0.role == .system && $0.content == "mid-system \(longText)" })
  #expect(result.messages.last?.content == "recent-user \(longText)")
}

@Test
func compactionNeverReplacesEarlierContextWithInformationFreePlaceholder() throws {
  let longText = String(repeating: "abcdefghij", count: 120)
  let result = try #require(
    try ContextWindowCompactor().compactIfNeeded(
      messages: [
        AgentMessage(role: .user, content: "constraint-alpha \(longText)"),
        AgentMessage(role: .assistant, content: "evidence-beta \(longText)"),
        AgentMessage(role: .user, content: "recent-gamma \(longText)"),
      ],
      tools: [],
      policy: ContextBudgetPolicy(
        windowTokens: 500,
        reservedOutputTokens: 100,
        triggerRatio: 0.20,
        targetRatio: 0.10,
        keepRecentMessages: 1,
        maxSummaryCharacters: 120
      )
    )
  )

  let projection = try #require(result.messages.first)
  #expect(projection.metadata["contextProjection"]?.stringValue == "extractive.v1")
  #expect(projection.content != "Earlier context was compacted to fit the runtime budget.")
  #expect(projection.content.contains("constraint"))
  #expect(projection.content.contains("evidence"))
}

@Test
func compactionRefusesAnInformationFreeSummaryBudget() throws {
  let longText = String(repeating: "abcdefghij", count: 120)
  #expect(throws: AgentError.self) {
    _ = try ContextWindowCompactor().compactIfNeeded(
      messages: [
        AgentMessage(role: .user, content: "constraint-alpha \(longText)"),
        AgentMessage(role: .assistant, content: "evidence-beta \(longText)"),
        AgentMessage(role: .user, content: "recent-gamma \(longText)"),
      ],
      tools: [],
      policy: ContextBudgetPolicy(
        windowTokens: 500,
        reservedOutputTokens: 100,
        triggerRatio: 0.20,
        targetRatio: 0.10,
        keepRecentMessages: 1,
        maxSummaryCharacters: 1
      )
    )
  }
}

@Test
func compactionRetainsToolIdentityArgumentsAndSafeMetadata() throws {
  let longText = String(repeating: "abcdefghij", count: 120)
  let toolMessage = AgentMessage(
    role: .assistant,
    content: "",
    toolCalls: [
      ToolCall(
        id: "call-123",
        name: "files.writeText",
        arguments: .object(["path": .string("notes/context.txt")])
      )
    ],
    metadata: [
      "artifactReference": .string("artifact-123"),
      "internalSecret": .string("must-not-be-copied"),
    ]
  )
  let toolResultMessage = AgentMessage(
    role: .tool,
    content: "written",
    toolCallID: "call-123",
    toolName: "files.writeText"
  )
  let result = try #require(
    try ContextWindowCompactor().compactIfNeeded(
      messages: [
        AgentMessage(role: .user, content: "constraint-alpha \(longText)"),
        toolMessage,
        toolResultMessage,
        AgentMessage(role: .user, content: "recent-gamma"),
      ],
      tools: [],
      policy: ContextBudgetPolicy(
      windowTokens: 500,
      reservedOutputTokens: 100,
      triggerRatio: 0.70,
      targetRatio: 0.50,
      keepRecentMessages: 1,
      maxSummaryCharacters: 2_000
      )
    )
  )

  let projection = try #require(
    result.messages.first(where: {
      $0.metadata["contextProjection"]?.stringValue == "extractive.v1"
    })
  )
  #expect(projection.content.contains("call-123"))
  #expect(projection.content.contains(#"notes\/context.txt"#))
  #expect(projection.content.contains("artifact-123"))
  #expect(projection.content.contains("tool[files.writeText]#call-123"))
  #expect(projection.content.contains("must-not-be-copied") == false)
}

@Test
func uncompactableOverBudgetTranscriptIsReportedAsNoCompactionNotAsFailure() throws {
  let compactor = ContextWindowCompactor()
  // One oversized message: nothing outside the retained tail can be summarized,
  // so compaction can never make progress for this transcript.
  let messages = [
    AgentMessage(role: .user, content: String(repeating: "abcdefghij", count: 400))
  ]

  func policy(windowTokens: Int) -> ContextBudgetPolicy {
    ContextBudgetPolicy(
      windowTokens: windowTokens,
      triggerRatio: 0.50,
      targetRatio: 0.10,
      keepRecentMessages: 2,
      maxSummaryCharacters: 2_000,
      preserveSystemMessages: true
    )
  }

  // Both well inside and far past the configured window the compactor reports
  // "no compaction" rather than throwing. The token count is only an
  // approximation; AgentLoop separately applies ModelCore's exact request
  // contract before any provider effect starts.
  #expect(
    try compactor.compactIfNeeded(
      messages: messages,
      tools: [],
      policy: policy(windowTokens: 100_000)
    ) == nil)
  #expect(
    try compactor.compactIfNeeded(
      messages: messages,
      tools: [],
      policy: policy(windowTokens: 10)
    ) == nil)
}

@Test
func compactionUsesOnlyInputCapacityAfterOutputReservation() throws {
  let compactor = ContextWindowCompactor()
  let longText = String(repeating: "abcdefghij", count: 100)
  let policy = ContextBudgetPolicy(
    windowTokens: 1_000,
    reservedOutputTokens: 400,
    triggerRatio: 0.70,
    targetRatio: 0.50,
    keepRecentMessages: 8,
    maxSummaryCharacters: 1_000
  )
  let result = try #require(
    try compactor.compactIfNeeded(
      messages: [
        AgentMessage(role: .system, content: "system"),
        AgentMessage(role: .user, content: "one \(longText)"),
        AgentMessage(role: .assistant, content: "two \(longText)"),
        AgentMessage(role: .user, content: "three \(longText)"),
      ],
      tools: [],
      policy: policy
    ))

  #expect(policy.inputWindowTokens == 600)
  #expect(result.approxTokensBefore > policy.triggerTokens)
  #expect(result.approxTokensAfter <= policy.targetTokens)
}

@Test
func contextEstimatorCompactsMultibyteTextBeforeItOverrunsTheInputBudget() throws {
  let compactor = ContextWindowCompactor()
  let koreanText = String(repeating: "대화", count: 300)
  let messages = [
    AgentMessage(role: .user, content: "one \(koreanText)"),
    AgentMessage(role: .assistant, content: "two \(koreanText)"),
    AgentMessage(role: .user, content: "three \(koreanText)"),
  ]
  let policy = ContextBudgetPolicy(
    windowTokens: 1_200,
    reservedOutputTokens: 200,
    triggerRatio: 0.60,
    targetRatio: 0.45,
    keepRecentMessages: 8,
    maxSummaryCharacters: 1_000
  )
  let estimator = ApproximateTokenEstimator()
  let estimatedTokens = try estimator.estimate(messages: messages, tools: [])
  let result = try #require(
    try compactor.compactIfNeeded(
      messages: messages,
      tools: [],
      policy: policy
    ))

  #expect(estimatedTokens > policy.triggerTokens)
  #expect(result.approxTokensAfter <= policy.targetTokens)
}

@Test
func successfulToolExecutionPersistsArtifactMetadataInToolMessage() async throws {
  struct ArtifactToolPack: ToolPack {
    let packID = "artifact-pack"

    func executors() -> [any ToolExecutor] {
      [ArtifactExecutor()]
    }
  }

  struct ArtifactExecutor: ToolExecutor {
    let definition = ToolDefinition(
      name: "artifact.echo",
      description: "Returns one artifact.",
      capabilityID: .files,
      inputSchema: ToolSchema.object(properties: [:]),
      approvalPolicy: .automatic
    )

    func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
      ToolResult(
        callID: call.id,
        toolName: call.name,
        output: .object(["content": .string("done")]),
        artifacts: [
          ArtifactWriteRequest(
            preferredFilename: "note.txt",
            mimeType: "text/plain",
            data: Data("payload".utf8),
            metadata: [
              "preferredFilename": .string("note.txt"),
              "role": .string("attachment"),
            ]
          )
        ]
      )
    }
  }

  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient(scriptedTurns: [
    ModelTurn(
      content: "tool",
      toolCalls: [ToolCall(id: "call-1", name: "artifact.echo", arguments: [:])]
    ),
    ModelTurn(content: "done"),
  ])

  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [ArtifactToolPack()]
  )

  let snapshot = try await coordinator.startSession(userPrompt: "run artifact tool")
  let toolMessage = try #require(snapshot.messages.last(where: { $0.role == .tool }))
  let artifacts = try #require(toolMessage.metadata["artifacts"]?.arrayValue)

  #expect(artifacts.count == 1)
  #expect(artifacts.first?.objectValue?["mimeType"]?.stringValue == "text/plain")
  #expect(artifacts.first?.objectValue?["filename"]?.stringValue?.contains("note.txt") == true)
  #expect(
    artifacts.first?.objectValue?["metadata"]?.objectValue?["preferredFilename"]?.stringValue
      == "note.txt")
  #expect(snapshot.artifacts.count == 1)
}

@Test
func generatedSessionIdentifierCollisionDoesNotOverwriteExistingSession() async throws {
  let tempRoot = makeRuntimeTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let sessionID = "stable-session-id"

  let firstCoordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(scriptedTurns: [
      ModelTurn(content: "original")
    ]),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    idGenerator: { sessionID }
  )
  let original = try await firstCoordinator.startSession(userPrompt: "first")

  let secondCoordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(scriptedTurns: [
      ModelTurn(content: "replacement")
    ]),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    idGenerator: { sessionID }
  )

  await #expect(throws: AgentError.self) {
    _ = try await secondCoordinator.startSession(userPrompt: "second")
  }

  let reloaded = try #require(try await store.loadSnapshot(sessionID: sessionID))
  #expect(reloaded.sessionID == original.sessionID)
  #expect(reloaded.status == original.status)
  #expect(reloaded.messages.map(\.content) == original.messages.map(\.content))
  #expect(reloaded.messages.contains(where: { $0.content == "replacement" }) == false)
}


@Test
func capabilityDiscoveryReturnsOnlyRegisteredToolsAndLoadsExactContract() async throws {
  let tempRoot = makeRuntimeTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient()
  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [FilesToolPack(rootURL: tempRoot.appendingPathComponent("files", isDirectory: true))]
  )

  let found = try await coordinator.discoverTools(intent: "read text file", limit: 3)
  let registered = Set(await coordinator.availableTools().map(\.name))
  #expect(found.isEmpty == false)
  #expect(found.allSatisfy { registered.contains($0.id) })
  #expect(found.contains { $0.id == "files.readText" })
  #expect(await coordinator.toolContract(named: "files.readText")?.name == "files.readText")
  #expect(await coordinator.toolContract(named: "phantom.tool") == nil)
}

@Test
func hostIssuedToolCallUsesCanonicalExecutionPolicyWithoutModelInvocation() async throws {
  let tempRoot = makeRuntimeTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  let provider = ScriptedModelClient()
  let filesRoot = tempRoot.appendingPathComponent("host-files", isDirectory: true)
  let coordinator = try SessionCoordinator(
    modelClient: provider,
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [FilesToolPack(rootURL: filesRoot)]
  )
  let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
  let providerID = await provider.providerID
  let original = SessionSnapshot(
    sessionID: "host-tool-session",
    status: .running,
    createdAt: timestamp,
    updatedAt: timestamp,
    messages: [AgentMessage(id: "host-user", role: .user, content: "host operation", createdAt: timestamp)],
    providerID: providerID,
    modelID: nil
  )
  try await store.createSession(original, events: [], effects: [])

  let call = ToolCall(
    id: "host-call-1",
    name: "files.writeText",
    arguments: ["path": "host.txt", "content": "written by host"]
  )
  let snapshot = try await coordinator.executeToolCall(call, sessionID: original.sessionID)

  #expect(await provider.callCount() == 0)
  #expect(snapshot.status == .running)
  let assistant = try #require(snapshot.messages.first { $0.toolCalls.contains(call) })
  #expect(assistant.metadata["hostIssuedToolCall"]?.boolValue == true)
  let result = try #require(snapshot.messages.last { $0.role == .tool && $0.toolCallID == call.id })
  #expect(result.metadata["isError"]?.boolValue == false)
  let effect = try #require(
    try await coordinator.toolEffect(sessionID: original.sessionID, callID: call.id)
  )
  #expect(effect.status == .completed)
  #expect(effect.key == call.id)
  #expect(
    try String(contentsOf: filesRoot.appendingPathComponent("host.txt"), encoding: .utf8)
      == "written by host"
  )
}
