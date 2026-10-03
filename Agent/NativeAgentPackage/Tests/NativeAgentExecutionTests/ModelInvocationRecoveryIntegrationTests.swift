import NativeAgentTestSupport
import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore

private actor CountingModelClient: ModelClient {
    nonisolated let providerID = "provider.test.counting"
    private var invocationCount = 0

    func generate(request: ModelRequest) async throws -> ModelTurn {
        invocationCount += 1
        return ModelTurn(content: "response-\(invocationCount)")
    }

    func count() -> Int {
        invocationCount
    }
}

private actor OutcomeUnknownModelClient: ModelClient {
    nonisolated let providerID = "provider.test.outcome-unknown"
    private var invocationCount = 0

    func generate(request: ModelRequest) async throws -> ModelTurn {
        invocationCount += 1
        throw EffectFailure.outcomeUnknown(
            operation: "model.generate",
            cause: "transport ended before the provider outcome was confirmed",
            context: ["sessionID": request.sessionID]
        )
    }

    func count() -> Int {
        invocationCount
    }
}

private final class PreStartOutcomeUnknownModelClient: ModelClient, @unchecked Sendable {
    let providerID = "provider.test.pre-start-outcome-unknown"
    private let lock = NSLock()
    private var invocationCount = 0

    func generate(request: ModelRequest) async throws -> ModelTurn {
        throw EffectFailure.outcomeUnknown(
            operation: "model.generate",
            cause: "preflight failure before provider dispatch",
            context: ["sessionID": request.sessionID]
        )
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        lock.lock()
        invocationCount += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: EffectFailure.outcomeUnknown(
                operation: "model.preflight",
                cause: "preflight failure before provider dispatch",
                context: ["sessionID": request.sessionID]
            ))
        }
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }
}

private actor AssistantCommitFailureStore:
    SessionRuntimeStore,
    SessionEventStore,
    EffectLedgerStore,
    SessionExecutionClaimStore
{
    private let base: ApplicationSupportSessionStore
    private var remainingCompletedModelCommitFailures: Int

    init(base: ApplicationSupportSessionStore, failures: Int) {
        self.base = base
        self.remainingCompletedModelCommitFailures = failures
    }

    func prepare() async throws { try await base.prepare() }
    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? { try await base.loadSessionRuntimeAdmission(sessionID: sessionID) }
    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {
        try await base.createSession(snapshot, events: events, effects: effects)
    }
    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? {
        try await base.loadSnapshot(sessionID: sessionID)
    }
    func commit(_ transaction: SessionPersistenceTransaction) async throws {
        let completesModelInvocation = transaction.effects.contains {
            $0.scope == .modelInvocation && $0.status == .completed
        }
        if completesModelInvocation && remainingCompletedModelCommitFailures > 0 {
            remainingCompletedModelCommitFailures -= 1
            throw AgentError.persistenceFailure(
                "Injected assistant/model-invocation transaction failure"
            )
        }
        try await base.commit(transaction)
    }
    func loadEvents(sessionID: String) async throws -> [SessionEvent] {
        try await base.loadEvents(sessionID: sessionID)
    }
    func loadEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) async throws -> EffectRecord? {
        try await base.loadEffect(sessionID: sessionID, scope: scope, key: key)
    }
    func saveEffect(_ effect: EffectRecord) async throws {
        try await base.saveEffect(effect)
    }
    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        try await base.acquireExecutionClaim(sessionID: sessionID)
    }
    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        try await base.releaseExecutionClaim(claim)
    }
    func persistArtifact(
        sessionID: String,
        artifact: ArtifactWriteRequest,
        createdAt: Date
    ) async throws -> ArtifactRecord {
        try await base.persistArtifact(
            sessionID: sessionID,
            artifact: artifact,
            createdAt: createdAt
        )
    }
    func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws {
        try await base.discardUnreferencedArtifact(artifact)
    }
    func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        try await base.loadArtifact(sessionID: sessionID, artifactID: artifactID)
    }
    func sandboxRootURL() async throws -> URL {
        try await base.sandboxRootURL()
    }
    func sessionDirectoryURL(sessionID: String) async throws -> URL {
        try await base.sessionDirectoryURL(sessionID: sessionID)
    }
}

