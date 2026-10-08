import Foundation
import Testing

@testable import NativeAgentMemoryProjection

@Test
func transcriptSyncIsIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-sync-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let sourceSession = "session-a"
    let messages = [
        AgentMemoryIncomingMessage(id: "user", role: "user", content: "user evidence", occurredAtMS: 1, sourceIndex: 0, rawContentHash: "u")
    ]
    let journal = AgentMemoryJournalState(messageCount: messages.count, revision: 1)
    let plan = try await engine.syncPlan(scope: scope, sessionID: sourceSession, journal: journal, lastMessage: nil)
    #expect(plan.offset == 0)
    let first = try await engine.applySyncPage(
        scope: scope,
        sessionID: sourceSession,
        journal: journal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: messages.count, messages: messages),
        expectedOffset: 0
    )
    #expect(first.insertedEvents == 1)

    let last = messages[0]
    let replayPlan = try await engine.syncPlan(
        scope: scope,
        sessionID: sourceSession,
        journal: journal,
        lastMessage: last
    )
    #expect(replayPlan.noOp)
    try await engine.close()
}

@Test
func transcriptSyncExcludesSystemEventsAndRetainsToolEvidence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-sync-filter-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let messages = [
        AgentMemoryIncomingMessage(id: "system", role: "system", content: "hidden system", occurredAtMS: 1, sourceIndex: 0, rawContentHash: "s"),
        AgentMemoryIncomingMessage(id: "user", role: "user", content: "user evidence", occurredAtMS: 2, sourceIndex: 1, rawContentHash: "u"),
        AgentMemoryIncomingMessage(id: "tool", role: "tool", content: "tool evidence", occurredAtMS: 3, toolName: "search", sourceIndex: 2, rawContentHash: "t")
    ]
    let journal = AgentMemoryJournalState(messageCount: messages.count, revision: 1)
    let first = try await engine.applySyncPage(
        scope: scope,
        sessionID: "session-a",
        journal: journal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: messages.count, messages: messages),
        expectedOffset: 0
    )
    #expect(first.insertedEvents == 2)

    let eventHits = try await engine.search(
        scope: AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared", sessionKey: "other"),
        query: ProjectionSearchQuery(query: "tool", kinds: [], fromMS: nil, toMS: nil, historical: false, limit: 8)
    )
    #expect(eventHits.count == 1)
    #expect(eventHits[0].role == "tool")
    #expect(eventHits[0].sourceSessionID == "session-a")
    try await engine.close()
}

@Test
func forkReplayOfTheSameSourceMessageDoesNotDuplicateGlobalMemory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-fork-replay-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let source = AgentMemoryIncomingMessage(
        id: "shared-message",
        role: "user",
        content: "forked durable evidence",
        occurredAtMS: 1,
        sourceIndex: 0,
        rawContentHash: "same"
    )
    let journal = AgentMemoryJournalState(messageCount: 1, revision: 1)
    let first = try await engine.applySyncPage(
        scope: scope,
        sessionID: "session-a",
        journal: journal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: 1, messages: [source]),
        expectedOffset: 0
    )
    let fork = try await engine.applySyncPage(
        scope: scope,
        sessionID: "session-b",
        journal: journal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: 1, messages: [source]),
        expectedOffset: 0
    )

    #expect(first.insertedEvents == 1)
    #expect(fork.insertedEvents == 0)
    let matches = try await engine.search(
        scope: scope,
        query: ProjectionSearchQuery(
            query: "forked",
            kinds: [],
            fromMS: nil,
            toMS: nil,
            historical: false,
            limit: 8
        )
    )
    #expect(matches.count == 1)
    #expect(matches[0].sourceSessionID == "session-a")
    try await engine.close()
}

@Test
func transcriptRewriteIsRejectedAtTheOriginalPosition() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-rewrite-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()
    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let original = [
        AgentMemoryIncomingMessage(id: "one", role: "user", content: "one", occurredAtMS: 1, sourceIndex: 0, rawContentHash: "one"),
        AgentMemoryIncomingMessage(id: "two", role: "user", content: "two", occurredAtMS: 2, sourceIndex: 1, rawContentHash: "two")
    ]
    let journal = AgentMemoryJournalState(messageCount: 2, revision: 1)
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: "session",
        journal: journal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: 2, messages: original),
        expectedOffset: 0
    )
    let changed = [
        AgentMemoryIncomingMessage(id: "one", role: "user", content: "rewritten", occurredAtMS: 1, sourceIndex: 0, rawContentHash: "changed"),
        original[1]
    ]
    let changedJournal = AgentMemoryJournalState(messageCount: 2, revision: 2)
    do {
        _ = try await engine.syncPlan(
            scope: scope,
            sessionID: "session",
            journal: changedJournal,
            lastMessage: original[1]
        )
        _ = try await engine.applySyncPage(
            scope: scope,
            sessionID: "session",
            journal: changedJournal,
            page: AgentMemoryIncomingPage(offset: 0, totalCount: 2, messages: changed),
            expectedOffset: 0
        )
        Issue.record("expected transcript rewrite to be rejected")
    } catch let error as AgentMemoryError {
        #expect(error.code == "transcript_rewrite")
    }

    do {
        _ = try await engine.syncPlan(
            scope: scope,
            sessionID: "session",
            journal: AgentMemoryJournalState(messageCount: 1, revision: 3),
            lastMessage: original[0]
        )
        Issue.record("expected transcript truncation to be rejected")
    } catch let error as AgentMemoryError {
        #expect(error.code == "transcript_truncated")
    }
    try await engine.close()
}

