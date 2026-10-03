import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
@testable import NativeAgentTools
import NativeAgentTestSupport

private func makeSessionJournalTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func snapshotSaveReasons(_ events: [SessionEvent]) -> [String] {
    events.compactMap { event in
        guard event.kind == .snapshotSaved else {
            return nil
        }
        return event.payload.objectValue?["reason"]?.stringValue
    }
}

private actor ForkTargetCreateFailureStore:
    SessionRuntimeStore,
    RuntimeAtomicSessionForkStore
{
    let base: ApplicationSupportSessionStore
    private var remainingForkFailures: Int

    init(base: ApplicationSupportSessionStore, createFailures: Int) {
        self.base = base
        self.remainingForkFailures = createFailures
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

    func commitFork(_ transaction: SessionForkPersistenceTransaction) async throws {
        if remainingForkFailures > 0 {
            remainingForkFailures -= 1
            throw AgentError.persistenceFailure("Injected fork target creation failure")
        }
        try await base.commitFork(transaction)
    }

    func commit(_ transaction: SessionPersistenceTransaction) async throws {
        try await base.commit(transaction)
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

    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? {
        try await base.loadSnapshot(sessionID: sessionID)
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

@Test
func sessionJournalRecordsLifecycleForSuccessfulToolRun() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "listing",
            toolCalls: [
                ToolCall(id: "call-1", name: "files.list", arguments: ["path": ""])
            ]
        ),
        ModelTurn(content: "done")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [FilesToolPack(rootURL: tempRoot.appendingPathComponent("user-files", isDirectory: true))]
    )

    let snapshot = try await coordinator.startSession(userPrompt: "list files")
    let events = try await store.loadEvents(sessionID: snapshot.sessionID)

    #expect(events.map(\.kind) == [
        .sessionCreated,
        .snapshotSaved,
        .assistantTurnAppended,
        .snapshotSaved,
        .toolResultAppended,
        .snapshotSaved,
        .assistantTurnAppended,
        .snapshotSaved,
        .sessionCompleted,
        .snapshotSaved
    ])
    #expect(snapshotSaveReasons(events) == [
        "session_created",
        "assistant_turn_appended",
        "tool_result_appended",
        "assistant_turn_appended",
        "session_completed"
    ])

    let toolResultEvent = try #require(events.first(where: { $0.kind == .toolResultAppended }))
    #expect(toolResultEvent.payload.objectValue?["toolName"]?.stringValue == "files.list")
    #expect(toolResultEvent.payload.objectValue?["artifactCount"]?.intValue == 0)
}

@Test
func sessionJournalRecordsCoordinatorSaveReasonsDuringContinuation() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "first"),
        ModelTurn(content: "second")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let first = try await coordinator.startSession(userPrompt: "one")
    _ = try await coordinator.continueSession(sessionID: first.sessionID, userPrompt: "two")
    let events = try await store.loadEvents(sessionID: first.sessionID)
    let reasons = snapshotSaveReasons(events)

    #expect(reasons.contains("user_prompt_appended"))

    let userPromptIndex = try #require(reasons.firstIndex(of: "user_prompt_appended"))
    let firstCompletionIndex = try #require(reasons.firstIndex(of: "session_completed"))
    #expect(userPromptIndex > firstCompletionIndex)
}

@Test
func completedSessionResumeDoesNotMutateOrInvokeProvider() async throws {
    let tempRoot = makeSessionJournalTempRoot()
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

    let first = try await coordinator.startSession(userPrompt: "one")
    await #expect(throws: AgentError.self) {
        _ = try await coordinator.run(sessionID: first.sessionID)
    }
    let events = try await store.loadEvents(sessionID: first.sessionID)
    let reasons = snapshotSaveReasons(events)

    #expect(first.status == .completed)
    #expect(await provider.callCount() == 1)
    #expect(reasons.contains("status_resumed_to_running") == false)
    #expect(try await coordinator.loadSession(sessionID: first.sessionID) == first)
}