private func makeModelInvocationTempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-model-invocation-\(UUID().uuidString)", isDirectory: true)
}

@Test
func uncertainModelInvocationWaitsInsteadOfBlindlyCallingProviderAgain() async throws {
    let root = makeModelInvocationTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = ApplicationSupportSessionStore(rootURL: root)
    let store = AssistantCommitFailureStore(base: base, failures: 1)
    let model = CountingModelClient()
    let sessionID = "model-uncertain-session"

    let firstCoordinator = try SessionCoordinator(
        modelClient: model,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: .agentDefault
    )

    do {
        _ = try await firstCoordinator.startSession(
            sessionID: sessionID,
            userPrompt: "hello"
        )
        Issue.record("Expected injected model response commit failure")
    } catch let error as AgentError {
        guard case .persistenceFailure(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("assistant/model-invocation"))
    }
    #expect(await model.count() == 1)

    let restarted = try SessionCoordinator(
        modelClient: model,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: .agentDefault
    )
    let waiting = try await restarted.run(sessionID: sessionID)

    #expect(waiting.status == .waiting)
    #expect(waiting.waitState?.kind == .modelInvocation)
    #expect(await model.count() == 1)

    let pending = try #require(
        try await restarted.pendingModelInvocation(sessionID: sessionID)
    )
    #expect(pending.providerID == model.providerID)
    #expect(pending.request.sessionID == sessionID)

    let oldRecord = try #require(try await store.loadEffect(
        sessionID: sessionID,
        scope: .modelInvocation,
        key: pending.id
    ))
    #expect(oldRecord.status == .started)
    let startedInput = try oldRecord.input.canonicalString()
    #expect(oldRecord.input.objectValue?["schemaVersion"]?.stringValue == "native-agent.model-invocation/2")
    #expect(startedInput.contains("hello") == false)
    #expect(pending.request.messages.contains(where: { $0.role == .user && $0.content == "hello" }))

    let completed = try await restarted.resolvePendingModelInvocation(
        sessionID: sessionID,
        invocationID: pending.id,
        resolution: .retry(reason: "Host confirmed the first request did not complete")
    )

    #expect(await model.count() == 2)
    #expect(completed.status == .completed)
    #expect(completed.messages.last(where: { $0.role == .assistant })?.content == "response-2")

    let resolvedOldRecord = try #require(try await store.loadEffect(
        sessionID: sessionID,
        scope: .modelInvocation,
        key: pending.id
    ))
    #expect(resolvedOldRecord.status == .failed)
}

@Test
func preStartOutcomeUnknownFailureIsDefiniteAndDoesNotEnterReconciliation() async throws {
    let root = makeModelInvocationTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let model = PreStartOutcomeUnknownModelClient()
    let sessionID = "model-pre-start-definite-session"
    let coordinator = try SessionCoordinator(
        modelClient: model,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: .agentDefault
    )

    do {
        _ = try await coordinator.startSession(
            sessionID: sessionID,
            userPrompt: "hello"
        )
        Issue.record("Expected pre-start model failure")
    } catch {}

    let failed = try #require(try await store.loadSnapshot(sessionID: sessionID))
    #expect(failed.status == .failed)
    #expect(failed.waitState == nil)
    #expect(model.count() == 1)
    #expect(try await coordinator.pendingModelInvocation(sessionID: sessionID) == nil)
}

