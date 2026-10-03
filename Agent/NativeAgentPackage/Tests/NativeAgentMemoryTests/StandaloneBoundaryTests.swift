import Foundation
import Testing
import NativeAgent
import NativeAgentDomain
import NativeAgentMemory
import LanguageModelRuntime

private struct UnenteredTranscript: MemoryTranscriptSource {
    func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        Issue.record("Memory I/O must not run during rejected durable composition")
        throw CancellationError()
    }
    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage {
        Issue.record("Memory I/O must not run during rejected durable composition")
        throw CancellationError()
    }
}
private struct UnenteredProvider: ModelClient {
    let providerID = "identity.provider"
    var modelDescriptor: ModelDescriptor? {
        ModelDescriptor(id: "model", providerID: providerID, capabilities: .allKnown)
    }
    func generate(request: ModelRequest) async throws -> ModelTurn {
        Issue.record("Provider must not run during rejected durable composition")
        throw CancellationError()
    }
}
@Test func memoryDecoratorCannotEnterDurableRuntimeBeforeAnyIO() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("never-created-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = MemoryModelClient(base: UnenteredProvider(),
        memory: MemoryController(configuration: MemoryConfiguration(dataDirectory: root)),
        transcriptSource: UnenteredTranscript())
    do {
        _ = try ModelRuntime(id: .init(rawValue: "forbidden"), client: client)
        Issue.record("Durable runtime accepted a request-decorating client")
    } catch let error as ModelRuntimeFailure {
        #expect(error.code == .invalidConfiguration)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

// This source deliberately ignores task cancellation until the caller releases it.
// The adapter must reject the late result before the provider receives anything.
private actor LateTranscript: MemoryTranscriptSource {
    private var entered = false
    private var listeners: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { listeners.append($0) }
    }
    func finish() { release?.resume(); release = nil }
    func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        entered = true
        listeners.forEach { $0.resume() }; listeners.removeAll()
        await withCheckedContinuation { release = $0 }
        return try AgentJournalRecord(sessionID: sessionID, revision: 1, status: .completed,
            updatedAt: Date(timeIntervalSince1970: 1), messageCount: 0, artifactCount: 0)
    }
    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage {
        SessionMessagePage(sessionID: sessionID, offset: 0, totalCount: 0, messages: [])
    }
}
@Test(arguments: [false, true])
func lateMemoryPreparationAfterCancellationNeverEntersProvider(streaming: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("late-memory-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = LateTranscript()
    let client = MemoryModelClient(base: UnenteredProvider(),
        memory: MemoryController(configuration: MemoryConfiguration(dataDirectory: root)),
        transcriptSource: transcript)
    let request = ModelRequest(sessionID: "late", messages: [.init(role: .user, content: "query")], tools: [])
    let task = Task {
        if streaming { for try await _ in client.stream(request: request) {} }
        else { _ = try await client.generate(request: request) }
    }
    await transcript.waitUntilEntered()
    task.cancel()
    await transcript.finish()
    do { try await task.value; Issue.record("Cancelled preparation returned success") }
    catch { #expect(error is CancellationError) }
}
