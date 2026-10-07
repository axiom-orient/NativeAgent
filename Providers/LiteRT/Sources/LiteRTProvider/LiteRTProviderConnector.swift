import Foundation
import LanguageModelCore
import LanguageModelRuntime

/// Registry adapter for a host-owned set of already-acquired LiteRT-LM models.
/// Model download remains outside the provider, and selection is explicit.
public struct LiteRTProviderConnector: ModelProviderConnector {
  public let descriptor: ModelProviderDescriptor
  private let modelsByID: [String: LiteRTTextModel]
  private let defaultModelID: String
  private let policy: ModelRuntimePolicy

  public init(
    models: [LiteRTTextModel],
    defaultModelID: String? = nil,
    policy: ModelRuntimePolicy = .default
  ) throws {
    guard !models.isEmpty else {
      throw ModelGenerationFailure(.invalidRequest, "LiteRT provider requires at least one model.")
    }
    var indexed: [String: LiteRTTextModel] = [:]
    for model in models {
      guard indexed[model.id] == nil else {
        throw ModelGenerationFailure(.invalidRequest, "Duplicate LiteRT model: \(model.id)")
      }
      indexed[model.id] = model
    }
    let resolvedDefault = defaultModelID ?? models[0].id
    guard indexed[resolvedDefault] != nil else {
      throw ModelGenerationFailure(.invalidRequest, "LiteRT default model is not registered.")
    }
    self.descriptor = try ModelProviderDescriptor(
      id: LiteRTProvider.providerID,
      displayName: "LiteRT-LM",
      kind: .onDevice
    )
    self.modelsByID = indexed
    self.defaultModelID = resolvedDefault
    self.policy = policy
  }

  public func availability() async throws -> ModelProviderAvailability {
    #if os(iOS) || os(macOS)
      let ready = modelsByID.values.contains {
        FileManager.default.fileExists(atPath: $0.modelURL.path)
      }
      return ready ? .available : .unavailable("No registered LiteRT-LM model artifact is present.")
    #else
      return .unavailable("LiteRT-LM is supported only on iOS and macOS.")
    #endif
  }

  public func models() async throws -> [ModelDescriptor] {
    modelsByID.values.sorted { $0.id < $1.id }
      .map(LiteRTProvider.modelDescriptor(for:))
  }

  public func makeRuntime(modelID: String?) async throws -> ModelRuntime {
    let selectedID = modelID ?? defaultModelID
    guard let model = modelsByID[selectedID] else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown LiteRT-LM model: \(selectedID)")
    }
    return try await LiteRTProvider.loadRuntime(model, policy: policy)
  }
}
