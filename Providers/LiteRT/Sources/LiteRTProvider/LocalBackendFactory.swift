import LanguageModelRuntime

extension LiteRTProvider {
  /// One host lifetime, reusable by NativeAgent and an Apple session bridge.
  public static func localBackend(
    for model: LiteRTTextModel,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) -> LocalBackend {
    LocalBackend(
      load: { try await loadRuntime(model, runtimeID: runtimeID, policy: policy) },
      // LiteRT loadRuntime owns partial construction cleanup and attaches the
      // engine/lease release to ModelRuntime.shutdown. Never close it twice.
      releaseResident: {}
    )
  }
}
