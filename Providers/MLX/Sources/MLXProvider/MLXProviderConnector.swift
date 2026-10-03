import LanguageModelCore
import LanguageModelRuntime

/// Registry adapter for host-prepared MLX models.
///
/// Hub resolution/download remains an explicit preparation step owned by `MLXTextRuntime`.
/// This connector only exposes immutable prepared model revisions to Agent management.
public struct MLXProviderConnector: ModelProviderConnector {
  public let descriptor: ModelProviderDescriptor
  private let runtime: MLXTextRuntime
  private let modelsByID: [String: MLXPreparedModel]
  private let defaultModelID: String
  private let policy: ModelRuntimePolicy

  public init(
    runtime: MLXTextRuntime,
    preparedModels: [MLXPreparedModel],
    defaultModelID: String? = nil,
    policy: ModelRuntimePolicy = .default
  ) throws {
    guard !preparedModels.isEmpty else {
      throw ModelGenerationFailure(
        .invalidRequest, "MLX provider requires at least one prepared model.")
    }
    var indexed: [String: MLXPreparedModel] = [:]
    for prepared in preparedModels {
      let id = Self.modelID(prepared.model)
      guard indexed[id] == nil else {
        throw ModelGenerationFailure(.invalidRequest, "Duplicate MLX model: \(id)")
      }
      indexed[id] = prepared
    }
    let resolvedDefault = defaultModelID ?? Self.modelID(preparedModels[0].model)
    guard indexed[resolvedDefault] != nil else {
      throw ModelGenerationFailure(.invalidRequest, "MLX default model is not registered.")
    }
    self.descriptor = try ModelProviderDescriptor(
      id: "mlx.text",
      displayName: "MLX",
      kind: .onDevice
    )
    self.runtime = runtime
    self.modelsByID = indexed
    self.defaultModelID = resolvedDefault
    self.policy = policy
  }

  public func availability() async throws -> ModelProviderAvailability {
    var sawBusy = false
    for prepared in modelsByID.values {
      switch try await runtime.readiness(for: prepared.model) {
      case .ready:
        return .available
      case .busy:
        sawBusy = true
      case .missing:
        continue
      }
    }
    return .unavailable(
      sawBusy ? "MLX runtime is busy." : "No registered MLX model artifact is ready."
    )
  }

  public func models() async throws -> [ModelDescriptor] {
    modelsByID.values.map { MLXTextRuntime.modelDescriptor(for: $0.model) }
    .sorted { $0.id < $1.id }
  }

  public func makeRuntime(modelID: String?) async throws -> ModelRuntime {
    let selectedID = modelID ?? defaultModelID
    guard let prepared = modelsByID[selectedID] else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown MLX model: \(selectedID)")
    }
    return try await runtime.loadRuntime(prepared, policy: policy)
  }

  private static func modelID(_ model: MLXModel) -> String {
    "\(model.repositoryID)@\(model.revision)"
  }
}
