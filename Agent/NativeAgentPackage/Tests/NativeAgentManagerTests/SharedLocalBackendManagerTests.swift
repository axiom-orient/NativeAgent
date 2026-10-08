import NativeAgentTestSupport
import Foundation
import NativeAgent
import NativeAgentManager
import LanguageModelCore
import LanguageModelRuntime
import Testing

/// Actual Manager tests on Apple platforms. The portable harness supplies no
/// substitute NaturalLanguage implementation and excludes this target.
@Suite("AgentManager borrows host-owned local runtime")
struct SharedLocalBackendManagerTests {
  @Test func repeatedManagedOperationsDoNotCloseTheHostBackend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = LocalBackend(
      load: {
        try ModelRuntime(id: .init(rawValue: "managed.shared"), client: ManagedSharedFixture())
      }, releaseResident: {})
    let connector = try await backend.providerConnector(displayName: "Shared local")
    let runtime = try await backend.load()
    let manager = AgentManager(
      dataStore: .directory(root), providers: try ModelProviderRegistry([connector]))
    _ = try await manager.createAgent(
      id: "shared", name: "Shared",
      provider: try .init(providerID: runtime.providerID, modelID: runtime.modelDescriptor.id))
    let first = try await manager.run(agentID: "shared", input: "hello", sessionID: "first")
    #expect(first.status == .completed)
    #expect(await runtime.status().phase == .idle)
    let second = try await manager.run(agentID: "shared", input: "again", sessionID: "second")
    #expect(second.status == .completed)
    #expect(await runtime.status().phase == .idle)
    try await backend.shutdown()
    #expect(await runtime.status().phase == .closed)
  }
}
private struct ManagedSharedFixture: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

  let providerID = "test.managed.shared"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    ModelTurn(content: "test-only response")
  }
}
