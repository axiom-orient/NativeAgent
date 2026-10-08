import LanguageModelCore

/// Adapts an existing exact-request provider port without replacing its native
/// loader, credentials, cancellation or resident owner. It binds the current
/// ModelClient port to the descriptor/executor contract.
public struct ClientLanguageModel: LanguageModel {
  public let executorConfiguration: Executor.Configuration
  public var descriptor: ModelDescriptor { executorConfiguration.binding.descriptor }

  public init(client: any ModelClient, descriptor: ModelDescriptor? = nil) throws {
    guard client.invocationSemantics == .exactRequest else {
      throw ModelGenerationFailure(.invalidRequest, "A model requires exact-request semantics.")
    }
    guard let resolved = descriptor ?? client.modelDescriptor else {
      throw ModelGenerationFailure(.invalidRequest, "A model requires an authoritative descriptor.")
    }
    try resolved.validateGenerationContract()
    guard resolved.providerID == client.providerID,
      client.modelDescriptor.map({ $0 == resolved }) ?? true
    else {
      throw ModelGenerationFailure(.invalidRequest, "The provider and model descriptors conflict.")
    }
    executorConfiguration = Executor.Configuration(
      binding: Binding(client: client, descriptor: resolved))
  }

  fileprivate final class Binding: Sendable {
    let client: any ModelClient
    let descriptor: ModelDescriptor
    init(client: any ModelClient, descriptor: ModelDescriptor) {
      self.client = client
      self.descriptor = descriptor
    }
  }

  public struct Executor: LanguageModelExecutor {
    public typealias Model = ClientLanguageModel

    /// A live client includes an account/native-resource identity, not just a
    /// model name. Copies reuse this configuration; independent bindings never
    /// alias merely because their model IDs or capability masks match.
    public struct Configuration: Hashable, Sendable {
      fileprivate let binding: Binding
      public static func == (lhs: Self, rhs: Self) -> Bool { lhs.binding === rhs.binding }
      public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(binding)) }
    }

    private let configuration: Configuration
    public init(configuration: Configuration) { self.configuration = configuration }

    public func respond(
      to request: ModelRequest,
      model: ClientLanguageModel,
      streamingInto channel: ModelGenerationChannel
    ) async throws {
      guard configuration == model.executorConfiguration else {
        throw ModelGenerationFailure(
          .invalidRequest, "Executor configuration does not match the model.")
      }
      try Task.checkCancellation()
      let client = configuration.binding.client
      let invocation = (client as? any ModelClientWithOwnedInvocation)?.invocation(
        request: request, onStarted: { channel.markProviderEffectStarted() })
      let events = invocation?.events ?? client.stream(request: request)
      try await withTaskCancellationHandler {
        do {
          for try await event in events {
            try Task.checkCancellation()
            try channel.send(event)
          }
          try await drain(invocation, cancel: false)
          try Task.checkCancellation()
        } catch let failure as ModelExecutorDrainFailure {
          throw failure
        } catch {
          try await drain(invocation, cancel: true)
          throw error
        }
      } onCancel: {
        invocation?.cancel()
      }
    }

    private func drain(_ invocation: ModelClientInvocation?, cancel: Bool) async throws {
      do {
        if cancel { invocation?.cancel() }
        try await invocation?.waitForCompletion()
      } catch {
        invocation?.cancel()
        throw ModelExecutorDrainFailure(
          "The provider did not prove native drain completion.", retaining: invocation)
      }
    }
  }
}
