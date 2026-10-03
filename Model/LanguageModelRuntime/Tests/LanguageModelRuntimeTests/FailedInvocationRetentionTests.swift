import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@Test(arguments: [false, true])
func quarantineRetainsExactFailedInvocationAfterPumpExits(throughModel: Bool) async throws {
  let lifetime = InvocationLifetime()
  let client = EphemeralOwnedClient(lifetime: lifetime)
  let runtime = throughModel
    ? try ModelRuntime(id: .init(rawValue: "retention"), model: ClientLanguageModel(client: client))
    : try ModelRuntime(id: .init(rawValue: "retention"), client: client)
  let run = try await runtime.start(ModelRequest(
    sessionID: "retention", messages: [.init(role: .user, content: "hello")], tools: []))
  await #expect(throws: ModelRuntimeFailure.self) { for try await _ in run.events {} }
  await run.cancel() // joins the pump, not merely its buffered terminal error
  #expect(await runtime.status().failure?.code == .nativeDrainFailed)
  #expect(lifetime.isAlive)
  await #expect(throws: ModelRuntimeFailure.self) { try await runtime.shutdown() }
  #expect(lifetime.isAlive)
}

private final class NativeOperation: Sendable {}
private final class InvocationLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private weak var operation: NativeOperation?
  func observe(_ operation: NativeOperation) { lock.withLock { self.operation = operation } }
  var isAlive: Bool { lock.withLock { operation != nil } }
}
private struct EphemeralOwnedClient: ModelClientWithOwnedInvocation {
  let lifetime: InvocationLifetime
  let providerID = "test.retention"
  var modelDescriptor: ModelDescriptor? {
    ModelDescriptor(id: "retention", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn { throw Unproved() }
  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }
  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void) -> ModelClientInvocation {
    let operation = NativeOperation()
    lifetime.observe(operation)
    onStarted()
    let stream = AsyncThrowingStream<ModelEvent, any Error> { continuation in
      continuation.yield(.started(descriptor: modelDescriptor))
      continuation.yield(.completed(ModelTurn(content: "ok")))
      continuation.finish()
    }
    return ModelClientInvocation(events: stream,
      cancel: { withExtendedLifetime(operation) {} },
      waitForCompletion: { try withExtendedLifetime(operation) { throw Unproved() } })
  }
  private struct Unproved: Error {}
}
