import LanguageModelRuntime

extension MLXTextRuntime {
  /// Create once per resident owner, then share `backend.load()` with all frontends.
  /// Do not use this native runtime directly while the backend owns its lifetime.
  public nonisolated func localBackend(
    for prepared: MLXPreparedModel,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) -> LocalBackend {
    LocalBackend(
      load: { try await self.loadRuntime(prepared, runtimeID: runtimeID, policy: policy) },
      releaseResident: { try await self.unload() }
    )
  }
}
