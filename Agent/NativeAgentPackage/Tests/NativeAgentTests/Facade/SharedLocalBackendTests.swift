import NativeAgentTestSupport
import Foundation
import NativeAgent
import LanguageModelCore
import LanguageModelRuntime
import Testing

@Suite("Durable Agent borrowing a local backend")
struct SharedLocalBackendTests {
  @Test func durableRunsAndExternalFrontendUseOneRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = LocalBackend(
      load: {
        try ModelRuntime(id: .init(rawValue: "test.shared"), client: SharedKernelFixture())
      }, releaseResident: {})
    let runtime = try await backend.load()
    let agent = try Agent(modelRuntime: runtime, storage: .directory(root))
    let first = try await agent.run("first", sessionID: "first")
    #expect(first.status == .completed)
    #expect(first.output == "test-only response")
    // Same lower boundary used by the Apple bridge, not a second wrapper.
    // This fixture does not prove native vendor inference.
    let external = try await runtime.generate(
      ModelRequest(
        sessionID: "external",
        messages: [.init(role: .user, content: "external")], tools: []))
    #expect(external.content == "test-only response")
    let second = try await agent.run("second", sessionID: "second")
    #expect(second.status == .completed)
    #expect(await runtime.status().phase == .idle)
    try await backend.shutdown()
    #expect(await runtime.status().phase == .closed)
  }
}
private struct SharedKernelFixture: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

  let providerID = "test.shared"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "shared", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn {
    ModelTurn(content: "test-only response")
  }
}
