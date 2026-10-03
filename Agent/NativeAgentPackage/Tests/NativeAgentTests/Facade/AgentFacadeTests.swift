import Foundation
import Testing
import NativeAgent
import NativeAgentDomain
import NativeAgentExecution
import NativeAgentTestSupport
import NativeAgentStore

@Suite(.serialized)
struct AgentFacadeTests {
    @Test
    func durableQueueRejectsDuplicateAndStaleCommandsAfterReload() async throws {
        let root = temporaryDirectory("durable-command-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AgentStorage.directory(root)
        let first = try Agent(
            model: ScriptedModelClient(scriptedTurns: []),
            storage: storage
        )
        _ = try await first.run("start", sessionID: "command-session")
        let revision = try await first.session(id: "command-session").revision
        _ = try await first.queue(
            "queued",
            to: "command-session",
            identity: .init(operationID: "queue-1", expectedRevision: revision)
        )

        let reloaded = try Agent(
            model: ScriptedModelClient(scriptedTurns: []),
            storage: storage
        )
        await #expect(throws: AgentError.self) {
            _ = try await reloaded.queue(
                "duplicate",
                to: "command-session",
                identity: .init(operationID: "queue-1", expectedRevision: revision)
            )
        }
        await #expect(throws: AgentError.self) {
            _ = try await reloaded.queue(
                "stale",
                to: "command-session",
                identity: .init(operationID: "queue-2", expectedRevision: revision)
            )
        }
    }

    @Test
    func editAndForkCreateIsolatedDurableRevisions() async throws {
        let root = temporaryDirectory("durable-command-edit-fork")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try Agent(
            model: ScriptedModelClient(scriptedTurns: [ModelTurn(content: "done")]),
            storage: .directory(root)
        )
        let started = try await agent.run("original", sessionID: "source-session")
        let original = try #require(started.messages.first(where: { $0.role == .user }))
        let edited = try await agent.edit(
            messageID: original.id,
            replacingWith: "replacement",
            in: "source-session",
            identity: .init(
                operationID: "edit-1",
                expectedRevision: started.snapshot.revision
            )
        )
        let source = try await agent.session(id: "source-session")
        #expect(source.messages.last?.metadata["native-agent.command.editOf"] == .string(original.id))

        _ = try await agent.fork(
            sessionID: "source-session",
            throughMessageIndex: 1,
            newSessionID: "fork-session",
            identity: .init(operationID: "fork-1", expectedRevision: source.revision),
            metadata: ["branch": .string("isolated")]
        )
        let fork = try await agent.session(id: "fork-session")
        #expect(fork.messages.count == 1)
        #expect(fork.artifacts.isEmpty)
        #expect(fork.waitState == nil)
        #expect(fork.metadata["branch"] == .string("isolated"))
        #expect(fork.messages.allSatisfy { $0.toolCalls.isEmpty && $0.toolCallID == nil })
        #expect(edited.revision == source.revision)
        let sourceAfterFork = try await agent.session(id: "source-session")
        await #expect(throws: AgentError.self) {
            _ = try await agent.fork(
                sessionID: "source-session",
                throughMessageIndex: 1,
                newSessionID: "fork-session-duplicate",
                identity: .init(
                    operationID: "fork-1",
                    expectedRevision: sourceAfterFork.revision
                )
            )
        }
    }

    @Test
    func appGroupStorageUsesBuiltInCrossProcessClaimOwnership() async throws {
        let container = temporaryDirectory("app-group-claim")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try AgentStorage.applicationSupport(
            appName: "Example",
            appGroupIdentifier: "group.example.nativeagent",
            appGroupContainerURL: container
        )
        let second = try AgentStorage.applicationSupport(
            appName: "Example",
            appGroupIdentifier: "group.example.nativeagent",
            appGroupContainerURL: container
        )

        let firstClaims = try #require(first.executionClaimStore)
        let secondClaims = try #require(second.executionClaimStore)
        let claim = try await firstClaims.acquireExecutionClaim(sessionID: "shared-session")
        await #expect(throws: AgentError.self) {
            _ = try await secondClaims.acquireExecutionClaim(sessionID: "shared-session")
        }
        try await firstClaims.releaseExecutionClaim(claim)
        let recovered = try await secondClaims.acquireExecutionClaim(sessionID: "shared-session")
        try await secondClaims.releaseExecutionClaim(recovered)

        #expect(throws: AgentError.self) {
            _ = try AgentStorage.applicationSupport(
                appName: "Example",
                appGroupContainerURL: container
            )
        }
    }

    @Test
    func directoryStorageForwardsExplicitExecutionClaimOwnership() async throws {
        let root = temporaryDirectory("directory-claim")
        let claims = AgentFacadeClaimStore()
        let storage = AgentStorage.directory(
            root,
            executionClaimStore: claims
        )

        let storageClaims = try #require(storage.executionClaimStore)
        let claim = try await storageClaims.acquireExecutionClaim(sessionID: "directory-session")
        #expect(await claims.ownsClaim())
        try await storageClaims.releaseExecutionClaim(claim)
        #expect(await claims.ownsClaim() == false)
    }

    @Test
    func storageReadModelQueriesDurableSessionsWithoutAProvider() async throws {
        let root = temporaryDirectory("storage-read-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AgentStorage.directory(root)
        let agent = try Agent(
            model: ScriptedModelClient(scriptedTurns: [ModelTurn(content: "done")]),
            storage: storage
        )

        _ = try await agent.run("hello", sessionID: "storage-read-session", title: "Stored")

        let summaries = try await storage.sessions()
        #expect(summaries.map(\.sessionID) == ["storage-read-session"])
        #expect(try await storage.session(id: "storage-read-session").title == "Stored")
        let state = try await storage.sessionState(id: "storage-read-session")
        #expect(state.summary.title == "Stored")
        #expect(state.summary.messageCount == 2)
        #expect(state.waitState == nil)
        let page = try await storage.messages(sessionID: "storage-read-session")
        #expect(page.totalCount == 2)
        #expect(page.messages.map(\.role) == [.user, .assistant])
        await #expect(throws: AgentError.self) {
            _ = try await storage.sessions(limit: 0)
        }
    }

    @Test
    func structuredOutputReachesModelAcrossSessionContinuation() async throws {
        let root = temporaryDirectory("structured-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let format = ModelOutputFormat.jsonObject(schema: .object([
            "type": "object", "properties": .object(["ok": .object(["type": "boolean"])]),
            "required": .array(["ok"]), "additionalProperties": false]))
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "{\"ok\":true}"), ModelTurn(content: "{\"ok\":false}")])
        let agent = try Agent(model: model, storage: .directory(root),
            configuration: AgentConfiguration(outputFormat: format))
        let first = try await agent.run("Return ok true")
        _ = try await agent.send("Return ok false", to: first.sessionID)
        let requests = await model.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.outputFormat == format })
    }

    @Test
    func typedUserContentSurvivesDurableAgentRun() async throws {
        let root = temporaryDirectory("typed-content")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "described")])
        let agent = try Agent(model: model, storage: .directory(root))

        let result = try await agent.run(contentParts: [
            .text("describe"),
            .image(.init(mimeType: "image/png", data: Data([1, 2, 3]), filename: "image.png")),
        ])

        #expect(result.status == .completed)
        let request = try #require(await model.recordedRequests().first)
        let user = try #require(request.messages.last { $0.role == .user })
        #expect(user.content == "describe")
        #expect(user.contentParts.count == 2)
    }

    @Test
    func typedUserContentUsesRuntimeIdentityTimeAndMetadataOwnership() async throws {
        let root = temporaryDirectory("typed-content-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "first"),
            ModelTurn(content: "second"),
            ModelTurn(content: "third"),
        ])
        let agent = try Agent(model: model, storage: .directory(root))
        let sessionID = "typed-content-session"
        let startedAfter = Date().addingTimeInterval(-1)

        let first = try await agent.run(
            contentParts: [.text("same input")],
            sessionID: sessionID,
            metadata: ["session": .string("owned by session")]
        )
        _ = try await agent.send(
            contentParts: [.text("same input")],
            to: sessionID,
            metadata: ["request": .string("owned by message")]
        )
        let third = try await agent.send(
            contentParts: [.text("same input")],
            to: sessionID,
            metadata: ["request": .string("owned by message")]
        )
        let users = third.messages.filter { $0.role == .user }

        #expect(first.snapshot.metadata["session"] == .string("owned by session"))
        #expect(users.count == 3)
        #expect(Set(users.map(\.id)).count == users.count)
        #expect(users.allSatisfy { $0.createdAt >= startedAfter })
        #expect(users[0].metadata.isEmpty)
        #expect(users[1].metadata["request"] == .string("owned by message"))
        #expect(users[2].metadata["request"] == .string("owned by message"))
    }

    @Test
    func runUsesOneHighLevelFacadeAndReturnsDerivedOutput() async throws {
        let root = temporaryDirectory("simple-run")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "final answer")
        ])
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            instructions: "Answer precisely."
        )

        let result = try await agent.run("question")

        #expect(result.status == .completed)
        #expect(result.output == "final answer")
        #expect(result.sessionID.isEmpty == false)
        #expect(await model.callCount() == 1)

        let request = try #require(await model.recordedRequests().first)
        #expect(request.messages.contains { $0.role == .system && $0.content == "Answer precisely." })
        #expect(request.messages.contains { $0.role == .user && $0.content == "question" })
    }

    @Test
    func automaticContextPolicyUsesDeclaredCapacityAndPreservesDurableHistory() async throws {
        let root = temporaryDirectory("declared-context-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = ModelDescriptor(
            id: "test.long-context",
            providerID: "provider.test.scripted",
            contextWindowTokens: 1_200
        )
        let longText = String(repeating: "abcdefghij", count: 180)
        let model = ScriptedModelClient(
            modelDescriptor: descriptor,
            scriptedTurns: [
                ModelTurn(content: "first \(longText)"),
                ModelTurn(content: "second \(longText)"),
            ]
        )
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            instructions: "Keep the conversation coherent."
        )

        let first = try await agent.run("first \(longText)")
        let second = try await agent.send("second \(longText)", to: first.sessionID)
        let requests = await model.recordedRequests()
        let projectedTokens = try ApproximateTokenEstimator().estimate(
            messages: try #require(requests.last?.messages),
            tools: []
        )

        #expect(second.status == .completed)
        #expect(second.snapshot.contextCheckpoint != nil)
        #expect(second.messages.count == 5)
        #expect(requests.count == 2)
        #expect(requests[1].messages.count < second.messages.count)
        #expect(projectedTokens <= 525) // (1,200 - 150) × automatic 50% target
        #expect(second.messages.contains(where: { $0.content == "first \(longText)" }))
    }

    @Test
    func explicitContextCapacityWorksWithoutProviderDescriptor() async throws {
        let root = temporaryDirectory("explicit-context-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let longText = String(repeating: "abcdefghij", count: 180)
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "first \(longText)"),
            ModelTurn(content: "second \(longText)"),
        ])
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            instructions: "Keep the conversation coherent.",
            configuration: AgentConfiguration(
                contextPolicy: .capacity(
                    AgentContextCapacity(
                        windowTokens: 1_200,
                        reservedOutputTokens: 150
                    )
                )
            )
        )

        let first = try await agent.run("first \(longText)")
        let second = try await agent.send("second \(longText)", to: first.sessionID)
        let requests = await model.recordedRequests()

        #expect(second.status == .completed)
        #expect(second.snapshot.contextCheckpoint != nil)
        #expect(requests.count == 2)
        #expect(requests[1].messages.count < second.messages.count)
    }


    @Test
    func agentRunOutputBelongsToLatestUserTurnOnly() throws {
        let oldUser = AgentMessage(role: .user, content: "first")
        let oldAssistant = AgentMessage(role: .assistant, content: "old answer")
        let currentUser = AgentMessage(role: .user, content: "second")

        let uncertain = AgentRun(snapshot: SessionSnapshot(
            sessionID: "output-uncertain",
            status: .waiting,
            messages: [oldUser, oldAssistant, currentUser],
            waitState: .modelInvocation(
                identifier: "invocation-2",
                providerID: "provider.test",
                snapshotRevision: 2
            )
        ))
        #expect(uncertain.output == nil)

        let failed = AgentRun(snapshot: SessionSnapshot(
            sessionID: "output-failed",
            status: .failed,
            messages: [oldUser, oldAssistant, currentUser]
        ))
        #expect(failed.output == nil)

        let completed = AgentRun(snapshot: SessionSnapshot(
            sessionID: "output-completed",
            status: .completed,
            messages: [
                oldUser, oldAssistant, currentUser,
                AgentMessage(role: .assistant, content: "current answer"),
            ]
        ))
        #expect(completed.output == "current answer")
    }

    @Test
    func sensitiveToolDefinitionPropagatesToDurableToolMessage() async throws {
        let root = temporaryDirectory("sensitive-tool-metadata")
        defer { try? FileManager.default.removeItem(at: root) }

        let call = ToolCall(id: "call-sensitive", name: "app.sensitive", arguments: .object([:]))
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "", toolCalls: [call]),
            ModelTurn(content: "done"),
        ])
        let tool = AgentTool(
            name: "app.sensitive",
            description: "Returns sensitive data.",
            inputSchema: ToolSchema.object(properties: [:]),
            approvalPolicy: .automatic,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        ) { _ in
            .object(["content": .string("private result")])
        }
        let agent = try Agent(model: model, storage: .directory(root), tools: [tool])

        let result = try await agent.run("use sensitive tool")
        let toolMessage = try #require(result.messages.first(where: { $0.role == .tool }))
        #expect(toolMessage.metadata["sensitiveData"] == .bool(true))
    }

    @Test
    func closureToolRunsWithoutApplicationKnowingAboutToolPacksOrCoordinator() async throws {
        let root = temporaryDirectory("tool-run")
        defer { try? FileManager.default.removeItem(at: root) }

        let call = ToolCall(
            id: "call-1",
            name: "app.lookup",
            arguments: .object(["query": .string("swift")])
        )
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "", toolCalls: [call]),
            ModelTurn(content: "tool complete")
        ])
        let counter = InvocationCounter()
        let tool = AgentTool(
            name: "app.lookup",
            description: "Look up an application value.",
            inputSchema: ToolSchema.object(
                properties: ["query": ToolSchema.string()],
                required: ["query"]
            ),
            approvalPolicy: .automatic,
            effect: .readOnly
        ) { arguments in
            await counter.increment()
            return .object([
                "content": .string(arguments.objectValue?["query"]?.stringValue ?? "")
            ])
        }
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            tools: [tool]
        )

        let result = try await agent.run("use the tool")

        #expect(result.status == .completed)
        #expect(result.output == "tool complete")
        #expect(await counter.value() == 1)
        #expect(result.messages.contains { $0.role == .tool && $0.toolCallID == "call-1" })
    }

    @Test
    func publicToolPackCanBeComposedWithoutFlatteningExecutorsInApplicationCode() async throws {
        struct LookupPack: ToolPack {
            let packID = "app.lookup-pack"
            let counter: InvocationCounter

            func executors() -> [any ToolExecutor] {
                [AgentTool(
                    name: "app.packLookup",
                    description: "Look up an application value through a ToolPack.",
                    inputSchema: ToolSchema.object(properties: [:]),
                    approvalPolicy: .automatic,
                    effect: .readOnly
                ) { _ in
                    await counter.increment()
                    return .object(["content": .string("pack-result")])
                }]
            }
        }

        let root = temporaryDirectory("tool-pack-run")
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = InvocationCounter()
        let call = ToolCall(id: "call-pack", name: "app.packLookup", arguments: .object([:]))
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "", toolCalls: [call]),
            ModelTurn(content: "pack complete")
        ])
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            toolPacks: [LookupPack(counter: counter)]
        )

        let result = try await agent.run("use pack")

        #expect(result.status == .completed)
        #expect(result.output == "pack complete")
        #expect(await counter.value() == 1)
        let availableTools = await agent.availableTools()
        #expect(availableTools.first?.effect == .readOnly)
    }

    @Test
    func signalWaitCanBeEnteredAndResumedThroughFacade() async throws {
        let root = temporaryDirectory("signal-wait")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ApplicationSupportSessionStore(rootURL: root)
        let sessionID = "facade-signal-session"
        try await store.createSession(
            SessionSnapshot(
                sessionID: sessionID,
                status: .running,
                messages: [AgentMessage(role: .user, content: "seed")],
                providerID: "provider.test.scripted"
            ),
            events: [],
            effects: []
        )
        let model = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "resumed")])
        let agent = try Agent(
            model: model,
            storage: AgentStorage(runtimePersistence: store)
        )

        let waiting = try await agent.waitForSignal(
            sessionID: sessionID,
            identifier: "sync.ready",
            details: ["source": .string("host")]
        )
        #expect(waiting.status == .waiting)
        #expect(waiting.snapshot.waitState?.kind == .signal)

        let resumed = try await agent.resumeSignalWait(
            sessionID: sessionID,
            identifier: "sync.ready",
            payload: .object(["revision": .integer(7)]),
            userPrompt: "signal received"
        )

        #expect(resumed.status == .completed)
        #expect(resumed.output == "resumed")
        #expect(resumed.snapshot.lastSignal?.identifier == "sync.ready")
        #expect(resumed.snapshot.lastSignal?.payload["revision"]?.intValue == 7)
    }

    @Test
    func timeWaitRemainsClosedUntilDeadlineAndThenResumesThroughFacade() async throws {
        let root = temporaryDirectory("time-wait")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ApplicationSupportSessionStore(rootURL: root)
        let sessionID = "facade-time-session"
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        try await store.createSession(
            SessionSnapshot(
                sessionID: sessionID,
                status: .running,
                messages: [AgentMessage(role: .user, content: "seed")],
                providerID: "provider.test.scripted"
            ),
            events: [],
            effects: []
        )
        let model = ScriptedModelClient(scriptedTurns: [ModelTurn(content: "timer resumed")])
        let agent = try Agent(
            model: model,
            storage: AgentStorage(runtimePersistence: store)
        )

        let waiting = try await agent.waitUntil(
            sessionID: sessionID,
            resumeAt: deadline,
            identifier: "timer.1"
        )
        #expect(waiting.status == .waiting)
        #expect(waiting.snapshot.waitState?.kind == .time)

        do {
            _ = try await agent.resumeTimeWait(
                sessionID: sessionID,
                asOf: deadline.addingTimeInterval(-1)
            )
            Issue.record("Expected an early time-wait resume to remain blocked.")
        } catch let error as AgentError {
            guard case .sessionWaiting(let blockedSessionID) = error else {
                Issue.record("Unexpected AgentError: \(error)")
                return
            }
            #expect(blockedSessionID == sessionID)
        }

        let resumed = try await agent.resumeTimeWait(
            sessionID: sessionID,
            asOf: deadline
        )
        #expect(resumed.status == .completed)
        #expect(resumed.output == "timer resumed")
    }

    @Test
    func approvalDefaultsToFailClosed() async throws {
        let root = temporaryDirectory("deny-by-default")
        defer { try? FileManager.default.removeItem(at: root) }

        let call = ToolCall(
            id: "call-denied",
            name: "app.mutate",
            arguments: .object([:])
        )
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "", toolCalls: [call]),
            ModelTurn(content: "not executed")
        ])
        let counter = InvocationCounter()
        let tool = AgentTool(
            name: "app.mutate",
            description: "Mutate application state.",
            approvalPolicy: .requireApproval
        ) { _ in
            await counter.increment()
            return .object(["content": .string("changed")])
        }
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            tools: [tool]
        )

        let result = try await agent.run("change it")

        #expect(result.status == .completed)
        #expect(await counter.value() == 0)
        #expect(result.messages.contains { message in
            message.role == .tool
                && message.toolCallID == "call-denied"
                && message.metadata["isError"]?.boolValue == true
        })
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-AgentFacade-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor InvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor AgentFacadeClaimStore: SessionExecutionClaimStore {
    private var claim: SessionExecutionClaim?

    func acquireExecutionClaim(sessionID: String) throws -> SessionExecutionClaim {
        guard claim == nil else { throw AgentError.sessionBusy(sessionID) }
        let acquired = SessionExecutionClaim(sessionID: sessionID, claimID: "facade-claim")
        claim = acquired
        return acquired
    }

    func releaseExecutionClaim(_ released: SessionExecutionClaim) throws {
        guard claim == released else {
            throw AgentError.persistenceFailure("Facade claim is not owned.")
        }
        claim = nil
    }

    func ownsClaim() -> Bool { claim != nil }
}

