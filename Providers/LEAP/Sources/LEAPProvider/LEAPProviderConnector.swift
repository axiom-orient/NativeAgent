import ModelArtifactStore
import LanguageModelCore
import LanguageModelRuntime

/// Registry adapter for host-prepared LEAP text models.
/// Download/import is deliberately outside provider selection; Agent management only selects
/// among verified prepared artifacts.
public struct LEAPProviderConnector: ModelProviderConnector {
  public let descriptor: ModelProviderDescriptor
  private let runtime: LeapRuntime
  private let modelsByID: [String: LeapPreparedTextModel]
  private let defaultModelID: String
  private let policy: ModelRuntimePolicy

  public init(
    runtime: LeapRuntime,
    preparedModels: [LeapPreparedTextModel],
    defaultModelID: String? = nil,
    policy: ModelRuntimePolicy = .default
  ) throws {
    guard !preparedModels.isEmpty else {
      throw ModelGenerationFailure(
        .invalidRequest, "LEAP provider requires at least one prepared text model.")
    }
    var indexed: [String: LeapPreparedTextModel] = [:]
    for prepared in preparedModels {
      let id = Self.modelID(prepared)
      guard indexed[id] == nil else {
        throw ModelGenerationFailure(.invalidRequest, "Duplicate LEAP text model: \(id)")
      }
      indexed[id] = prepared
    }
    let resolvedDefault = defaultModelID ?? Self.modelID(preparedModels[0])
    guard indexed[resolvedDefault] != nil else {
      throw ModelGenerationFailure(.invalidRequest, "LEAP default text model is not registered.")
    }
    self.descriptor = try ModelProviderDescriptor(
      id: "leap.text",
      displayName: "LEAP",
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
      sawBusy ? "LEAP runtime is busy." : "No registered LEAP text model artifact is ready."
    )
  }

  public func models() async throws -> [ModelDescriptor] {
    modelsByID.values.map { prepared in
      ModelDescriptor(
        id: Self.modelID(prepared),
        providerID: descriptor.id,
        displayName: prepared.model.repositoryID,
        capabilities: LeapModelClient.supportedCapabilities
      )
    }
    .sorted { $0.id < $1.id }
  }

  public func makeRuntime(modelID: String?) async throws -> ModelRuntime {
    let selectedID = modelID ?? defaultModelID
    guard let prepared = modelsByID[selectedID] else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown LEAP text model: \(selectedID)")
    }
    return try await runtime.makeTextRuntime(prepared, policy: policy)
  }

  private static func modelID(_ prepared: LeapPreparedTextModel) -> String {
    "lfm2.5-qad-\(prepared.identity.manifestDigest.rawValue)"
  }
}
