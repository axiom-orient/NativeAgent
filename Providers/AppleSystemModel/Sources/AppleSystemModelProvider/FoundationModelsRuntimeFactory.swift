#if canImport(FoundationModels)
  import Foundation
  import FoundationModels
  import LanguageModelCore
  import LanguageModelRuntime

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @available(tvOS, unavailable)
  @available(watchOS, unavailable)
  public enum AppleSystemModelProvider {
    /// Creates a ready runtime for Apple's on-device system language model.
    ///
    /// Availability is checked before the runtime is published. The adapter owns
    /// one native LanguageModelSession per invocation; ModelRuntime owns transient
    /// invocation admission, cancellation, stream validation, and completion.
    public static func makeRuntime(
      model: SystemLanguageModel = .default,
      runtimeID: ModelRuntimeID = ModelRuntimeID(rawValue: "apple.foundation-models.system"),
      policy: ModelRuntimePolicy = .default
    ) throws -> ModelRuntime {
      let client = FoundationModelsClient(model: model)
      guard client.availability == .available else {
        throw ModelGenerationFailure(
          .sourceUnavailable,
          "Apple on-device Foundation Models is unavailable."
        )
      }
      return try ModelRuntime(id: runtimeID, client: client, policy: policy)
    }
  }

#endif