@Test
func revisionReplayDoesNotRegressCheckpointBetweenPages() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-revision-replay-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let sessionID = "session"
    let messages = (0..<150).map { index in
        AgentMemoryIncomingMessage(
            id: "m-\(index)",
            role: "user",
            content: "message \(index)",
            occurredAtMS: Int64(index + 1),
            sourceIndex: index,
            rawContentHash: "raw-\(index)"
        )
    }
    let initialJournal = AgentMemoryJournalState(messageCount: messages.count, revision: 1)
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: initialJournal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: messages.count, messages: Array(messages[..<100])),
        expectedOffset: 0
    )
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: initialJournal,
        page: AgentMemoryIncomingPage(offset: 100, totalCount: messages.count, messages: Array(messages[100...])),
        expectedOffset: 100
    )
    #expect(try await engine.checkpointMessageCount(scope: scope, sessionID: sessionID) == 150)

    let replayJournal = AgentMemoryJournalState(messageCount: messages.count, revision: 2)
    let replayPlan = try await engine.syncPlan(
        scope: scope,
        sessionID: sessionID,
        journal: replayJournal,
        lastMessage: messages.last
    )
    #expect(replayPlan.offset == 0)
    #expect(replayPlan.noOp == false)

    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: replayJournal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: messages.count, messages: Array(messages[..<100])),
        expectedOffset: 0
    )
    #expect(try await engine.checkpointMessageCount(scope: scope, sessionID: sessionID) == 150)

    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: replayJournal,
        page: AgentMemoryIncomingPage(offset: 100, totalCount: messages.count, messages: Array(messages[100...])),
        expectedOffset: 100
    )
    let settled = try await engine.syncPlan(
        scope: scope,
        sessionID: sessionID,
        journal: replayJournal,
        lastMessage: messages.last
    )
    #expect(settled.noOp)
    try await engine.close()
}

@Test
func revisionReplayRejectsReorderedStableMessageIDs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-reorder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let sessionID = "session"
    let first = AgentMemoryIncomingMessage(id: "one", role: "user", content: "one", occurredAtMS: 1, sourceIndex: 0, rawContentHash: "one")
    let second = AgentMemoryIncomingMessage(id: "two", role: "user", content: "two", occurredAtMS: 2, sourceIndex: 1, rawContentHash: "two")
    let third = AgentMemoryIncomingMessage(id: "three", role: "user", content: "three", occurredAtMS: 3, sourceIndex: 2, rawContentHash: "three")
    let original = [first, second, third]
    let initialJournal = AgentMemoryJournalState(messageCount: original.count, revision: 1)
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: initialJournal,
        page: AgentMemoryIncomingPage(offset: 0, totalCount: original.count, messages: original),
        expectedOffset: 0
    )

    let replayJournal = AgentMemoryJournalState(messageCount: original.count, revision: 2)
    _ = try await engine.syncPlan(
        scope: scope,
        sessionID: sessionID,
        journal: replayJournal,
        lastMessage: third
    )
    let reordered = [
        AgentMemoryIncomingMessage(id: "two", role: "user", content: "two", occurredAtMS: 2, sourceIndex: 0, rawContentHash: "two"),
        AgentMemoryIncomingMessage(id: "one", role: "user", content: "one", occurredAtMS: 1, sourceIndex: 1, rawContentHash: "one"),
        third,
    ]
    do {
        _ = try await engine.applySyncPage(
            scope: scope,
            sessionID: sessionID,
            journal: replayJournal,
            page: AgentMemoryIncomingPage(offset: 0, totalCount: reordered.count, messages: reordered),
            expectedOffset: 0
        )
        Issue.record("expected reordered transcript to be rejected")
    } catch let error as AgentMemoryError {
        #expect(error.code == "transcript_rewrite")
    }
    try await engine.close()
}

