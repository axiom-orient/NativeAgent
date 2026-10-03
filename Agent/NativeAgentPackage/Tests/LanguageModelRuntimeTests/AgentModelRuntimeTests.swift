import NativeAgent
import NativeAgentDomain
import NativeAgentExecution
import NativeAgentStore
import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@Suite("NativeAgent over ModelRuntime")
struct LanguageModelRuntimeTests {
  @Test func completedRuntimeTurnCommitsAtomically() async throws {
    let client = ScriptedRuntimeClient(mode: .completed("hello"))
    let runtime = try makeRuntime(client: client)
    let (agent, storage, root) = try makeAgent(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await agent.run("hi", sessionID: "session-complete")

    #expect(result.output == "hello")
    let persisted = try await storage.session(id: "session-complete")
    #expect(persisted.messages.filter { $0.role == .assistant }.map(\.content) == ["hello"])
    #expect(persisted.modelID == runtime.modelDescriptor.id)
    #expect(persisted.providerID == runtime.providerID)
    #expect(persisted.waitState == nil)
  }

  @Test func sessionModelIdentityComesOnlyFromSelectedRuntime() async throws {
    let client = ScriptedRuntimeClient(mode: .completed("identity"))
    let runtime = try makeRuntime(client: client)
    let (agent, storage, root) = try makeAgent(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try await agent.run("hello", sessionID: "session-model-identity")

    let persisted = try await storage.session(id: "session-model-identity")
    #expect(persisted.modelID == runtime.modelDescriptor.id)
    #expect(persisted.providerID == runtime.providerID)
  }

  @Test func partialTransportFailureNeverCommitsAssistantTurn() async throws {
    let client = ScriptedRuntimeClient(mode: .partialThenFailure)
    let runtime = try makeRuntime(client: client)
    let (agent, storage, root) = try makeAgent(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: root) }

    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await agent.run("hi", sessionID: "session-partial")
    }

    let persisted = try await storage.session(id: "session-partial")
    #expect(persisted.messages.allSatisfy { $0.role != .assistant })
    #expect(persisted.waitState != nil)
  }

  @Test func cancellationAfterProviderEntryRequiresReconciliation() async throws {
    let client = ScriptedRuntimeClient(mode: .untilCancelled)
    let runtime = try makeRuntime(client: client)
    let (agent, storage, root) = try makeAgent(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: root) }

    let task = Task {
      try await agent.run("hi", sessionID: "session-cancel")
    }
    await client.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }

    let persisted = try await storage.session(id: "session-cancel")
    #expect(persisted.messages.allSatisfy { $0.role != .assistant })
    #expect(persisted.status == .waiting)
    #expect(persisted.waitState?.kind == .modelInvocation)
    #expect(persisted.failure == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func bufferedProducerCanOutliveCancellationWithoutAuthorizingRetry() async throws {
    let client = ScriptedRuntimeClient(mode: .afterRelease)
    let runtime = try makeRuntime(client: client)
    let (agent, storage, root) = try makeAgent(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: root) }
    let operation = Task { try await agent.run("hi", sessionID: "buffered-cancel") }
    await client.waitUntilStarted()
    operation.cancel()
    await #expect(throws: CancellationError.self) { _ = try await operation.value }
    let producerStillRunning = await !client.hasFinished
    await client.releaseProducer()
    await client.waitUntilFinished()
    #expect(producerStillRunning)
    // Cancellation of AsyncThrowingStream consumption is not proof that the
    // buffered producer stopped. Its late terminal result must not be committed.
    let snapshot = try await storage.session(id: "buffered-cancel")
    #expect(snapshot.status == .waiting)
    #expect(snapshot.waitState?.kind == .modelInvocation)
    #expect(snapshot.messages.allSatisfy { $0.role != .assistant })
    #expect(snapshot.failure == nil)
  }

  @Test func providerDeadlineAfterEntryRequiresReconciliation() async throws {
    let client = ScriptedRuntimeClient(mode: .deadline)
    let runtime = try makeRuntime(client: client)
    let (agent, storage, root) = try makeAgent(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      _ = try await agent.run("hi", sessionID: "session-deadline")
      Issue.record("A provider deadline returned success.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .deadlineExceeded)
    }
    let snapshot = try await storage.session(id: "session-deadline")
    #expect(snapshot.status == .waiting)
    #expect(snapshot.waitState?.kind == .modelInvocation)
    #expect(snapshot.messages.allSatisfy { $0.role != .assistant })
    #expect(snapshot.failure == nil)
  }

  private func makeRuntime(client: ScriptedRuntimeClient) throws -> ModelRuntime {
    try ModelRuntime(
      id: ModelRuntimeID(rawValue: "test.runtime"),
      client: client
    )
  }

  private func makeAgent(
    runtime: ModelRuntime
  ) throws -> (Agent, AgentStorage, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "native-agent-runtime-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let claimStore = InMemorySessionExecutionClaimStore()
    let storage = AgentStorage.directory(root, executionClaimStore: claimStore)
    let agent = try Agent(modelRuntime: runtime, storage: storage)
    return (agent, storage, root)
  }
}

private actor ScriptedRuntimeClient: ModelClient {
  enum Mode: Sendable {
    case completed(String)
    case partialThenFailure
    case untilCancelled
    case afterRelease
    case deadline
  }

  nonisolated let providerID = "provider.test.runtime"
  nonisolated let modelDescriptor: ModelDescriptor? = ModelDescriptor(
    id: "test-model",
    providerID: "provider.test.runtime",
    capabilities: [.textInput, .textOutput, .streaming],
    contextWindowTokens: 8_192
  )

  private let mode: Mode
  private var producerRelease: CheckedContinuation<Void, Never>?
  private var producerReleased = false
  private(set) var hasFinished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init(mode: Mode) {
    self.mode = mode
  }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  nonisolated func stream(
    request: ModelRequest
  ) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.markStarted()
        continuation.yield(.started(descriptor: self.modelDescriptor))
        switch await self.modeValue() {
        case .completed(let value):
          continuation.yield(.textDelta(value))
          continuation.yield(.completed(ModelTurn(content: value, stopReason: .stop)))
          continuation.finish()
        case .partialThenFailure:
          continuation.yield(.textDelta("partial"))
          continuation.finish(
            throwing: ModelGenerationFailure(.transportFailure, "fixture transport failure")
          )
        case .deadline:
          continuation.finish(throwing: ModelGenerationFailure(.deadlineExceeded, "Provider deadline."))
        case .afterRelease:
          await self.waitForRelease()
          continuation.yield(.completed(ModelTurn(content: "late result")))
          continuation.finish()
          await self.markFinished()
        case .untilCancelled:
          do {
            try await Task.sleep(for: .seconds(60))
            continuation.finish(
              throwing: ModelGenerationFailure(.terminalMissing, "fixture ended unexpectedly")
            )
          } catch {
            continuation.finish(throwing: CancellationError())
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  private func markStarted() {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func releaseProducer() {
    producerReleased = true
    producerRelease?.resume()
    producerRelease = nil
  }

  private func waitForRelease() async {
    if producerReleased { return }
    await withCheckedContinuation { producerRelease = $0 }
  }

  func waitUntilFinished() async {
    if hasFinished { return }
    await withCheckedContinuation { finishWaiters.append($0) }
  }

  private func markFinished() {
    hasFinished = true
    let waiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func modeValue() -> Mode { mode }
}
