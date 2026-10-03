import Foundation
import NativeAgent
import NativeAgentDomain
import Testing
@testable import NativeAgentMemory

private actor MemoryPause {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            entered = true
            waiting?.resume(); waiting = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

private struct ForgetTranscript: MemoryTranscriptSource {
    let messages: [AgentMessage]
    var revision: Int64 = 1
    var journalPause: MemoryPause? = nil
    var pagePause: MemoryPause? = nil

    func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        if let journalPause { await journalPause.pause() }
        return try AgentJournalRecord(sessionID: sessionID, revision: revision,
            status: .completed, updatedAt: Date(timeIntervalSince1970: 20),
            messageCount: messages.count, artifactCount: 0)
    }
    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage {
        if let pagePause { await pagePause.pause() }
        return SessionMessagePage(sessionID: sessionID, offset: offset, totalCount: messages.count,
            messages: Array(messages.dropFirst(offset).prefix(limit)))
    }
}

private func forgottenMessage(_ id: String, _ text: String) -> AgentMessage {
    AgentMessage(id: id, role: .user, content: text, createdAt: Date(timeIntervalSince1970: 10))
}

private func forgettingErrorCode(_ error: MemoryError) -> String? {
    switch error {
    case .memoryFailure(let code, _), .detailedMemoryFailure(_, let code, _, _, _): return code
    default: return nil
    }
}

@Test func forgettingSurvivesRestartReplayDirectCaptureAndProjectionReset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("forget-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = MemoryConfiguration(dataDirectory: root)
    let controller = MemoryController(configuration: configuration)
    let scope = MemoryScope(profileID: "p", userID: "u", namespace: "n")
    let other = MemoryScope(profileID: "p", userID: "other", namespace: "n")
    let old = forgottenMessage("old", "Remember the cobalt contract amount 48271 won.")
    _ = try await controller.sync(scope: scope, sessionID: "s", from: ForgetTranscript(messages: [old]))
    _ = try await controller.sync(scope: other, sessionID: "s", from: ForgetTranscript(messages: [old]))
    #expect(try await controller.search(scope: scope, query: "cobalt").matches.count == 1)
    try await controller.forget(scope: MemoryScope(profileID: "p", userID: "u", sessionKey: "ignored", namespace: "n"))
    let reopened = MemoryController(configuration: configuration)
    let replay = try await reopened.sync(scope: scope, sessionID: "s", from: ForgetTranscript(messages: [old]))
    #expect(replay.insertedEvents == 0)
    #expect(try await reopened.search(scope: scope, query: "cobalt").matches.isEmpty)
    #expect(try await reopened.search(scope: other, query: "cobalt").matches.count == 1)
    let capture = try await reopened.capture(scope: scope, turns: [MemoryTurn(id: "old", role: .user,
        content: old.content, timestampMilliseconds: 10_000, sessionID: "fork")])
    #expect(capture.insertedMessages == 0)
    try await reopened.delete(scope: scope)
    _ = try await reopened.sync(scope: scope, sessionID: "fork", from: ForgetTranscript(messages: [old]))
    #expect(try await reopened.search(scope: scope, query: "cobalt").matches.isEmpty)
    let fresh = forgottenMessage("new", "Remember the amber contract amount 96542 won.")
    let tail = try await reopened.sync(scope: scope, sessionID: "s", from: ForgetTranscript(messages: [old, fresh], revision: 2))
    #expect(tail.insertedEvents == 1)
    #expect(try await reopened.search(scope: scope, query: "amber").matches.count == 1)
    _ = try await reopened.sync(scope: scope, sessionID: "s", from: ForgetTranscript(messages: [old, fresh], revision: 3))
    #expect(try await reopened.search(scope: scope, query: "cobalt").matches.isEmpty)
    #expect(try await reopened.search(scope: scope, query: "amber").matches.count == 1)
}