@Test
func outcomeUnknownModelFailureKeepsStartedReceiptUntilExplicitResolution() async throws {
    let root = makeModelInvocationTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationSupportSessionStore(rootURL: root)
    let model = OutcomeUnknownModelClient()
    let sessionID = "model-outcome-unknown-session"
    let coordinator = try SessionCoordinator(
        modelClient: model,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: .agentDefault
    )

    do {
        _ = try await coordinator.startSession(
            sessionID: sessionID,
            userPrompt: "hello"
        )
        Issue.record("Expected outcome-unknown model failure")
    } catch let error as ModelGenerationFailure {
        #expect(error.code == .transportFailure)
    }

    let waiting = try #require(try await store.loadSnapshot(sessionID: sessionID))
    #expect(waiting.status == .waiting)
    #expect(waiting.waitState?.kind == .modelInvocation)
    #expect(waiting.failure == nil)
    #expect(await model.count() == 1)

    let pending = try #require(
        try await coordinator.pendingModelInvocation(sessionID: sessionID)
    )
    let receipt = try #require(try await store.loadEffect(
        sessionID: sessionID,
        scope: .modelInvocation,
        key: pending.id
    ))
    #expect(receipt.status == .started)

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.run(sessionID: sessionID)
    }
    #expect(await model.count() == 1)

    let resolved = try await coordinator.resolvePendingModelInvocation(
        sessionID: sessionID,
        invocationID: pending.id,
        resolution: .completed(ModelTurn(content: "host verified response"))
    )
    #expect(resolved.status == .completed)
    #expect(resolved.messages.last(where: { $0.role == .assistant })?.content == "host verified response")
    #expect(await model.count() == 1)
    let completedReceipt = try #require(try await store.loadEffect(
        sessionID: sessionID,
        scope: .modelInvocation,
        key: pending.id
    ))
    #expect(completedReceipt.status == .completed)
    let completedResult = try #require(completedReceipt.result).canonicalString()
    #expect(completedReceipt.result?.objectValue?["schemaVersion"]?.stringValue == "native-agent.model-turn/2")
    #expect(completedResult.contains("host verified response") == false)
}

@Test
func hostVerifiedModelResponseCompletesWithoutAnotherProviderCall() async throws {
    let root = makeModelInvocationTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = ApplicationSupportSessionStore(rootURL: root)
    let store = AssistantCommitFailureStore(base: base, failures: 1)
    let model = CountingModelClient()
    let sessionID = "model-verified-session"

    let coordinator = try SessionCoordinator(
        modelClient: model,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: .agentDefault
    )
    do {
        _ = try await coordinator.startSession(
            sessionID: sessionID,
            userPrompt: "hello"
        )
        Issue.record("Expected injected model response commit failure")
    } catch {
        // The exact failure is asserted by the preceding regression test.
    }

    let restarted = try SessionCoordinator(
        modelClient: model,
        approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: .agentDefault
    )
    _ = try await restarted.run(sessionID: sessionID)
    let pending = try #require(
        try await restarted.pendingModelInvocation(sessionID: sessionID)
    )

    do {
        _ = try await restarted.resolvePendingModelInvocation(
            sessionID: sessionID,
            invocationID: "stale-model-invocation",
            resolution: .completed(ModelTurn(content: "stale-response"))
        )
        Issue.record("Expected stale model invocation resolution to be rejected")
    } catch let error as AgentError {
        guard case .invariantViolation = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
    }
    #expect(await model.count() == 1)
    #expect(try await restarted.pendingModelInvocation(sessionID: sessionID) == pending)

    let final = try await restarted.resolvePendingModelInvocation(
        sessionID: sessionID,
        invocationID: pending.id,
        resolution: .completed(
            ModelTurn(content: "verified-response")
        )
    )

    #expect(await model.count() == 1)
    #expect(final.status == .completed)
    #expect(final.messages.last(where: { $0.role == .assistant })?.content == "verified-response")
    #expect(try await restarted.pendingModelInvocation(sessionID: sessionID) == nil)
}

private struct LegacyModelInvocationKeyInput: Codable {
    let providerID: String
    let snapshotRevision: Int64
    let request: ModelRequest
}

