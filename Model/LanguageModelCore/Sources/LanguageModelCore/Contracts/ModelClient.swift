/// Semantic contract at the provider port, not a model capability or a feature flag.
/// A durable invocation may only enter a client that preserves its frozen request.
public enum ModelClientInvocationSemantics: Sendable, Equatable {
    /// The request at this declared client boundary is consumed without hidden augmentation.
    /// An explicit aggregate operation has its own child calls; this is not a claim
    /// that their physical provider requests equal the aggregate input.
    case exactRequest
    /// Hidden host-side request decoration. Call directly, outside ModelRuntime.
    case standaloneOnly
}

public protocol ModelClient: Sendable {
    var providerID: String { get }
    var invocationSemantics: ModelClientInvocationSemantics { get }
    var modelDescriptor: ModelDescriptor? { get }
    func generate(request: ModelRequest) async throws -> ModelTurn
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error>
}

public extension ModelClient {
    /// Existing providers already promise to execute the supplied semantic request.
    /// Request-decorating wrappers must override this; routing wrappers propagate
    /// the wrapped client contract rather than masking it.
    var invocationSemantics: ModelClientInvocationSemantics { .exactRequest }
    var modelDescriptor: ModelDescriptor? { nil }
}