@Test
func sessionJournalRecordsToolErrors() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(
            content: "write",
            toolCalls: [
                ToolCall(id: "call-1", name: "files.writeText", arguments: ["path": "invalid.txt"])
            ]
        ),
        ModelTurn(content: "done")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [FilesToolPack(rootURL: tempRoot.appendingPathComponent("user-files", isDirectory: true))]
    )

    let snapshot = try await coordinator.startSession(userPrompt: "write invalid")
    let events = try await store.loadEvents(sessionID: snapshot.sessionID)

    let toolErrorEvent = try #require(events.first(where: { $0.kind == .toolErrorAppended }))
    #expect(toolErrorEvent.payload.objectValue?["toolName"]?.stringValue == "files.writeText")
    let toolMessageJSON = try #require(toolErrorEvent.payload.objectValue?["message"])
    let toolMessage = try toolMessageJSON.decode(AgentMessage.self)
    #expect(toolMessage.metadata["isError"]?.boolValue == true)
    #expect(snapshotSaveReasons(events).contains("tool_error_appended"))
}

@Test
func sessionJournalRecordsWaitOnUnknownModelError() async throws {
    enum ExpectedFailure: Error {
        case boom
    }

    struct FailingProvider: ModelClient {
        let providerID = "provider.fail"

        func generate(request: ModelRequest) async throws -> ModelTurn {
            throw ExpectedFailure.boom
        }
    }

    let tempRoot = makeSessionJournalTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let coordinator = try SessionCoordinator(
        modelClient: FailingProvider(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        idGenerator: { "failed-session" }
    )

    await #expect(throws: ModelGenerationFailure.self) {
        _ = try await coordinator.startSession(userPrompt: "fail")
    }

    let events = try await store.loadEvents(sessionID: "failed-session")
    #expect(events.map(\.kind) == [
        .sessionCreated,
        .snapshotSaved,
        .waitEntered,
        .snapshotSaved
    ])
    #expect(snapshotSaveReasons(events) == [
        "session_created",
        "wait_entered"
    ])
    #expect(events.contains(where: { $0.kind == .sessionFailed }) == false)
    let waitEvent = try #require(events.first(where: { $0.kind == .waitEntered }))
    #expect(waitEvent.payload.objectValue?["kind"]?.stringValue == SessionWaitKind.modelInvocation.rawValue)
}

@Test
func sessionJournalRejectsUnencodablePayloadInsteadOfWritingNull() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    try await store.prepare()
    let journal = SessionJournal(
        now: { Date(timeIntervalSince1970: 1) },
        idGenerator: { "event-invalid-json" }
    )
    let message = AgentMessage(
        role: .assistant,
        content: "invalid JSON",
        metadata: ["notFinite": .number(.nan)]
    )

    #expect(throws: (any Error).self) {
        _ = try journal.events(
            for: [.assistantTurn(message)],
            snapshot: SessionSnapshot(sessionID: "session-invalid-json")
        )
    }
    let events = try await store.loadEvents(sessionID: "session-invalid-json")
    #expect(events.isEmpty)
}

@Test
func snapshotWriterRejectsStateChangeWithoutExplicitMutationReason() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    try await store.prepare()
    let snapshot = SessionSnapshot(sessionID: "missing-effect-session")
    let writer = RuntimeSnapshotWriter(
        journal: SessionJournal(
            now: { Date(timeIntervalSince1970: 1) },
            idGenerator: { "missing-effect-event" }
        ),
        transactionalStore: store
    )
    let reduction = SessionReduction(snapshot: snapshot, mutationReason: nil)

    await #expect(throws: AgentError.self) {
        _ = try await writer.persist(reduction)
    }
    #expect(try await store.loadSnapshot(sessionID: snapshot.sessionID) == nil)
}

@Test
func forkRejectsInvalidTargetBeforeRecordingSourceIntent() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_100_200)
    let source = SessionSnapshot(
        sessionID: "fork-source-invalid",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "fork-source-message",
                role: .user,
                content: "go",
                createdAt: timestamp
            )
        ]
    )
    try await store.createSession(source, events: [], effects: [])
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
        _ = try await coordinator.forkCommand(
            sessionID: source.sessionID,
            throughMessageIndex: 1,
            newSessionID: "fork-invalid-title",
            identity: .init(
                operationID: "fork-invalid-title",
                expectedRevision: source.revision
            ),
            title: "12345",
            metadata: [:]
        )
    }

    #expect(try await store.loadSnapshot(sessionID: source.sessionID) == source)
    #expect(try await store.loadSnapshot(sessionID: "fork-invalid-title") == nil)
    #expect(try await store.loadEvents(sessionID: source.sessionID).isEmpty)
}