private func makeStartedInvocationFixture(
    sessionID: String = "model-manifest-fixture"
) async throws -> (
    root: URL,
    store: ApplicationSupportSessionStore,
    ledger: ModelInvocationLedger,
    snapshot: SessionSnapshot,
    request: ModelRequest,
    started: EffectRecord,
    pending: PendingModelInvocation
) {
    let root = makeModelInvocationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: root)
    let message = AgentMessage(
        id: "user-fixture",
        role: .user,
        content: "fixture-secret-body",
        createdAt: Date(timeIntervalSince1970: 1)
    )
    let snapshot = SessionSnapshot(
        revision: 0,
        sessionID: sessionID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        messages: [message]
    )
    try await store.createSession(snapshot, events: [], effects: [])
    let request = ModelRequest(sessionID: sessionID, messages: [message], tools: [])
    let ledger = ModelInvocationLedger(store: store, now: { Date(timeIntervalSince1970: 2) })
    let decision = try await ledger.decision(
        request: request,
        snapshot: snapshot,
        snapshotRevision: snapshot.revision,
        providerID: "provider.fixture"
    )
    guard case let .invoke(pending, started) = decision else {
        throw AgentError.invariantViolation("Expected a new model invocation fixture.")
    }
    try await ledger.save(started)
    return (root, store, ledger, snapshot, request, started, pending)
}

private func replaceFixtureMessages(
    _ messages: [AgentMessage],
    snapshot: SessionSnapshot,
    store: ApplicationSupportSessionStore
) async throws {
    let updated = SessionSnapshot(
        revision: snapshot.revision + 1,
        sessionID: snapshot.sessionID,
        title: snapshot.title,
        status: snapshot.status,
        createdAt: snapshot.createdAt,
        updatedAt: Date(timeIntervalSince1970: 3),
        messages: messages,
        artifacts: snapshot.artifacts,
        providerID: snapshot.providerID,
        modelID: snapshot.modelID,
        metadata: snapshot.metadata,
        contextCheckpoint: snapshot.contextCheckpoint,
        waitState: snapshot.waitState,
        failure: snapshot.failure,
        lastSignal: snapshot.lastSignal
    )
    try await store.commit(
        SessionPersistenceTransaction(
            snapshot: updated,
            delta: SessionPersistenceDelta(
                expectedRevision: snapshot.revision,
                messages: .replace(messages: messages)
            )
        )
    )
}

@Test
func modelInvocationStartedReceiptStoresReferencesAndUsesCanonicalRequestIdentity() async throws {
    let fixture = try await makeStartedInvocationFixture(sessionID: "model-manifest-reference")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let input = try fixture.started.input.canonicalString()
    #expect(fixture.started.input.objectValue?["schemaVersion"]?.stringValue == "native-agent.model-invocation/2")
    #expect(input.contains("user-fixture"))
    #expect(input.contains("fixture-secret-body") == false)

    let identity = LegacyModelInvocationKeyInput(
        providerID: "provider.fixture",
        snapshotRevision: fixture.snapshot.revision,
        request: fixture.request
    )
    let expected = "model-\(SHA256HexDigest.digest(try JSONValue.encode(identity).canonicalString()))"
    #expect(fixture.pending.id == expected)

    let hydrated = try await fixture.ledger.pending(
        sessionID: fixture.snapshot.sessionID,
        key: fixture.pending.id
    )
    #expect(hydrated.request == fixture.request)
}

@Test
func modelInvocationHydrationRejectsMissingReferencedMessage() async throws {
    let fixture = try await makeStartedInvocationFixture(sessionID: "model-manifest-missing")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await replaceFixtureMessages([], snapshot: fixture.snapshot, store: fixture.store)

    await #expect(throws: AgentError.self) {
        _ = try await fixture.ledger.pending(
            sessionID: fixture.snapshot.sessionID,
            key: fixture.pending.id
        )
    }
}

