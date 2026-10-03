import NativeAgentDomain
import NativeAgent
import Foundation
import Testing

@testable import NativeAgentMemory

private enum TranscriptFixtureError: Error {
    case fetch
}

private struct FixedTranscript: MemoryTranscriptSource {
    let sourceSessionID: String
    let storedMessages: [AgentMessage]
    let revision: Int64
    let failJournal: Bool

    init(
        sessionID: String,
        messages: [AgentMessage],
        revision: Int64 = 1,
        failJournal: Bool = false
    ) {
        self.sourceSessionID = sessionID
        self.storedMessages = messages
        self.revision = revision
        self.failJournal = failJournal
    }

    func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        guard !failJournal else { throw TranscriptFixtureError.fetch }
        return try AgentJournalRecord(
            sessionID: sourceSessionID,
            revision: revision,
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 10),
            messageCount: storedMessages.count,
            artifactCount: 0
        )
    }

    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage {
        guard sessionID == sourceSessionID, offset >= 0, offset <= storedMessages.count else {
            throw TranscriptFixtureError.fetch
        }
        return SessionMessagePage(
            sessionID: sourceSessionID,
            offset: offset,
            totalCount: storedMessages.count,
            messages: Array(storedMessages.dropFirst(offset).prefix(limit))
        )
    }
}

