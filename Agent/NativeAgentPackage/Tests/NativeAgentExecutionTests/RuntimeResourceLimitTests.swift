import NativeAgentTestSupport
import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore

private func resourceLimitRoot() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("native-agent-resource-limit-\(UUID().uuidString)", isDirectory: true)
}

@Test
func invalidRuntimeIterationLimitFailsAtCompositionBoundary() throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }

  #expect(throws: AgentError.self) {
    try SessionCoordinator(
      modelClient: ScriptedModelClient(),
      approvalRouter: AllowAllApprovalRouter(),
      runtimeStore: ApplicationSupportSessionStore(rootURL: root),
      toolPacks: [],
      configuration: RuntimeConfiguration(maxIterations: 0)
    )
  }
}

@Test
func oversizedUserPromptIsRejectedBeforeSessionCreation() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      resourceLimits: RuntimeResourceLimits(maxMessageUTF8Bytes: 4)
    )
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.startSession(userPrompt: "12345")
  }
  #expect((try await store.listSessionSummaries(limit: 1, offset: 0).isEmpty))
}

@Test
func oversizedLoadedSnapshotIsRejectedAtAdvancementBoundary() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let sessionID = "oversized-loaded-snapshot"
  try await store.createSession(
    SessionSnapshot(
      sessionID: sessionID,
      messages: [
        AgentMessage(
          id: "oversized-message",
          role: .user,
          content: "12345"
        )
      ]
    ), events: [], effects: [])
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      resourceLimits: RuntimeResourceLimits(maxMessageUTF8Bytes: 4)
    )
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.run(sessionID: sessionID)
  }

  let persisted = try #require(try await store.loadSnapshot(sessionID: sessionID))
  #expect(persisted.revision == 0)
  #expect(persisted.messages.map(\.id) == ["oversized-message"])
}

@Test
func oversizedModelTurnPersistsStructuredFailure() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(scriptedTurns: [
      ModelTurn(content: "12345")
    ]),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      resourceLimits: RuntimeResourceLimits(maxMessageUTF8Bytes: 4)
    ),
    idGenerator: { "resource-session" }
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.startSession(userPrompt: "go")
  }

  let snapshot = try #require(try await store.loadSnapshot(sessionID: "resource-session"))
  #expect(snapshot.status == .failed)
  #expect(snapshot.failure?.code == "budget_exceeded")
  #expect(snapshot.failure?.message.contains("model turn content") == true)
  #expect(snapshot.messages.count == 1)
}

@Test
func malformedRuntimeAdmissionFailsClosed() throws {
  let validator = RuntimeResourceValidator(limits: RuntimeResourceLimits())
  for admission in [
    SessionRuntimeAdmission(
      schemaVersion: SessionSnapshot.currentSchemaVersion,
      revision: 0,
      messageCount: -1,
      hydrationPayloadBytes: 0,
      artifactCount: 0
    ),
    SessionRuntimeAdmission(
      schemaVersion: SessionSnapshot.currentSchemaVersion,
      revision: 0,
      messageCount: 0,
      hydrationPayloadBytes: -1,
      artifactCount: 0
    ),
    SessionRuntimeAdmission(
      schemaVersion: SessionSnapshot.currentSchemaVersion,
      revision: 0,
      messageCount: 0,
      hydrationPayloadBytes: 0,
      artifactCount: -1
    ),
  ] {
    #expect(throws: AgentError.self) {
      try validator.validate(admission: admission)
    }
  }
}

@Test
func modelTurnValidatesBinaryReasoningResponseIdentifierAndUsage() throws {
  let validator = RuntimeResourceValidator(
    limits: RuntimeResourceLimits(
      maxMessageUTF8Bytes: 4,
      maxIdentifierUTF8Bytes: 4
    )
  )

  #expect(throws: AgentError.self) {
    try validator.validate(
      turn: ModelTurn(
        contentParts: [
          .image(ModelBinaryContent(mimeType: "image/png", data: Data(repeating: 0, count: 5)))
        ]
      )
    )
  }
  #expect(throws: AgentError.self) {
    try validator.validate(turn: ModelTurn(content: "ok", responseID: "12345"))
  }
  #expect(throws: AgentError.self) {
    try validator.validate(turn: ModelTurn(content: "ok", reasoningSummary: "12345"))
  }
  #expect(throws: AgentError.self) {
    try validator.validate(
      turn: ModelTurn(content: "ok", usage: ModelUsage(outputTokens: -1))
    )
  }
}

