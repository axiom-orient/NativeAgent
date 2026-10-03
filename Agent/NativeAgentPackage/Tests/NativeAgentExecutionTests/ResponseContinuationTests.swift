import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private func makeContinuationTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor CapturedContinuationSnapshot {
    private var valueStorage: SessionSnapshot?

    func record(_ snapshot: SessionSnapshot?) {
        valueStorage = snapshot
    }

    func value() -> SessionSnapshot? {
        valueStorage
    }
}

private struct FailingContinuationModelClient: ModelClient {
    let providerID = "provider.test.failing-continuation"
    let store: ApplicationSupportSessionStore
    let sessionID: String
    let capture: CapturedContinuationSnapshot

    func generate(request: ModelRequest) async throws -> ModelTurn {
        await capture.record(try await store.loadSnapshot(sessionID: sessionID))
        throw AgentError.unavailableProvider("continuation regression failure")
    }
}

@Test
func truncatedFinishReasonContinuesWhenPolicyIsEnabled() async throws {
    let tempRoot = makeContinuationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "partial",
            metadata: ["finishReason": .string("length")]
        ),
        ModelTurn(content: "complete")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "Explain the design.",
        responseContinuation: .truncatedResponseOnly(maxAdditionalTurns: 1)
    )

    #expect(snapshot.status == .completed)
    #expect(await provider.callCount() == 2)
    #expect(snapshot.messages.contains(where: {
        $0.role == .user &&
        $0.metadata[ResponseContinuationMetadata.syntheticRequestKey]?.boolValue == true &&
        $0.content == ResponseContinuationMetadata.syntheticPrompt
    }))
    #expect(snapshot.messages.last?.content == "complete")
}

@Test
func typedMaxTokensStopReasonDrivesContinuation() async throws {
    let tempRoot = makeContinuationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "partial",
            metadata: ["provider": .string("test")],
            stopReason: .maxTokens
        ),
        ModelTurn(content: "complete")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "Explain the design.",
        responseContinuation: .truncatedResponseOnly(maxAdditionalTurns: 1)
    )

    #expect(snapshot.status == .completed)
    #expect(await provider.callCount() == 2)
    #expect(snapshot.messages.last?.content == "complete")
}

@Test
func typedStopReasonCannotBeOverriddenByConflictingRawMetadata() async throws {
    let tempRoot = makeContinuationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "complete",
            metadata: [
                ModelStopReasonMetadata.key: .string("maxTokens"),
                "finishReason": .string("max_tokens")
            ],
            stopReason: .stop
        ),
        ModelTurn(content: "unused")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "Explain the design.",
        responseContinuation: .truncatedResponseOnly(maxAdditionalTurns: 1)
    )

    #expect(snapshot.status == .completed)
    #expect(await provider.callCount() == 1)
    #expect(snapshot.messages.contains(where: {
        $0.metadata[ResponseContinuationMetadata.syntheticRequestKey]?.boolValue == true
    }) == false)
    #expect(snapshot.messages.last?.content == "complete")
}

@Test
func truncatedFinishReasonDoesNotContinueByDefault() async throws {
    let tempRoot = makeContinuationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "partial",
            metadata: ["finishReason": .string("length")]
        ),
        ModelTurn(content: "unused")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(userPrompt: "Explain the design.")

    #expect(snapshot.status == .completed)
    #expect(await provider.callCount() == 1)
    #expect(snapshot.messages.contains(where: {
        $0.metadata[ResponseContinuationMetadata.syntheticRequestKey]?.boolValue == true
    }) == false)
    #expect(snapshot.messages.last?.content == "partial")
}

@Test
func truncatedFinishReasonStopsAfterConfiguredContinuationBudget() async throws {
    let tempRoot = makeContinuationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "partial-1",
            metadata: ["finishReason": .string("max_tokens")]
        ),
        ModelTurn(
            content: "partial-2",
            metadata: ["finishReason": .string("max_tokens")]
        ),
        ModelTurn(content: "unused")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "Explain the design.",
        responseContinuation: .truncatedResponseOnly(maxAdditionalTurns: 1)
    )

    #expect(snapshot.status == .completed)
    #expect(await provider.callCount() == 2)
    #expect(snapshot.messages.filter {
        $0.metadata[ResponseContinuationMetadata.syntheticRequestKey]?.boolValue == true
    }.count == 1)
    #expect(snapshot.messages.last?.content == "partial-2")
}