private actor AgentFacadeObserver: RuntimeObserver {
    private var effectDecisions: [ToolEffectDecisionEvent] = []
    private var executionDurations: [ToolExecutionDurationEvent] = []

    func record(effectDecision event: ToolEffectDecisionEvent) async {
        effectDecisions.append(event)
    }

    func record(toolExecutionDuration event: ToolExecutionDurationEvent) async {
        executionDurations.append(event)
    }

    func snapshot() -> (
        decisions: [ToolEffectDecisionEvent],
        durations: [ToolExecutionDurationEvent]
    ) {
        (effectDecisions, executionDurations)
    }
}

@Test
func highLevelFacadeForwardsRuntimeObservationWithoutUIOrCoordinatorWiring() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-AgentFacade-observer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let call = ToolCall(
        id: "call-observed",
        name: "app.observe",
        arguments: .object([:])
    )
    let model = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "", toolCalls: [call]),
        ModelTurn(content: "observed")
    ])
    let observer = AgentFacadeObserver()
    let tool = AgentTool(
        name: "app.observe",
        description: "Record one observed execution.",
        approvalPolicy: .automatic
    ) { _ in
        .object(["content": .string("done")])
    }
    let agent = try Agent(
        model: model,
        storage: .directory(root),
        tools: [tool],
        observer: observer
    )

    let result = try await agent.run("observe the tool")
    let events = await observer.snapshot()

    #expect(result.status == .completed)
    #expect(events.decisions.map(\.decision) == [.execute])
    #expect(events.durations.count == 1)
    #expect(events.durations.first?.succeeded == true)
}