@Test
func modelInvocationHydrationRejectsDigestMismatch() async throws {
    let fixture = try await makeStartedInvocationFixture(sessionID: "model-manifest-digest")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let changed = AgentMessage(
        id: "user-fixture",
        role: .user,
        content: "changed-body",
        createdAt: Date(timeIntervalSince1970: 1)
    )
    try await replaceFixtureMessages([changed], snapshot: fixture.snapshot, store: fixture.store)

    await #expect(throws: AgentError.self) {
        _ = try await fixture.ledger.pending(
            sessionID: fixture.snapshot.sessionID,
            key: fixture.pending.id
        )
    }
}

@Test
func modelInvocationHydrationRejectsDuplicateMessageIDsWithoutTrap() async throws {
    let fixture = try await makeStartedInvocationFixture(sessionID: "model-manifest-duplicate")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let duplicate = AgentMessage(
        id: "user-fixture",
        role: .user,
        content: "duplicate-body",
        createdAt: Date(timeIntervalSince1970: 1)
    )
    try await replaceFixtureMessages(
        [fixture.snapshot.messages[0], duplicate],
        snapshot: fixture.snapshot,
        store: fixture.store
    )

    await #expect(throws: AgentError.self) {
        _ = try await fixture.ledger.pending(
            sessionID: fixture.snapshot.sessionID,
            key: fixture.pending.id
        )
    }
}

@Test
func v2ReceiptRejectsDifferentDurableKey() async throws {
    let fixture = try await makeStartedInvocationFixture(sessionID: "audit-v2-invalid-key")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.started
    let corrupted = EffectRecord(
        sessionID: original.sessionID, scope: original.scope, key: "model-wrong-identity",
        effectType: original.effectType, status: original.status,
        createdAt: original.createdAt, updatedAt: original.updatedAt,
        input: original.input, metadata: original.metadata)
    try await fixture.ledger.save(corrupted)
    await #expect(throws: AgentError.self) {
        _ = try await fixture.ledger.pending(sessionID: original.sessionID, key: corrupted.key)
    }
}

