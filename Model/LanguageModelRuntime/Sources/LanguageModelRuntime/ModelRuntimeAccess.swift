/// Ownership returned by a provider to an operation-scoped consumer.
/// Borrowing never transfers host shutdown authority. No reference counting or
/// second invocation gate is introduced: both cases expose the exact runtime.
public enum ModelRuntimeAccess: Sendable {
  case owned(ModelRuntime)
  case borrowed(ModelRuntime)

  public var runtime: ModelRuntime {
    switch self {
    case .owned(let runtime), .borrowed(let runtime): runtime
    }
  }

  /// Idempotent. An owned access joins runtime shutdown. A borrowed access has
  /// no resource to release; the caller's generation already owns its own drain.
  public func release() async throws {
    switch self {
    case .owned(let runtime): try await runtime.shutdown()
    case .borrowed: break
    }
  }
}
