#if canImport(FoundationModels)
  import FoundationModels
  import LanguageModelCore
  import LanguageModelRuntime

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @available(tvOS, unavailable)
  @available(watchOS, unavailable)
  public struct FoundationModelsProviderConnector: ModelProviderConnector {
    public let descriptor: ModelProviderDescriptor
    private let model: SystemLanguageModel
    private let policy: ModelRuntimePolicy

    public init(
      model: SystemLanguageModel = .default,
      policy: ModelRuntimePolicy = .default
    ) throws {
      self.model = model
      self.policy = policy
      self.descriptor = try ModelProviderDescriptor(
        id: "apple.foundation-models",
        displayName: "Apple Foundation Models",
        kind: .onDevice
      )
    }

    public func availability() async throws -> ModelProviderAvailability {
      let client = FoundationModelsClient(model: model)
      switch client.availability {
      case .available:
        return .available
      case .deviceNotEligible:
        return .unavailable("This device is not eligible for Apple Foundation Models.")
      case .appleIntelligenceNotEnabled:
        return .unavailable("Apple Intelligence is not enabled.")
      case .modelNotReady:
        return .unavailable("Apple Foundation Models is not ready.")
      }
    }

    public func models() async throws -> [ModelDescriptor] {
      [
        ModelDescriptor(
          id: "system-language-model",
          providerID: descriptor.id,
          displayName: "Apple Intelligence",
          capabilities: [.textInput, .textOutput, .streaming]
        )
      ]
    }

    public func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess {
      if let modelID, modelID != "system-language-model" {
        throw ModelGenerationFailure(
          .invalidRequest, "Unknown Apple Foundation Models model: \(modelID)")
      }
      return .owned(try AppleSystemModelProvider.makeRuntime(model: model, policy: policy))

    }
  }

#endif
