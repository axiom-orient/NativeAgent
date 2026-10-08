import LanguageModelCore

extension LocalBackend {
  /// Load once and expose the selected model to AgentManager's registry. The
  /// manager borrows; only this backend is allowed to shut the model down.
  public func providerConnector(displayName: String) async throws -> any ModelProviderConnector {
    let runtime = try await load()
    return LocalBackendConnector(
      backend: self, runtime: runtime,
      descriptor:
        try ModelProviderDescriptor(
          id: runtime.providerID, displayName: displayName, kind: .onDevice))
  }
}

private struct LocalBackendConnector: ModelProviderConnector {
  let backend: LocalBackend
  let runtime: ModelRuntime
  let descriptor: ModelProviderDescriptor

  func availability() async throws -> ModelProviderAvailability {
    guard case .ready = await backend.status() else {
      return .unavailable("The shared local backend is not ready.")
    }
    switch await runtime.status().phase {
    case .closing, .closed, .failed:
      return .unavailable("The shared local runtime is closed or quarantined.")
    default:
      // Busy remains an invocation admission decision, not a fallback signal.
      return .available
    }
  }

  func models() async throws -> [ModelDescriptor] { [runtime.modelDescriptor] }

  func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess {
    if let modelID, modelID != runtime.modelDescriptor.id {
      throw ModelGenerationFailure(
        .invalidRequest, "The shared backend has a different selected model.")
    }
    let selected = try await backend.load()
    guard selected === runtime else {
      throw ModelRuntimeFailure(.invariantViolation, "The shared backend changed runtime identity.")
    }
    return .borrowed(selected)
  }
}
