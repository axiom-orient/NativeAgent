import LanguageModelCore
import LanguageModelRuntime
import ModelHub
import MLXModelRegistry

/// A model provider whose Hugging Face catalog can grow after the host app has shipped.
///
/// Register one instance with `ModelProviderRegistry`, then pass model-page addresses to
/// `installModel(from:)`. The resolved commit is persisted by `MLXTextRuntime` when configured
/// with a specifications URL, and newly installed models appear in `models()` immediately.
public actor MLXHubModelProviderConnector: ModelProviderConnector, HubModelImportBackend {
  public nonisolated let descriptor: ModelProviderDescriptor
  public nonisolated let hubBackendID = "mlx"
  public nonisolated let hubProviderID = "mlx.text"

  private let runtime: MLXTextRuntime
  private let policy: ModelRuntimePolicy
  private var defaultModelID: String?
  private var modelMutationInProgress = false

  public init(
    runtime: MLXTextRuntime,
    defaultModelID: String? = nil,
    policy: ModelRuntimePolicy = .default
  ) throws {
    self.descriptor = try ModelProviderDescriptor(
      id: "mlx.text",
      displayName: "MLX",
      kind: .onDevice)
    self.runtime = runtime
    self.defaultModelID = defaultModelID
    self.policy = policy
  }

  /// Adds a model from its Hugging Face page URL or `namespace/repository` ID.
  /// The latest branch commit is pinned before files are downloaded. The returned descriptor can
  /// be selected immediately through `ModelProviderRegistry`; during this process, this becomes
  /// the connector's default when asked for a runtime without an explicit model ID.
  @discardableResult
  public func installModel(
    from address: String,
    progress: (@Sendable (MLXDownloadProgress) -> Void)? = nil
  ) async throws -> ModelDescriptor {
    try beginModelMutation()
    defer { modelMutationInProgress = false }
    let prepared = try await runtime.prepare(from: address, progress: progress)
    let modelDescriptor = MLXTextRuntime.modelDescriptor(for: prepared.model)
    defaultModelID = modelDescriptor.id
    return modelDescriptor
  }

  public func inspectModel(at address: HubModelAddress) async throws -> HubModelImportCandidate? {
    guard let inspection = try await runtime.inspectHubModel(at: address) else { return nil }
    return try HubModelImportCandidate(
      backendID: hubBackendID,
      providerID: hubProviderID,
      repositoryID: inspection.reference.repositoryID,
      revision: inspection.reference.revision,
      displayName: inspection.reference.repositoryID,
      artifactPaths: inspection.filePaths,
      totalBytes: inspection.totalBytes)
  }

  public func installModel(
    _ candidate: HubModelImportCandidate,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)?
  ) async throws -> ModelDescriptor {
    guard candidate.backendID == hubBackendID, candidate.providerID == hubProviderID else {
      throw HubModelImportError.invalidCandidate
    }
    let address = "https://huggingface.co/\(candidate.repositoryID)/commit/\(candidate.revision)"
    return try await installModel(from: address) { value in
      progress?(.init(
        completedBytes: value.completedBytes,
        totalBytes: value.totalBytes,
        currentFile: value.currentFile))
    }
  }

  /// Removes a previously installed model and its verified local artifact.
  public func removeModel(modelID: String) async throws {
    try beginModelMutation()
    defer { modelMutationInProgress = false }
    let models = try await runtime.registeredModels()
    guard let model = models.first(where: { Self.modelID($0) == modelID }) else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown MLX model: \(modelID)")
    }
    try await runtime.remove(model)
    if defaultModelID == modelID {
      let remainingModels = try await runtime.registeredModels()
      defaultModelID = remainingModels.first.map(Self.modelID)
    }
  }

  public func availability() async throws -> ModelProviderAvailability {
    let models = try await runtime.registeredModels()
    guard !models.isEmpty else {
      return .unavailable("No Hugging Face MLX model has been installed.")
    }
    var sawBusy = false
    for model in models {
      switch try await runtime.readiness(for: model) {
      case .ready:
        return .available
      case .busy:
        sawBusy = true
      case .missing:
        continue
      }
    }
    return .unavailable(
      sawBusy ? "MLX runtime is busy." : "No registered MLX model artifact is ready.")
  }

  public func models() async throws -> [ModelDescriptor] {
    let registeredModels = try await runtime.registeredModels()
    return registeredModels.map(MLXTextRuntime.modelDescriptor(for:))
  }

  public func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess {
    let models = try await runtime.registeredModels()
    guard !models.isEmpty else {
      throw ModelGenerationFailure(.sourceUnavailable, "No Hugging Face MLX model is installed.")
    }
    let selectedID = modelID ?? defaultModelID ?? Self.modelID(models[0])
    guard let model = models.first(where: { Self.modelID($0) == selectedID }) else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown MLX model: \(selectedID)")
    }
    // Re-prepare the pinned revision if the local artifact was removed or found to be damaged.
    let prepared = try await runtime.prepare(model)
    if defaultModelID == nil { defaultModelID = selectedID }
    return .owned(try await runtime.loadRuntime(prepared, policy: policy))
  }

  private func beginModelMutation() throws {
    guard !modelMutationInProgress else { throw MLXTextError.busy }
    modelMutationInProgress = true
  }

  private static func modelID(_ model: MLXModel) -> String {
    "\(model.repositoryID)@\(model.revision)"
  }

}