private struct BlockingTranscript: MemoryTranscriptSource {
    func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        try await Task.sleep(for: .seconds(30))
        return try AgentJournalRecord(
            sessionID: sessionID,
            revision: 1,
            status: .running,
            updatedAt: Date(),
            messageCount: 0,
            artifactCount: 0
        )
    }

    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage {
        throw TranscriptFixtureError.fetch
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct RecordingModelClient: ModelClient {
    let providerID: String
    let modelDescriptor: ModelDescriptor?
    let counter: InvocationCounter
    let response: ModelTurn
    let scriptedEvents: [ModelEvent]
    let failure: (any Error)?

    func generate(request: ModelRequest) async throws -> ModelTurn {
        counter.increment()
        if let failure { throw failure }
        return response
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in scriptedEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private struct RequestEchoModelClient: ModelClient {
    let providerID = "provider.echo"

    func generate(request: ModelRequest) async throws -> ModelTurn {
        ModelTurn(content: request.messages.map(\.content).joined(separator: "\n"))
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct StaticMemoryProvider: MemoryConsolidationProvider {
    let text: String

    func generateMemoryText(
        system: String,
        messages: [MemoryGenerationMessage]
    ) async throws -> String {
        text
    }
}

private func testRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-public-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private func message(
    _ id: String,
    _ role: AgentMessage.Role,
    _ content: String,
    _ seconds: TimeInterval,
    metadata: [String: JSONValue] = [:],
    toolName: String? = nil
) -> AgentMessage {
    AgentMessage(
        id: id,
        role: role,
        content: content,
        createdAt: Date(timeIntervalSince1970: seconds),
        toolName: toolName,
        metadata: metadata
    )
}

@Test
func publicCaptureFiltersSystemAndHiddenButKeepsToolEvidence() async throws {
    let root = testRoot("capture")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(
            dataDirectory: root,
            defaultProfileID: "profile",
            defaultUserID: "user",
            namespace: "shared"
        )
    )
    let scope = MemoryScope(profileID: "profile", userID: "user", sessionKey: "s1", namespace: "shared")
    let result = try await controller.capture(
        scope: scope,
        messages: [
            message("system", .system, "system-only text", 1),
            message("user", .user, "I prefer durable tea.", 2),
            message("tool", .tool, "tea result", 3, toolName: "lookup"),
            message("hidden", .user, "hidden credential", 4, metadata: ["hidden": .bool(true)])
        ]
    )

    #expect(result.inputMessages == 3)
    #expect(result.insertedMessages == 2)
    let search = try await controller.search(scope: scope, query: "tea")
    #expect(search.matches.contains { $0.role == "user" })
    #expect(search.matches.contains { $0.role == "tool" })
    #expect(search.matches.contains { $0.content.contains("hidden credential") } == false)
    let system = try await controller.search(scope: scope, query: "system-only")
    #expect(system.matches.isEmpty)
}


@Test
func memoryCaptureAdmissionRejectsSensitiveDataMetadata() async throws {
    let root = testRoot("sensitive-admission")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(
            dataDirectory: root,
            defaultProfileID: "profile",
            defaultUserID: "user",
            namespace: "shared"
        )
    )
    let scope = MemoryScope(profileID: "profile", userID: "user", sessionKey: "s1", namespace: "shared")

    let result = try await controller.capture(
        scope: scope,
        messages: [
            message("public", .user, "remember public preference", 1),
            message(
                "sensitive", .tool, "private health result", 2,
                metadata: ["sensitiveData": .bool(true)], toolName: "health.aggregateQuantity"
            ),
        ]
    )

    #expect(result.inputMessages == 2)
    #expect(result.insertedMessages == 1)
    #expect(result.filtered)
    let privateSearch = try await controller.search(scope: scope, query: "private health")
    #expect(privateSearch.matches.isEmpty)
    let publicSearch = try await controller.search(scope: scope, query: "public preference")
    #expect(publicSearch.matches.isEmpty == false)
}

@Test
func transcriptSyncIsIdempotentAndDefaultRecallSpansSessions() async throws {
    let root = testRoot("sync")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(
            dataDirectory: root,
            defaultProfileID: "profile",
            defaultUserID: "user",
            namespace: "shared"
        )
    )
    let first = FixedTranscript(
        sessionID: "session-a",
        messages: [
            message("a-system", .system, "system instruction", 1),
            message("a-user", .user, "alpha durable fact", 2),
            message("a-tool", .tool, "alpha durable tool result", 3, toolName: "lookup")
        ]
    )
    let initial = try await controller.sync(sessionID: "session-a", from: first)
    let replay = try await controller.sync(sessionID: "session-a", from: first)
    #expect(initial.insertedEvents == 2)
    #expect(replay.insertedEvents == 0)
    #expect(replay.scannedMessages == 0)

    let second = FixedTranscript(
        sessionID: "session-b",
        messages: [message("b-user", .user, "beta durable fact", 4)]
    )
    _ = try await controller.sync(sessionID: "session-b", from: second)
    let crossSession = try await controller.search(
        scope: MemoryScope(profileID: "profile", userID: "user", sessionKey: "not-a-filter", namespace: "shared"),
        query: "durable"
    )
    #expect(crossSession.matches.count == 3)
    #expect(Set(crossSession.matches.map(\.sourceSessionID)) == ["session-a", "session-b"])
    let system = try await controller.search(
        scope: MemoryScope(profileID: "profile", userID: "user", namespace: "shared"),
        query: "system instruction"
    )
    #expect(system.matches.isEmpty)
}

@Test
func transcriptFailureDoesNotInvokeProvider() async throws {
    let root = testRoot("failure-boundary")
    defer { try? FileManager.default.removeItem(at: root) }
    let counter = InvocationCounter()
    let base = RecordingModelClient(
        providerID: "provider",
        modelDescriptor: nil,
        counter: counter,
        response: ModelTurn(content: "provider response"),
        scriptedEvents: [],
        failure: nil
    )
    let client = MemoryModelClient(
        base: base,
        memory: MemoryController(
            configuration: MemoryConfiguration(
                dataDirectory: root,
                defaultProfileID: "profile",
                defaultUserID: "user"
            )
        ),
        transcriptSource: FixedTranscript(
            sessionID: "session",
            messages: [],
            failJournal: true
        )
    )
    do {
        _ = try await client.generate(
            request: ModelRequest(
                sessionID: "session",
                messages: [message("request", .user, "invoke provider", 1)],
                tools: []
            )
        )
        Issue.record("expected transcript failure")
    } catch let error as MemoryError {
        #expect(counter.count() == 0)
        #expect(error.operation == "memory.sync.journal")
        #expect(error.cause?.contains("fetch") == true)
        #expect(error.context["sessionID"] == "session")
    }
}

@Test
func modelClientExcludesOnlyTheCurrentUserMessageFromRecall() async throws {
    let root = testRoot("current-message-exclusion")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(
            dataDirectory: root,
            defaultProfileID: "profile",
            defaultUserID: "user",
            namespace: "shared"
        )
    )
    let scope = MemoryScope(profileID: "profile", userID: "user", namespace: "shared")
    let oldMessage = message("old-user", .user, "Always answer with concise code.", 1)
    let initialSource = FixedTranscript(sessionID: "session", messages: [oldMessage])
    _ = try await controller.sync(scope: scope, sessionID: "session", from: initialSource)
    let oldEvent = try #require(
        try await controller.search(scope: scope, query: "concise").matches.first?.id
    )
    let instruction = """
    {"closed_through_event_id":"\(oldEvent)","records":[{"local_id":"r1","kind":"instruction","slot_key":"user.response_style","content":"Answer with concise code.","valid_from_ms":null,"evidence":[{"event_id":"\(oldEvent)","quote":"Always answer with concise code."}]}],"relations":[]}
    """
    _ = try await controller.consolidatePending(
        scope: scope,
        sessionID: "session",
        provider: StaticMemoryProvider(text: instruction)
    )

    let currentMessage = message("current-user", .user, "What should I change?", 2)
    let client = MemoryModelClient(
        base: RequestEchoModelClient(),
        memory: controller,
        transcriptSource: FixedTranscript(
            sessionID: "session",
            messages: [oldMessage, currentMessage],
            revision: 2
        )
    )
    let turn = try await client.generate(
        request: ModelRequest(
            sessionID: "session",
            messages: [oldMessage, currentMessage],
            tools: [],
            metadata: [
                "native-agent.memory.profile_id": .string("profile"),
                "native-agent.memory.user_id": .string("user"),
            ]
        )
    )
    #expect(turn.content.contains("Answer with concise code."))
}