@Test
func forkUsesWriterValidationAndStandardCreationJournalWithReloadIdempotency() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_100_300)
    let source = SessionSnapshot(
        sessionID: "fork-source-valid",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "fork-source-message-valid",
                role: .user,
                content: "go",
                createdAt: timestamp
            )
        ]
    )
    try await store.createSession(source, events: [], effects: [])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )
    let identity = AgentCommandIdentity(
        operationID: "fork-valid",
        expectedRevision: source.revision
    )

    let receipt = try await coordinator.forkCommand(
        sessionID: source.sessionID,
        throughMessageIndex: 1,
        newSessionID: "fork-target-valid",
        identity: identity,
        title: "Fork",
        metadata: ["branch": .string("isolated")]
    )
    let target = try #require(try await store.loadSnapshot(sessionID: receipt.sessionID))
    let events = try await store.loadEvents(sessionID: target.sessionID)

    #expect(receipt.revision == target.revision)
    #expect(events.map(\.kind) == [.sessionCreated, "session.forked", .snapshotSaved])
    let forkedEvent = try #require(events.first(where: { $0.kind.rawValue == "session.forked" }))
    #expect(
        forkedEvent.payload.objectValue?["sourceSessionID"]?.stringValue == source.sessionID
    )
    #expect(snapshotSaveReasons(events) == ["session_created"])

    let reloaded = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )
    let duplicate = try await reloaded.forkCommand(
        sessionID: source.sessionID,
        throughMessageIndex: 1,
        newSessionID: target.sessionID,
        identity: identity,
        title: "Fork",
        metadata: ["branch": .string("isolated")]
    )

    #expect(duplicate == receipt)
    #expect(try await store.loadEvents(sessionID: target.sessionID).count == events.count)
    #expect(try await store.loadSnapshot(sessionID: source.sessionID)?.revision == 1)
}

@Test
func completedSourceCanBeForkedWithoutReplacingItsMessages() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_100_400)
    let source = SessionSnapshot(
        sessionID: "fork-source-completed",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "fork-completed-message",
                role: .user,
                content: "done",
                createdAt: timestamp
            )
        ]
    )
    let completed = try SessionReducer.reduce(
        .complete(updatedAt: timestamp.addingTimeInterval(1)),
        state: source
    ).snapshot
    try await store.createSession(completed, events: [], effects: [])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let receipt = try await coordinator.forkCommand(
        sessionID: completed.sessionID,
        throughMessageIndex: completed.messages.count,
        newSessionID: "fork-target-completed",
        identity: .init(
            operationID: "fork-completed",
            expectedRevision: completed.revision
        ),
        title: nil,
        metadata: [:]
    )
    let target = try #require(try await store.loadSnapshot(sessionID: receipt.sessionID))
    let persistedSource = try #require(try await store.loadSnapshot(sessionID: completed.sessionID))

    #expect(target.messages.map(\.content) == completed.messages.map(\.content))
    #expect(persistedSource.status == .completed)
    #expect(persistedSource.revision == completed.revision + 1)
    #expect(persistedSource.messages == completed.messages)
}

@Test
func forkRetryRejectsSourceMutationAfterTargetCreationFailure() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = ForkTargetCreateFailureStore(base: base, createFailures: 1)
    let timestamp = Date(timeIntervalSince1970: 1_726_100_500)
    let source = SessionSnapshot(
        sessionID: "fork-source-retry",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "fork-retry-message",
                role: .user,
                content: "original",
                createdAt: timestamp
            )
        ]
    )
    try await base.createSession(source, events: [], effects: [])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        executionClaimStore: base,
        toolPacks: []
    )
    let identity = AgentCommandIdentity(
        operationID: "fork-retry",
        expectedRevision: source.revision
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.forkCommand(
            sessionID: source.sessionID,
            throughMessageIndex: source.messages.count,
            newSessionID: "fork-target-retry",
            identity: identity,
            title: "Retry",
            metadata: [:]
        )
    }

    let intentSnapshot = try #require(try await base.loadSnapshot(sessionID: source.sessionID))
    _ = try await coordinator.queueCommand(
        sessionID: source.sessionID,
        input: "mutated after intent",
        identity: .init(
            operationID: "mutate-after-fork-intent",
            expectedRevision: intentSnapshot.revision
        ),
        metadata: [:]
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.forkCommand(
            sessionID: source.sessionID,
            throughMessageIndex: source.messages.count,
            newSessionID: "fork-target-retry",
            identity: identity,
            title: "Retry",
            metadata: [:]
        )
    }

    #expect(try await base.loadSnapshot(sessionID: "fork-target-retry") == nil)
    let mutatedSource = try #require(try await base.loadSnapshot(sessionID: source.sessionID))
    #expect(mutatedSource.messages.last?.content == "mutated after intent")
}