@Test
func normalizedStopReasonMetadataDrivesContinuationWithoutProviderRawKeys() async throws {
    let tempRoot = makeContinuationTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "partial",
            metadata: ModelStopReasonMetadata.applying(.maxTokens, to: [:])
        ),
        ModelTurn(content: "complete")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "Explain the design.",
        responseContinuation: .truncatedResponseOnly(maxAdditionalTurns: 1)
    )

    #expect(snapshot.status == .completed)
    #expect(await provider.callCount() == 2)
    #expect(snapshot.messages.last?.content == "complete")
}

@Test
func malformedResponseContinuationMetadataFailsExplicitly() throws {
    #expect(throws: AgentError.self) {
        _ = try ResponseContinuationMetadata.policy(from: [
            ResponseContinuationMetadata.policyKey: .string("malformed")
        ])
    }
}

@Test
func waitResumeWithoutPromptPersistsContinuationPolicyBeforeAdvance() async throws {
    let tempRoot = makeContinuationTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_001_600)
    let sessionID = "wait-resume-continuation"
    let capture = CapturedContinuationSnapshot()
    let initial = SessionSnapshot(
        sessionID: sessionID,
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "initial-user",
                role: .user,
                content: "seed",
                createdAt: timestamp
            )
        ]
    )
    try await store.createSession(initial, events: [], effects: [])

    let coordinator = try SessionCoordinator(
        modelClient: FailingContinuationModelClient(
            store: store,
            sessionID: sessionID,
            capture: capture
        ),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        now: { timestamp }
    )
    _ = try await coordinator.waitUntil(
        sessionID: sessionID,
        resumeAt: timestamp.addingTimeInterval(-1),
        identifier: "timer.continuation"
    )

    await #expect(throws: ModelGenerationFailure.self) {
        _ = try await coordinator.resumeTimeWait(
            sessionID: sessionID,
            asOf: timestamp,
            responseContinuation: .truncatedResponseOnly(maxAdditionalTurns: 1)
        )
    }

    let captured = try #require(await capture.value())
    #expect(captured.status == .running)
    #expect(captured.waitState == nil)
    #expect(
        captured.metadata[ResponseContinuationMetadata.policyKey] == .object([
            "mode": .string(ResponseContinuationMode.truncatedResponseOnly.rawValue),
            "maxAdditionalTurns": .integer(1)
        ])
    )

    let restartedStore = ApplicationSupportSessionStore(rootURL: tempRoot)
    let restartedCoordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: restartedStore,
        toolPacks: []
    )
    let persisted = try await restartedCoordinator.loadSession(sessionID: sessionID)
    #expect(persisted.status == .waiting)
    #expect(persisted.waitState?.kind == .modelInvocation)
    #expect(
        persisted.metadata[ResponseContinuationMetadata.policyKey] == .object([
            "mode": .string(ResponseContinuationMode.truncatedResponseOnly.rawValue),
            "maxAdditionalTurns": .integer(1)
        ])
    )
}

@Test
func persistedResponseContinuationPolicyRejectsOutOfRangeTurns() throws {
    let negative = JSONValue.object([
        "mode": .string(ResponseContinuationMode.truncatedResponseOnly.rawValue),
        "maxAdditionalTurns": .integer(-1)
    ])
    #expect(throws: DecodingError.self) {
        _ = try negative.decode(ResponseContinuationPolicy.self)
    }

    let excessive = JSONValue.object([
        "mode": .string(ResponseContinuationMode.truncatedResponseOnly.rawValue),
        "maxAdditionalTurns": .integer(Int64(ResponseContinuationPolicy.supportedMaximumAdditionalTurns + 1))
    ])
    #expect(throws: DecodingError.self) {
        _ = try excessive.decode(ResponseContinuationPolicy.self)
    }
}