@Test
func modelStreamForwardsEveryBaseEventInOrder() async throws {
    let root = testRoot("stream")
    defer { try? FileManager.default.removeItem(at: root) }
    let events: [ModelEvent] = [
        .started(descriptor: nil),
        .textDelta("one"),
        .reasoningDelta("thinking"),
        .toolCallDelta(id: "call", name: "lookup", argumentsDelta: "{}"),
        .usage(ModelUsage(inputTokens: 1, outputTokens: 2, totalTokens: 3)),
        .completed(ModelTurn(content: "one"))
    ]
    let client = MemoryModelClient(
        base: RecordingModelClient(
            providerID: "provider",
            modelDescriptor: nil,
            counter: InvocationCounter(),
            response: ModelTurn(content: "unused"),
            scriptedEvents: events,
            failure: nil
        ),
        memory: MemoryController(
            configuration: MemoryConfiguration(dataDirectory: root)
        ),
        transcriptSource: FixedTranscript(sessionID: "stream-session", messages: [])
    )
    var observed: [ModelEvent] = []
    for try await event in client.stream(
        request: ModelRequest(
            sessionID: "stream-session",
            messages: [message("stream-user", .user, "stream request", 1)],
            tools: []
        )
    ) {
        observed.append(event)
    }
    #expect(observed == events)
}

@Test
func cancellationStopsTranscriptPreparation() async throws {
    let root = testRoot("cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = MemoryModelClient(
        base: RecordingModelClient(
            providerID: "provider",
            modelDescriptor: nil,
            counter: InvocationCounter(),
            response: ModelTurn(content: "unused"),
            scriptedEvents: [],
            failure: nil
        ),
        memory: MemoryController(
            configuration: MemoryConfiguration(dataDirectory: root)
        ),
        transcriptSource: BlockingTranscript()
    )
    let task = Task {
        try await client.generate(
            request: ModelRequest(
                sessionID: "cancel-session",
                messages: [message("cancel-user", .user, "cancel me", 1)],
                tools: []
            )
        )
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected cancellation")
    } catch {
        #expect(error is CancellationError || (error as? MemoryError) == .cancelled)
    }
}

@Test
func searchHonorsExplicitBounds() async throws {
    let root = testRoot("bounds")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(dataDirectory: root)
    )
    let scope = MemoryScope(profileID: "p", userID: "u", sessionKey: "s", namespace: "n")
    _ = try await controller.capture(
        scope: scope,
        turns: (0..<12).map {
            MemoryTurn(
                id: "bound-\($0)",
                role: .user,
                content: "bounded item \($0)",
                timestampMilliseconds: Int64($0 + 1),
                sessionID: "s"
            )
        }
    )
    let result = try await controller.search(
        scope: scope,
        query: MemorySearchQuery(query: "bounded", limit: 99)
    )
    #expect(result.matches.count <= 8)
    await #expect(throws: (any Error).self) {
        _ = try await controller.search(scope: scope, query: "   ")
    }
}