@Test
func oversizedSignalPayloadDoesNotResolveDurableWait() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let timestamp = Date(timeIntervalSince1970: 1_726_100_100)
  try await store.createSession(
    SessionSnapshot(
      sessionID: "signal-limit",
      createdAt: timestamp,
      updatedAt: timestamp,
      messages: [AgentMessage(role: .user, content: "go")]
    ), events: [], effects: [])
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      resourceLimits: RuntimeResourceLimits(maxToolArgumentsUTF8Bytes: 8)
    )
  )
  _ = try await coordinator.waitForSignal(
    sessionID: "signal-limit",
    identifier: "ready"
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.resumeSignalWait(
      sessionID: "signal-limit",
      identifier: "ready",
      payload: .string("payload-too-large")
    )
  }

  let snapshot = try #require(try await store.loadSnapshot(sessionID: "signal-limit"))
  #expect(snapshot.status == .waiting)
  #expect(snapshot.waitState?.identifier == "ready")
  #expect(snapshot.lastSignal == nil)
}

private func nestedJSON(depth: Int) -> JSONValue {
  var value: JSONValue = .null
  for _ in 0..<depth {
    value = .array([value])
  }
  return value
}

@Test
func deeplyNestedModelArgumentsFailBeforeCanonicalEncodingAndPersistFailure() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let deepArguments = nestedJSON(depth: 8)
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(scriptedTurns: [
      ModelTurn(
        content: "tool",
        toolCalls: [
          ToolCall(id: "deep-call", name: "unknown.deep", arguments: deepArguments)
        ]
      )
    ]),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      resourceLimits: RuntimeResourceLimits(
        jsonStructureLimits: RuntimeJSONStructureLimits(maxDepth: 4)
      )
    ),
    idGenerator: { "json-depth-session" }
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.startSession(userPrompt: "go")
  }

  let snapshot = try #require(
    try await store.loadSnapshot(sessionID: "json-depth-session")
  )
  #expect(snapshot.status == .failed)
  #expect(snapshot.failure?.code == "budget_exceeded")
  #expect(snapshot.failure?.message.contains("JSON depth exceeds 4") == true)
  #expect(snapshot.messages.count == 1)
}

@Test
func nonFiniteSignalPayloadIsRejectedWithoutClearingWait() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let timestamp = Date(timeIntervalSince1970: 1_726_100_200)
  try await store.createSession(
    SessionSnapshot(
      sessionID: "signal-nonfinite",
      createdAt: timestamp,
      updatedAt: timestamp,
      messages: [AgentMessage(role: .user, content: "go")]
    ), events: [], effects: [])
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: []
  )
  _ = try await coordinator.waitForSignal(
    sessionID: "signal-nonfinite",
    identifier: "ready"
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.resumeSignalWait(
      sessionID: "signal-nonfinite",
      identifier: "ready",
      payload: .number(.nan)
    )
  }

  let snapshot = try #require(
    try await store.loadSnapshot(sessionID: "signal-nonfinite")
  )
  #expect(snapshot.status == .waiting)
  #expect(snapshot.waitState?.identifier == "ready")
  #expect(snapshot.lastSignal == nil)
}

@Test
func invalidJSONStructureLimitFailsAtCompositionBoundary() throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }

  #expect(throws: AgentError.self) {
    try SessionCoordinator(
      modelClient: ScriptedModelClient(),
      approvalRouter: AllowAllApprovalRouter(),
      runtimeStore: ApplicationSupportSessionStore(rootURL: root),
      toolPacks: [],
      configuration: RuntimeConfiguration(
        resourceLimits: RuntimeResourceLimits(
          jsonStructureLimits: RuntimeJSONStructureLimits(maxDepth: 0)
        )
      )
    )
  }
}

@Test
func unboundedContextPolicyFailsAtCompositionBoundary() throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }

  #expect(throws: AgentError.self) {
    try SessionCoordinator(
      modelClient: ScriptedModelClient(),
      approvalRouter: AllowAllApprovalRouter(),
      runtimeStore: ApplicationSupportSessionStore(rootURL: root),
      toolPacks: [],
      configuration: RuntimeConfiguration(
        contextBudgetPolicy: ContextBudgetPolicy(
          windowTokens: ContextBudgetPolicy.supportedMaximumWindowTokens + 1
        )
      )
    )
  }
}

@Test
func oversizedToolIdentifierPersistsStructuredFailureBeforeAssistantAppend() async throws {
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(scriptedTurns: [
      ModelTurn(
        content: "tool",
        toolCalls: [
          ToolCall(id: "call", name: String(repeating: "t", count: 33), arguments: .object([:]))
        ]
      )
    ]),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    toolPacks: [],
    configuration: RuntimeConfiguration(
      resourceLimits: RuntimeResourceLimits(
        jsonStructureLimits: .standard,
        maxIdentifierUTF8Bytes: 32
      )
    ),
    idGenerator: { "identifier-limit-session" }
  )

  await #expect(throws: AgentError.self) {
    _ = try await coordinator.startSession(userPrompt: "go")
  }

  let snapshot = try #require(
    try await store.loadSnapshot(sessionID: "identifier-limit-session")
  )
  #expect(snapshot.status == .failed)
  #expect(snapshot.failure?.code == "budget_exceeded")
  #expect(snapshot.failure?.message.contains("tool call name") == true)
  #expect(snapshot.messages.count == 1)
}