// Frozen full-body payloads emitted by the v1 writer's Codable field layout.
// Keep these literals independent of the current writer so a codec/key change is detectable.
private let v1InvocationInputJSON = #"""
{
  "providerID": "provider.test.counting",
  "request": {
    "deadline": {
      "attoseconds": 0,
      "seconds": 30
    },
    "limits": {
      "maxBinaryInputBytes": 16777216,
      "maxBinaryOutputBytes": 33554432,
      "maxBinaryOutputParts": 8,
      "maxBinaryParts": 8,
      "maxDeadline": {
        "attoseconds": 0,
        "seconds": 30
      },
      "maxDeltaBytes": 4096,
      "maxFrameBytes": 65536,
      "maxInputBytes": 131072,
      "maxMessageBytes": 16384,
      "maxMessages": 32,
      "maxOutputBytes": 16384,
      "version": "v1"
    },
    "maxOutputBytes": 16384,
    "messages": [
      {
        "content": "v1 persisted request body",
        "contentParts": [
          {
            "kind": "text",
            "text": "v1 persisted request body"
          }
        ],
        "createdAt": 1000,
        "id": "user-v1",
        "metadata": {},
        "role": "user",
        "toolCalls": []
      }
    ],
    "metadata": {
      "legacy": "request-metadata"
    },
    "modelID": "legacy-model",
    "outputFormat": {
      "text": {}
    },
    "requiredCapabilities": 3,
    "sessionID": "model-v1-compatibility",
    "tools": []
  },
  "snapshotRevision": 0
}
"""#
private let v1InvocationResultJSON = #"""
{
  "content": "v1 persisted response body",
  "contentParts": [
    {
      "kind": "text",
      "text": "v1 persisted response body"
    }
  ],
  "metadata": {
    "legacy": "response-metadata"
  },
  "reasoningSummary": "legacy reasoning summary",
  "responseID": "legacy-response-1",
  "stopReason": "stop",
  "toolCalls": [],
  "usage": {
    "inputTokens": 7,
    "outputTokens": 5,
    "totalTokens": 12
  }
}
"""#
private let v1InvocationKey = "model-3a7084937228bc6b496a005e892a9483c64e4e2230b45ab970559df3ee34e7d6"

private func makeV1InvocationFixture(
    waiting: Bool = false,
    completed: Bool = false,
    input replacementInput: JSONValue? = nil,
    key replacementKey: String? = nil,
    result replacementResult: JSONValue? = nil
) async throws -> (
    root: URL,
    store: ApplicationSupportSessionStore,
    requestSnapshot: SessionSnapshot,
    request: ModelRequest,
    record: EffectRecord,
    expectedTurn: ModelTurn
) {
    let input = try JSONDecoder().decode(JSONValue.self, from: Data(v1InvocationInputJSON.utf8))
    let legacy = try input.decode(LegacyModelInvocationKeyInput.self)
    let result = try JSONDecoder().decode(JSONValue.self, from: Data(v1InvocationResultJSON.utf8))
    let expectedTurn = try result.decode(ModelTurn.self)
    let request = legacy.request
    let requestSnapshot = SessionSnapshot(
        revision: legacy.snapshotRevision,
        sessionID: request.sessionID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        messages: request.messages,
        providerID: legacy.providerID,
        modelID: request.modelID
    )
    let record = EffectRecord(
        sessionID: request.sessionID,
        scope: .modelInvocation,
        key: replacementKey ?? v1InvocationKey,
        effectType: "model_invocation",
        status: completed ? .completed : .started,
        createdAt: Date(timeIntervalSince1970: 2),
        updatedAt: Date(timeIntervalSince1970: completed ? 3 : 2),
        input: replacementInput ?? input,
        result: completed ? .some(replacementResult ?? result) : .none,
        metadata: [
            "providerID": .string(legacy.providerID),
            "snapshotRevision": .integer(legacy.snapshotRevision),
        ]
    )
    let snapshot = waiting ? SessionSnapshot(
        revision: 1,
        sessionID: request.sessionID,
        status: .waiting,
        createdAt: requestSnapshot.createdAt,
        updatedAt: Date(timeIntervalSince1970: 3),
        messages: request.messages,
        providerID: legacy.providerID,
        modelID: request.modelID,
        waitState: .modelInvocation(
            identifier: record.key,
            providerID: legacy.providerID,
            snapshotRevision: legacy.snapshotRevision,
            createdAt: Date(timeIntervalSince1970: 3)
        )
    ) : requestSnapshot
    let root = makeModelInvocationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: root)
    do {
        // This uses the real SQLite store; no in-memory ledger or provider result is substituted.
        try await store.createSession(snapshot, events: [], effects: [record])
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
    return (root, store, requestSnapshot, request, record, expectedTurn)
}

@Test(arguments: [false, true])
func oldInvocationEnvelopeIsRejectedWithoutRewritingOrProviderExecution(completed: Bool) async throws {
    let fixture = try await makeV1InvocationFixture(waiting: true, completed: completed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let reopened = ApplicationSupportSessionStore(rootURL: fixture.root)
    let original = try await reopened.loadSnapshot(sessionID: fixture.request.sessionID)
    let ledger = ModelInvocationLedger(store: reopened, now: { Date(timeIntervalSince1970: 4) })
    await #expect(throws: AgentError.self) {
        _ = try await ledger.pending(sessionID: fixture.request.sessionID, key: v1InvocationKey)
    }
    await #expect(throws: AgentError.self) {
        _ = try await ledger.decision(
            request: fixture.request, snapshot: fixture.requestSnapshot,
            snapshotRevision: 0, providerID: "provider.test.counting"
        )
    }
    let model = CountingModelClient()
    let coordinator = try SessionCoordinator(
        modelClient: model, approvalRouter: DenyAllApprovalRouter(), runtimeStore: reopened,
        toolPacks: [], configuration: .agentDefault
    )
    await #expect(throws: AgentError.self) {
        _ = try await coordinator.resolvePendingModelInvocation(
            sessionID: fixture.request.sessionID, invocationID: v1InvocationKey,
            resolution: .completed(fixture.expectedTurn)
        )
    }
    #expect(await model.count() == 0)
    #expect(try await reopened.loadSnapshot(sessionID: fixture.request.sessionID) == original)
    #expect(try await reopened.loadEffect(
        sessionID: fixture.request.sessionID, scope: .modelInvocation, key: v1InvocationKey
    ) == fixture.record)
}

@Test(arguments: [false, true])
func completedInvocationRequiresCurrentResultEnvelope(missingSchema: Bool) async throws {
    let fixture = try await makeStartedInvocationFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result: JSONValue = missingSchema
        ? try JSONValue.encode(ModelTurn(content: "unsupported full-body result"))
        : .object(["schemaVersion": .string("native-agent.model-turn/99")])
    let completed = fixture.started.applying(.completed(
        effectType: "model_invocation", result: result,
        metadata: fixture.started.metadata, updatedAt: Date(timeIntervalSince1970: 3)
    ))
    try await fixture.ledger.save(completed)
    await #expect(throws: AgentError.self) {
        _ = try await fixture.ledger.decision(
            request: fixture.request, snapshot: fixture.snapshot,
            snapshotRevision: fixture.snapshot.revision, providerID: "provider.fixture"
        )
    }
    #expect(try await fixture.store.loadEffect(
        sessionID: fixture.request.sessionID, scope: .modelInvocation, key: fixture.pending.id
    ) == completed)
}

@Test(arguments: ["missing-request", "wrong-key", "foreign-session"])
func v1MalformedStartedPayloadIsRejectedWithoutRewritingIt(_ corruption: String) async throws {
    var input = try JSONDecoder().decode(JSONValue.self, from: Data(v1InvocationInputJSON.utf8))
    var key = v1InvocationKey
    switch corruption {
    case "missing-request":
        var object = try #require(input.objectValue)
        object.removeValue(forKey: "request")
        input = .object(object)
    case "wrong-key":
        key = "model-v1-wrong-key"
    case "foreign-session":
        var object = try #require(input.objectValue)
        var request = try #require(object["request"]?.objectValue)
        request["sessionID"] = .string("another-session")
        object["request"] = .object(request)
        input = .object(object)
        // A matching digest must not allow another session's full request to cross the boundary.
        key = "model-" + SHA256HexDigest.digest(try input.canonicalString())
    default:
        throw AgentError.invariantViolation("Unknown fixture corruption.")
    }
    let fixture = try await makeV1InvocationFixture(input: input, key: key)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let reopened = ApplicationSupportSessionStore(rootURL: fixture.root)
    let ledger = ModelInvocationLedger(store: reopened, now: { Date(timeIntervalSince1970: 4) })
    await #expect(throws: AgentError.self) {
        _ = try await ledger.pending(sessionID: fixture.request.sessionID, key: key)
    }
    #expect(try await reopened.loadEffect(
        sessionID: fixture.request.sessionID, scope: .modelInvocation, key: key
    ) == fixture.record)
}

@Test
func v1MalformedCompletedPayloadIsRejectedWithoutRewritingIt() async throws {
    let fixture = try await makeV1InvocationFixture(
        completed: true, result: .object(["content": .integer(7)])
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let reopened = ApplicationSupportSessionStore(rootURL: fixture.root)
    let ledger = ModelInvocationLedger(store: reopened, now: { Date(timeIntervalSince1970: 4) })
    await #expect(throws: AgentError.self) {
        _ = try await ledger.decision(
            request: fixture.request, snapshot: fixture.requestSnapshot,
            snapshotRevision: 0, providerID: "provider.test.counting"
        )
    }
    #expect(try await reopened.loadEffect(
        sessionID: fixture.request.sessionID, scope: .modelInvocation, key: v1InvocationKey
    ) == fixture.record)
}