@Test func ordinaryDeleteStillAllowsExplicitTranscriptRebuild() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(configuration: MemoryConfiguration(dataDirectory: root))
    let scope = MemoryScope(profileID: "p", userID: "u", namespace: "n")
    let source = ForgetTranscript(messages: [forgottenMessage("reset", "Remember the cobalt contract amount 48271 won.")])
    _ = try await controller.sync(scope: scope, sessionID: "s", from: source)
    try await controller.delete(scope: scope)
    #expect(try await controller.search(scope: scope, query: "cobalt").matches.isEmpty)
    #expect(try await controller.sync(scope: scope, sessionID: "s", from: source).insertedEvents == 1)
}

@Test(arguments: ["journal", "page"], [false, true])
func lateTranscriptCannotCrossForgetOrReset(stage: String, forgetting: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("late-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = MemoryConfiguration(dataDirectory: root)
    let controller = MemoryController(configuration: configuration)
    let otherConnection = MemoryController(configuration: configuration)
    let scope = MemoryScope(profileID: "p", userID: "u", namespace: "n")
    let pause = MemoryPause()
    let old = forgottenMessage("late", "Remember the cobalt contract amount 48271 won.")
    let source = ForgetTranscript(messages: [old], journalPause: stage == "journal" ? pause : nil,
                                  pagePause: stage == "page" ? pause : nil)
    let task = Task { try await controller.sync(scope: scope, sessionID: "s", from: source) }
    await pause.waitForEntry()
    do {
        if forgetting { try await otherConnection.forget(scope: scope) }
        else { try await otherConnection.delete(scope: scope) }
    } catch { await pause.release(); _ = await task.result; throw error }
    await pause.release()
    do { _ = try await task.value; Issue.record("Old source response crossed the scope generation") }
    catch let error as MemoryError { #expect(forgettingErrorCode(error) == "stale_sync_result") }
    #expect(try await controller.search(scope: scope, query: "cobalt").matches.isEmpty)
}

private struct PausedConsolidation: MemoryConsolidationProvider {
    let pause: MemoryPause
    let output: String
    func generateMemoryText(system: String, messages: [MemoryGenerationMessage]) async throws -> String {
        await pause.pause()
        return output
    }
}

@Test(arguments: [false, true])
func consolidationCannotCrossResetABAOrForget(forgetting: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("late-memory-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = MemoryConfiguration(dataDirectory: root)
    let controller = MemoryController(configuration: configuration)
    let otherConnection = MemoryController(configuration: configuration)
    let scope = MemoryScope(profileID: "p", userID: "u", namespace: "n")
    let source = ForgetTranscript(messages: [forgottenMessage("old", "I prefer cobalt notebooks.")])
    _ = try await controller.sync(scope: scope, sessionID: "s", from: source)
    let event = try #require(try await controller.search(scope: scope, query: "cobalt").matches.first)
    let output = """
    {"closed_through_event_id":"\(event.id)","records":[{"local_id":"r","kind":"fact","slot_key":"preference","content":"I prefer cobalt notebooks.","valid_from_ms":null,"evidence":[{"event_id":"\(event.id)","quote":"I prefer cobalt notebooks."}]}],"relations":[]}
    """
    let pause = MemoryPause()
    let task = Task { try await controller.consolidatePending(scope: scope, sessionID: "s",
        provider: PausedConsolidation(pause: pause, output: output)) }
    await pause.waitForEntry()
    do {
        if forgetting { try await otherConnection.forget(scope: scope) }
        else { try await otherConnection.delete(scope: scope) }
        _ = try await otherConnection.sync(scope: scope, sessionID: "s", from: source)
    } catch { await pause.release(); _ = await task.result; throw error }
    await pause.release()
    do { _ = try await task.value; Issue.record("A stale consolidation crossed reset/forget") }
    catch let error as MemoryError { #expect(forgettingErrorCode(error) == "stale_consolidation_result") }
    let matches = try await controller.search(scope: scope, query: "cobalt").matches
    #expect(matches.allSatisfy { $0.layer == "event" })
    if forgetting { #expect(matches.isEmpty) }
}