@Test
func modelTurnUsesOneCanonicalToolCallCollection() throws {
  let call = ToolCall(
    id: "call-canonical",
    name: "unknown.canonical",
    arguments: .object([:])
  )
  let original = ModelTurn(content: "canonical", toolCalls: [call])
  let encoded = try JSONEncoder.nativeAgent().encode(original)
  let decoded = try JSONDecoder.nativeAgent().decode(ModelTurn.self, from: encoded)

  #expect(decoded == original)
  #expect(decoded.toolCalls == [call])
}

@Test
func cumulativeSessionArtifactBytesAreBounded() throws {
  let validator = RuntimeResourceValidator(
    limits: RuntimeResourceLimits(
      jsonStructureLimits: .standard,
      maxSessionArtifactBytes: 5
    )
  )
  let snapshot = SessionSnapshot(
    sessionID: "artifact-budget-session",
    artifacts: [
      ArtifactRecord(
        id: "artifact-1",
        sessionID: "artifact-budget-session",
        filename: "a.txt",
        relativePath: "artifacts/a.txt",
        mimeType: "text/plain",
        byteCount: 3,
        contentSHA256: String(repeating: "0", count: 64)
      ),
      ArtifactRecord(
        id: "artifact-2",
        sessionID: "artifact-budget-session",
        filename: "b.txt",
        relativePath: "artifacts/b.txt",
        mimeType: "text/plain",
        byteCount: 3,
        contentSHA256: String(repeating: "0", count: 64)
      ),
    ]
  )

  #expect(throws: AgentError.self) {
    try validator.validate(snapshot: snapshot)
  }
}

@Test
func incrementalValidationRejectsConflictingHistoricalToolCallIdentifier() throws {
  let originalCall = ToolCall(
    id: "shared-call",
    name: "example.original",
    arguments: .object(["value": .string("one")])
  )
  let initial = SessionSnapshot(
    sessionID: "incremental-validation-session",
    messages: [
      AgentMessage(
        id: "original-message",
        role: .assistant,
        content: "original",
        toolCalls: [originalCall]
      )
    ]
  )
  let validator = RuntimeResourceValidator(limits: RuntimeResourceLimits())
  let previous = try validator.validatedIndex(snapshot: initial)
  let conflictingMessage = AgentMessage(
    id: "conflicting-message",
    role: .assistant,
    content: "conflict",
    toolCalls: [
      ToolCall(
        id: originalCall.id,
        name: "example.changed",
        arguments: .object(["value": .string("two")])
      )
    ]
  )
  let reduction = try SessionReducer.reduce(
    .append(
      messages: [conflictingMessage],
      artifacts: initial.artifacts,
      updatedAt: Date(timeIntervalSince1970: 1),
      reason: .assistantTurnAppended
    ),
    state: initial
  )
  let delta = try #require(reduction.persistenceDelta)

  #expect(throws: AgentError.self) {
    _ = try validator.validatedIndex(
      snapshot: reduction.snapshot,
      delta: delta,
      previous: previous
    )
  }
}

@Test
func runtimeRejectsDatesOutsideJournalRepresentableRangeWithoutTrapping() throws {
  let validator = RuntimeResourceValidator(limits: RuntimeResourceLimits())
  let snapshot = SessionSnapshot(
    sessionID: "date-range-session",
    createdAt: Date(timeIntervalSince1970: .greatestFiniteMagnitude),
    updatedAt: Date(timeIntervalSince1970: .greatestFiniteMagnitude)
  )

  #expect(throws: AgentError.self) {
    try validator.validate(snapshot: snapshot)
  }
}

@Test
func toolErrorTransitionBoundsMessageAndRecordsTruncationEvidence() throws {
  let transitions = AgentLoopSnapshotTransitions(
    now: { Date(timeIntervalSince1970: 1) },
    idGenerator: { "tool-error-message" },
    maximumFailureMessageUTF8Bytes: 4
  )
  let reduction = try transitions.appendingToolError(
    callID: "call",
    toolName: "tool",
    content: "123456789",
    to: SessionSnapshot(sessionID: "tool-error-bound")
  )
  let message = try #require(reduction.snapshot.messages.last)

  #expect(message.content == "1234")
  #expect(message.metadata["messageTruncated"]?.boolValue == true)
  #expect(message.metadata["originalMessageUTF8Bytes"]?.intValue == 9)
}