@Test
func forkRetryAfterTargetCreationFailureUsesOneDurableTargetEventSequence() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let base = ApplicationSupportSessionStore(rootURL: tempRoot)
    let store = ForkTargetCreateFailureStore(base: base, createFailures: 1)
    let timestamp = Date(timeIntervalSince1970: 1_726_100_600)
    let source = SessionSnapshot(
        sessionID: "fork-source-retry-success",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "fork-retry-success-message",
                role: .user,
                content: "original",
                createdAt: timestamp
            )
        ]
    )
    try await base.createSession(source, events: [], effects: [])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        executionClaimStore: base,
        toolPacks: []
    )
    let identity = AgentCommandIdentity(
        operationID: "fork-retry-success",
        expectedRevision: source.revision
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.forkCommand(
            sessionID: source.sessionID,
            throughMessageIndex: source.messages.count,
            newSessionID: "fork-target-retry-success",
            identity: identity,
            title: "Retry",
            metadata: ["branch": .string("isolated")]
        )
    }

    let sourceAfterFailure = try #require(try await base.loadSnapshot(sessionID: source.sessionID))
    let receipt = try await coordinator.forkCommand(
        sessionID: source.sessionID,
        throughMessageIndex: source.messages.count,
        newSessionID: "fork-target-retry-success",
        identity: identity,
        title: "Retry",
        metadata: ["branch": .string("isolated")]
    )
    let target = try #require(try await base.loadSnapshot(sessionID: receipt.sessionID))
    let targetEvents = try await base.loadEvents(sessionID: target.sessionID)
    let persistedSource = try #require(try await base.loadSnapshot(sessionID: source.sessionID))
    let intent = try #require(
        persistedSource.metadata["native-agent.command.forkIntents"]?
            .objectValue?[identity.operationID]
    )

    #expect(targetEvents.map(\.kind) == [.sessionCreated, "session.forked", .snapshotSaved])
    #expect(targetEvents.count == 3)
    #expect(
        target.metadata["native-agent.command.fork"] == .object([
            "operationID": .string(identity.operationID),
            "sourceSessionID": .string(source.sessionID),
            "throughMessageIndex": .integer(Int64(source.messages.count)),
            "intent": intent,
        ])
    )
    #expect(sourceAfterFailure == source)
    #expect(persistedSource.revision == source.revision + 1)
    #expect(persistedSource.messages == source.messages)
    #expect(receipt.revision == target.revision)
}

@Test
func incompleteForkIntentWithoutSourceRevisionFailsClosedWithoutMutation() async throws {
    let tempRoot = makeSessionJournalTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let timestamp = Date(timeIntervalSince1970: 1_726_100_700)
    let operationID = "incomplete-fork"
    let source = SessionSnapshot(
        revision: 1,
        sessionID: "fork-source-incomplete",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "fork-incomplete-message",
                role: .user,
                content: "incomplete",
                createdAt: timestamp
            )
        ],
        metadata: [
            "native-agent.command.operations": .object([
                operationID: .integer(0)
            ]),
            "native-agent.command.forkIntents": .object([
                operationID: .object([
                    "newSessionID": .string("fork-target-incomplete"),
                    "throughMessageIndex": .integer(1),
                    "title": .string("Incomplete"),
                    "metadata": .object(["branch": .string("incomplete")]),
                ])
            ])
        ]
    )
    try await store.createSession(source, events: [], effects: [])
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.forkCommand(
            sessionID: source.sessionID,
            throughMessageIndex: 1,
            newSessionID: "fork-target-incomplete",
            identity: .init(operationID: operationID, expectedRevision: 0),
            title: "Incomplete",
            metadata: ["branch": .string("incomplete")]
        )
    }

    #expect(try await store.loadSnapshot(sessionID: source.sessionID) == source)
    #expect(try await store.loadSnapshot(sessionID: "fork-target-incomplete") == nil)
    #expect(try await store.loadEvents(sessionID: source.sessionID).isEmpty)
}