@Test
func staleSyncPageCannotOverwriteAnAdvancedCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-stale-page-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let sessionID = "session"
    let first = AgentMemoryIncomingMessage(id: "one", role: "user", content: "one", occurredAtMS: 1, sourceIndex: 0, rawContentHash: "one")
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: AgentMemoryJournalState(messageCount: 1, revision: 1),
        page: AgentMemoryIncomingPage(offset: 0, totalCount: 1, messages: [first]),
        expectedOffset: 0
    )

    let second = AgentMemoryIncomingMessage(id: "two", role: "user", content: "two", occurredAtMS: 2, sourceIndex: 1, rawContentHash: "two")
    let target = AgentMemoryJournalState(messageCount: 2, revision: 2)
    let page = AgentMemoryIncomingPage(offset: 1, totalCount: 2, messages: [second])
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: target,
        page: page,
        expectedOffset: 1
    )

    do {
        _ = try await engine.applySyncPage(
            scope: scope,
            sessionID: sessionID,
            journal: target,
            page: page,
            expectedOffset: 1
        )
        Issue.record("expected stale sync page to be rejected")
    } catch let error as AgentMemoryError {
        #expect(error.code == "stale_sync_result")
    }
    #expect(try await engine.checkpointMessageCount(scope: scope, sessionID: sessionID) == 2)
    try await engine.close()
}

@Test
func transcriptPageEndOverflowIsRejectedBeforeDatabaseMutation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-page-overflow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let offset = Int.max - 50
    let messages = (0..<100).map { index in
        AgentMemoryIncomingMessage(
            id: "overflow-\(index)",
            role: "user",
            content: "message \(index)",
            occurredAtMS: Int64(index + 1),
            sourceIndex: index,
            rawContentHash: "overflow-\(index)"
        )
    }
    let journal = AgentMemoryJournalState(messageCount: Int.max, revision: 1)

    do {
        _ = try await engine.applySyncPage(
            scope: scope,
            sessionID: "session",
            journal: journal,
            page: AgentMemoryIncomingPage(
                offset: offset,
                totalCount: Int.max,
                messages: messages
            ),
            expectedOffset: offset
        )
        Issue.record("expected overflowing transcript page end to be rejected")
    } catch let error as AgentMemoryError {
        #expect(error.code == "invalid_transcript_page")
    }
    try await engine.close()
}


private struct ImmediateMemoryProvider: AgentMemoryLLMProvider {
    let content: String

    func generate(_ request: AgentMemoryGenerateRequest) async throws -> AgentMemoryGenerateResponse {
        // Guard the production prompt contract: real providers cannot infer a private v1 schema.
        for field in ["closed_through_event_id", "local_id", "slot_key", "valid_from_ms", "event_id", "quote", "relations"] {
            #expect(request.system.contains(field) == true)
        }
        return AgentMemoryGenerateResponse(content: content)
    }
}

private actor BlockingMemoryProvider: AgentMemoryLLMProvider {
    let content: String
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(content: String) {
        self.content = content
    }

    func generate(_ request: AgentMemoryGenerateRequest) async throws -> AgentMemoryGenerateResponse {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return AgentMemoryGenerateResponse(content: content)
    }

    func waitUntilStarted() async {
        while started == false {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test
func staleConsolidationResultCannotOverwriteAnAdvancedCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-stale-consolidation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()

    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let sessionID = "session"
    let message = AgentMemoryIncomingMessage(
        id: "one",
        role: "user",
        content: "durable evidence",
        occurredAtMS: 1,
        sourceIndex: 0,
        rawContentHash: "one"
    )
    _ = try await engine.applySyncPage(
        scope: scope,
        sessionID: sessionID,
        journal: AgentMemoryJournalState(messageCount: 1, revision: 1),
        page: AgentMemoryIncomingPage(offset: 0, totalCount: 1, messages: [message]),
        expectedOffset: 0
    )
    let hits = try await engine.search(
        scope: scope,
        query: ProjectionSearchQuery(
            query: "durable",
            kinds: [],
            fromMS: nil,
            toMS: nil,
            historical: false,
            limit: 8
        )
    )
    let eventID = try #require(hits.first?.id)
    let output = "{\"closed_through_event_id\":\"\(eventID)\",\"records\":[],\"relations\":[]}"

    let blocked = BlockingMemoryProvider(content: output)
    let staleTask = Task {
        try await engine.consolidate(scope: scope, sessionID: sessionID, provider: blocked)
    }
    await blocked.waitUntilStarted()

    let authoritative = try await engine.consolidate(
        scope: scope,
        sessionID: sessionID,
        provider: ImmediateMemoryProvider(content: output)
    )
    #expect(authoritative.closedThroughEventID == eventID)

    await blocked.release()
    do {
        _ = try await staleTask.value
        Issue.record("expected stale consolidation result to be rejected")
    } catch let error as AgentMemoryError {
        #expect(error.code == "stale_consolidation_result")
        #expect(error.operation == "memory.consolidate.apply")
        #expect(error.context["sessionID"] == sessionID)
    }
    try await engine.close()
}