@Test
func consolidationValidatesEvidenceIsIdempotentAndEvolvesSlots() async throws {
    let root = testRoot("consolidation")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(
            dataDirectory: root,
            defaultProfileID: "profile",
            defaultUserID: "user",
            namespace: "shared"
        )
    )
    let scope = MemoryScope(profileID: "profile", userID: "user", sessionKey: "session-a", namespace: "shared")
    let source = FixedTranscript(
        sessionID: "session-a",
        messages: [
            message("tea", .user, "I prefer tea.", 1),
            message("calm", .assistant, "Tea causes calm mornings.", 2)
        ]
    )
    _ = try await controller.sync(sessionID: "session-a", from: source)
    let teaEvent = try await controller.search(scope: scope, query: "prefer")
    let calmEvent = try await controller.search(scope: scope, query: "calm")
    let teaID = try #require(teaEvent.matches.first?.id)
    let calmID = try #require(calmEvent.matches.first?.id)

    let invalid = """
    {"closed_through_event_id":"\(teaID)","records":[{"local_id":"r1","kind":"fact","slot_key":"preference","content":"I prefer tea.","valid_from_ms":null,"evidence":[{"event_id":"\(teaID)","quote":"not source"}]}],"relations":[]}
    """
    await #expect(throws: (any Error).self) {
        _ = try await controller.consolidatePending(
            scope: scope,
            sessionID: "session-a",
            provider: StaticMemoryProvider(text: invalid)
        )
    }

    let assistantOnlyInstruction = """
    {"closed_through_event_id":"\(calmID)","records":[{"local_id":"r1","kind":"instruction","slot_key":"assistant.only","content":"Invalid assistant instruction.","valid_from_ms":null,"evidence":[{"event_id":"\(calmID)","quote":"Tea causes calm mornings."}]}],"relations":[]}
    """
    await #expect(throws: (any Error).self) {
        _ = try await controller.consolidatePending(
            scope: scope,
            sessionID: "session-a",
            provider: StaticMemoryProvider(text: assistantOnlyInstruction)
        )
    }

    let valid = """
    {"closed_through_event_id":"\(calmID)","records":[{"local_id":"r1","kind":"fact","slot_key":"preference","content":"I prefer tea.","valid_from_ms":null,"evidence":[{"event_id":"\(teaID)","quote":"I prefer tea."}]},{"local_id":"r2","kind":"gotcha","slot_key":null,"content":"Tea causes calm mornings.","valid_from_ms":null,"evidence":[{"event_id":"\(calmID)","quote":"Tea causes calm mornings."}]},{"local_id":"r3","kind":"instruction","slot_key":"tea.default","content":"Choose tea by default.","valid_from_ms":null,"evidence":[{"event_id":"\(teaID)","quote":"I prefer tea."},{"event_id":"\(calmID)","quote":"Tea causes calm mornings."}]}],"relations":[{"from":"r1","relation":"causes","to":"r2"}]}
    """
    let first = try await controller.consolidatePending(
        scope: scope,
        sessionID: "session-a",
        provider: StaticMemoryProvider(text: valid)
    )
    let replay = try await controller.consolidatePending(
        scope: scope,
        sessionID: "session-a",
        provider: StaticMemoryProvider(text: valid)
    )
    #expect(first.insertedRecords == 3)
    #expect(first.insertedRelations == 1)
    #expect(replay.insertedRecords == 0)
    #expect(replay.insertedRelations == 0)

    let evolvedSource = FixedTranscript(
        sessionID: "session-b",
        messages: [message("coffee", .user, "I prefer coffee.", 3)]
    )
    _ = try await controller.sync(sessionID: "session-b", from: evolvedSource)
    let coffeeEvent = try await controller.search(scope: scope, query: "coffee")
    let coffeeID = try #require(coffeeEvent.matches.first?.id)
    let evolved = """
    {"closed_through_event_id":"\(coffeeID)","records":[{"local_id":"r1","kind":"fact","slot_key":"preference","content":"I prefer coffee.","valid_from_ms":null,"evidence":[{"event_id":"\(coffeeID)","quote":"I prefer coffee."}]}],"relations":[]}
    """
    let evolution = try await controller.consolidatePending(
        scope: scope,
        sessionID: "session-b",
        provider: StaticMemoryProvider(text: evolved)
    )
    #expect(evolution.insertedRecords == 1)
    #expect(evolution.insertedRelations == 1)

    let active = try await controller.search(scope: scope, query: MemorySearchQuery(query: "prefer"))
    #expect(active.matches.count == 1)
    #expect(active.matches.first?.content == "I prefer coffee.")
    let historical = try await controller.search(
        scope: scope,
        query: MemorySearchQuery(query: "prefer", historical: true)
    )
    #expect(historical.matches.count == 2)
}

@Test
func memoryToolPackIsReadOnlyAndSearchesTypedResults() async throws {
    let root = testRoot("tool")
    defer { try? FileManager.default.removeItem(at: root) }
    let scope = MemoryScope(profileID: "p", userID: "u", sessionKey: "s", namespace: "n")
    let controller = MemoryController(
        configuration: MemoryConfiguration(dataDirectory: root)
    )
    _ = try await controller.capture(
        scope: scope,
        turns: [MemoryTurn(id: "tool-memory", role: .user, content: "tool searchable memory", timestampMilliseconds: 1)]
    )
    let pack = MemoryToolPack(memory: controller, scope: scope)
    let executor = try #require(pack.executors().first)
    #expect(executor.definition.name == "memory.search")
    #expect(executor.definition.isReadOnly)
    let result = try await executor.execute(
        call: ToolCall(id: "call", name: "memory.search", arguments: ["query": "searchable"]),
        context: ToolExecutionContext(sessionID: "s", sessionDirectoryURL: root, sandboxRootURL: root)
    )
    #expect(result.output.objectValue?["results"]?.arrayValue?.isEmpty == false)
}