@Test
func snapshotValidationAllowsIdempotentCallReuseButRejectsConflictingCallIdentity() throws {
  let callID = "reused-call"
  let sessionID = "durable-identities"
  let timestamp = Date(timeIntervalSince1970: 1)
  let validator = RuntimeResourceValidator(limits: RuntimeResourceLimits())
  let repeatedCall = ToolCall(
    id: callID,
    name: "tool.one",
    arguments: .object(["value": .string("same")])
  )

  try validator.validate(
    snapshot: SessionSnapshot(
      sessionID: sessionID,
      messages: [
        AgentMessage(
          id: "assistant-one",
          role: .assistant,
          content: "one",
          toolCalls: [repeatedCall]
        ),
        AgentMessage(
          id: "assistant-two",
          role: .assistant,
          content: "two",
          toolCalls: [repeatedCall]
        ),
      ]
    ))

  #expect(throws: AgentError.self) {
    try validator.validate(
      snapshot: SessionSnapshot(
        sessionID: sessionID,
        messages: [
          AgentMessage(
            id: "assistant-one",
            role: .assistant,
            content: "one",
            toolCalls: [repeatedCall]
          ),
          AgentMessage(
            id: "assistant-two",
            role: .assistant,
            content: "two",
            toolCalls: [
              ToolCall(
                id: callID,
                name: "tool.two",
                arguments: .object(["value": .string("different")])
              )
            ]
          ),
        ]
      ))
  }

  let artifact = ArtifactRecord(
    id: "duplicate-artifact",
    sessionID: sessionID,
    filename: "one.txt",
    relativePath: "Artifacts/one.txt",
    mimeType: "text/plain",
    byteCount: 1,
    contentSHA256: String(repeating: "0", count: 64),
    createdAt: timestamp
  )
  #expect(throws: AgentError.self) {
    try validator.validate(
      snapshot: SessionSnapshot(
        sessionID: sessionID,
        artifacts: [artifact, artifact]
      ))
  }
}


@Test
func runtimeToolBoundsUseModelCoreAsSingleAuthority() throws {
  #expect(RuntimeResourceLimits.standardMaxToolCount == ModelToolContract.maximumDefinitionCount)
  #expect(RuntimeResourceLimits.supportedMaximumToolCount == ModelToolContract.maximumDefinitionCount)
  #expect(RuntimeResourceLimits.standardMaxToolCallsPerTurn == ModelToolContract.maximumCallsPerTurn)
  #expect(RuntimeResourceLimits.supportedMaximumToolCallsPerTurn == ModelToolContract.maximumCallsPerTurn)

  let tooMany = RuntimeResourceLimits.supportedMaximumToolCallsPerTurn + 1
  let root = resourceLimitRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(throws: AgentError.self) {
    try SessionCoordinator(
      modelClient: ScriptedModelClient(),
      approvalRouter: AllowAllApprovalRouter(),
      runtimeStore: ApplicationSupportSessionStore(rootURL: root),
      toolPacks: [],
      configuration: RuntimeConfiguration(
        resourceLimits: RuntimeResourceLimits(maxToolCallsPerTurn: tooMany)
      )
    )
  }
}

@Test
func configuredIdentifierLimitAlsoBoundsRegisteredToolNames() throws {
  let validator = RuntimeResourceValidator(
    limits: RuntimeResourceLimits(maxIdentifierUTF8Bytes: 8)
  )
  let definition = ToolDefinition(
    name: "tool.name",
    description: "valid model tool with a host limit that is intentionally smaller",
    capabilityID: CapabilityID("tool-cap"),
    inputSchema: .object(["type": .string("object")]),
    approvalPolicy: .automatic,
    effect: .readOnly
  )

  #expect(throws: AgentError.self) {
    try validator.validate(toolDefinitions: [definition])
  }
}

@Test
func registeredToolContractCannotExceedModelCoreToolSurface() throws {
  let validator = RuntimeResourceValidator(limits: RuntimeResourceLimits())
  let invalidName = ToolDefinition(
    name: "invalid name",
    description: "invalid",
    capabilityID: CapabilityID("invalid-name"),
    inputSchema: .object(["type": .string("object")]),
    approvalPolicy: .automatic,
    effect: .readOnly
  )
  #expect(throws: AgentError.self) {
    try validator.validate(toolDefinitions: [invalidName])
  }

  let oversizedDescription = ToolDefinition(
    name: "valid.name",
    description: String(repeating: "d", count: ModelToolContract.maximumDescriptionUTF8Bytes + 1),
    capabilityID: CapabilityID("oversized-description"),
    inputSchema: .object(["type": .string("object")]),
    approvalPolicy: .automatic,
    effect: .readOnly
  )
  #expect(throws: AgentError.self) {
    try validator.validate(toolDefinitions: [oversizedDescription])
  }
}