@Test
func durablePresentationProjectionRedactsSecretsAndExcludesExecutableState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-durable-projection-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = AgentStorage.directory(root)
    let agent = try Agent(
        model: ScriptedModelClient(scriptedTurns: [ModelTurn(content: "safe response")]),
        storage: storage
    )

    _ = try await agent.run(
        "Authorization: Bearer should-not-sync",
        sessionID: "projection-session"
    )

    let journal = try await storage.journalRecord(sessionID: "projection-session")
    let projection = try await storage.cloudProjection(sessionID: "projection-session")
    #expect(journal.sessionID == projection.sessionID)
    #expect(journal.revision == projection.revision)
    #expect(projection.messages.first?.text == "[Content omitted from cloud projection]")
    #expect(projection.messages.allSatisfy { !$0.text.contains("should-not-sync") })
}

@Test
func cloudProjectionHydrationIsIdempotentAndRejectsConflictAndUnknownFields() async throws {
    let base = try AgentCloudProjection(
        sessionID: "cloud-session",
        revision: 1,
        title: "Cloud",
        status: .completed,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        providerID: "provider",
        modelID: "model",
        messageCount: 0,
        artifactCount: 0,
        messages: []
    )
    let hydrator = AgentCloudProjectionHydrator()
    #expect(try await hydrator.hydrate(base) == .inserted)
    #expect(try await hydrator.hydrate(base) == .unchanged)

    let conflict = try AgentCloudProjection(
        sessionID: "cloud-session",
        revision: 1,
        title: "Different",
        status: .completed,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        providerID: "provider",
        modelID: "model",
        messageCount: 0,
        artifactCount: 0,
        messages: []
    )
    await #expect(throws: AgentProjectionError.self) {
        _ = try await hydrator.hydrate(conflict)
    }

    let encoded = try JSONEncoder().encode(base)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["unexpected"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: AgentProjectionError.self) {
        _ = try JSONDecoder().decode(AgentCloudProjection.self, from: unknown)
    }
}

@Test
func cloudProjectionHydrationHasBoundedLocalLatencyAcrossFiveHundredSessions() async throws {
    let hydrator = AgentCloudProjectionHydrator()
    let clock = ContinuousClock()
    var samples: [Duration] = []
    samples.reserveCapacity(500)

    for index in 0..<500 {
        let projection = try AgentCloudProjection(
            sessionID: "benchmark-\(index)",
            revision: 1,
            title: nil,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            providerID: nil,
            modelID: nil,
            messageCount: 0,
            artifactCount: 0,
            messages: []
        )
        let started = clock.now
        #expect(try await hydrator.hydrate(projection) == .inserted)
        samples.append(started.duration(to: clock.now))
    }

    let ordered = samples.sorted()
    let p50 = ordered[ordered.count / 2]
    let p95 = ordered[Int(Double(ordered.count - 1) * 0.95)]
    #expect(p50 < .milliseconds(10))
    #expect(p95 < .milliseconds(50))
    #expect(await hydrator.projection(sessionID: "benchmark-499")?.revision == 1)
}

private struct RetryOnceDefiniteModelFailure: ModelClientFailure, EffectFailureClassifying {
    let sessionID: String

    var modelFailureCode: String { "request_rejected" }
    var modelFailureDetails: [String: JSONValue] { ["sessionID": .string(sessionID)] }
    var effectFailureCertainty: EffectFailureCertainty { .definiteFailure }
    var errorDescription: String? { "Model request was rejected before dispatch." }
}

private actor RetryOnceModelClient: ModelClient {
    nonisolated let providerID = "retry-once"
    private var calls = 0

    func generate(request: ModelRequest) async throws -> ModelTurn {
        calls += 1
        if calls == 1 {
            throw RetryOnceDefiniteModelFailure(sessionID: request.sessionID)
        }
        return ModelTurn(content: "retried")
    }
}

@Test
func durableRetryUsesRecoveryAndRejectsReusedOperationIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-durable-retry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = AgentStorage.directory(root)
    let agent = try Agent(model: RetryOnceModelClient(), storage: storage)

    await #expect(throws: RetryOnceDefiniteModelFailure.self) {
        _ = try await agent.run("retry me", sessionID: "retry-session")
    }
    let failed = try await storage.session(id: "retry-session")
    #expect(failed.status == .failed)
    let identity = AgentCommandIdentity(
        operationID: "retry-operation",
        expectedRevision: failed.revision
    )

    let retried = try await agent.retry(sessionID: failed.sessionID, identity: identity)
    #expect(retried.status == .completed)
    #expect(retried.output == "retried")
    await #expect(throws: AgentError.self) {
        _ = try await agent.retry(sessionID: failed.sessionID, identity: identity)
    }
}
