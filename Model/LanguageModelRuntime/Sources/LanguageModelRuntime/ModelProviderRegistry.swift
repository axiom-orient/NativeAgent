import Foundation
import LanguageModelCore

/// Broad execution locality. Authentication and readiness are reported separately.
public enum ModelProviderKind: String, Codable, Hashable, Sendable {
  case onDevice
  case remote
}

/// Stable provider identity exposed to agent-management code.
public struct ModelProviderDescriptor: Codable, Hashable, Sendable, Identifiable {
  public static let maximumIdentifierUTF8Bytes = 128
  public static let maximumDisplayNameUTF8Bytes = 256

  public let id: String
  public let displayName: String
  public let kind: ModelProviderKind

  public init(id: String, displayName: String, kind: ModelProviderKind) throws {
    let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidIdentifier(normalizedID), !normalizedName.isEmpty,
      normalizedName.utf8.count <= Self.maximumDisplayNameUTF8Bytes
    else {
      throw ModelGenerationFailure(.invalidRequest, "Model provider identity is invalid.")
    }
    self.id = normalizedID
    self.displayName = normalizedName
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey { case id, displayName, kind }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(String.self, forKey: .id),
      displayName: container.decode(String.self, forKey: .displayName),
      kind: container.decode(ModelProviderKind.self, forKey: .kind)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(kind, forKey: .kind)
  }

  static func isValidIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= Self.maximumIdentifierUTF8Bytes else { return false }
    return value.utf8.allSatisfy { byte in
      switch byte {
      case 45, 46, 48...57, 65...90, 95, 97...122: true
      default: false
      }
    }
  }
}

/// Readiness is explicit. It never means that the registry may silently choose another provider.
public enum ModelProviderAvailability: Sendable, Equatable {
  case available
  case authenticationRequired
  case unavailable(String)
}

/// Explicit provider/model choice persisted by higher-level agent management.
/// A nil model identifier means "use this provider's documented default/recommended model".
public struct ModelProviderSelection: Codable, Hashable, Sendable {
  public static let maximumModelIdentifierUTF8Bytes = 512

  public let providerID: String
  public let modelID: String?

  public init(providerID: String, modelID: String? = nil) throws {
    let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard ModelProviderDescriptor.isValidIdentifier(providerID),
      modelID.map({ !$0.isEmpty && $0.utf8.count <= Self.maximumModelIdentifierUTF8Bytes }) ?? true
    else {
      throw ModelGenerationFailure(.invalidRequest, "Model provider selection is invalid.")
    }
    self.providerID = providerID
    self.modelID = modelID
  }

  private enum CodingKeys: String, CodingKey { case providerID, modelID }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      providerID: container.decode(String.self, forKey: .providerID),
      modelID: container.decodeIfPresent(String.self, forKey: .modelID)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(providerID, forKey: .providerID)
    try container.encodeIfPresent(modelID, forKey: .modelID)
  }
}

/// Adapter boundary between account/model discovery and one concrete `ModelRuntime`.
///
/// A connector may own authentication or model preparation state. It must not perform
/// cross-provider routing or fallback. `makeRuntime(modelID:)` returns exactly one selected runtime.
public protocol ModelProviderConnector: Sendable {
  var descriptor: ModelProviderDescriptor { get }
  func availability() async throws -> ModelProviderAvailability
  func models() async throws -> [ModelDescriptor]
  /// Transfers ownership of a new runtime wrapper. Shared connectors must
  /// reject this API rather than falsely transferring host-owned resources.
  func makeRuntime(modelID: String?) async throws -> ModelRuntime
  func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess
}

extension ModelProviderConnector {
  /// Existing connectors retain their operation-owned cleanup behavior.
  public func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess {
    .owned(try await makeRuntime(modelID: modelID))
  }
}

/// Closure-backed connector for local/custom providers without another wrapper type.
public struct ClosureModelProviderConnector: ModelProviderConnector {
  public let descriptor: ModelProviderDescriptor
  private let availabilityClosure: @Sendable () async throws -> ModelProviderAvailability
  private let modelsClosure: @Sendable () async throws -> [ModelDescriptor]
  private let runtimeClosure: @Sendable (String?) async throws -> ModelRuntime

  public init(
    descriptor: ModelProviderDescriptor,
    availability: @escaping @Sendable () async throws -> ModelProviderAvailability,
    models: @escaping @Sendable () async throws -> [ModelDescriptor],
    makeRuntime: @escaping @Sendable (String?) async throws -> ModelRuntime
  ) {
    self.descriptor = descriptor
    self.availabilityClosure = availability
    self.modelsClosure = models
    self.runtimeClosure = makeRuntime
  }

  public func availability() async throws -> ModelProviderAvailability {
    try await availabilityClosure()
  }

  public func models() async throws -> [ModelDescriptor] {
    try await modelsClosure()
  }

  public func makeRuntime(modelID: String?) async throws -> ModelRuntime {
    try await runtimeClosure(modelID)
  }
}

/// Process-local registry for explicit provider discovery and selection.
///
/// The registry deliberately has no fallback, ranking or automatic routing. A caller selects a
/// provider; the resulting `ModelRuntime` remains the sole invocation lifecycle authority.
public actor ModelProviderRegistry {
  private var connectors: [String: any ModelProviderConnector] = [:]

  public init(_ connectors: [any ModelProviderConnector] = []) throws {
    for connector in connectors {
      let id = connector.descriptor.id
      guard self.connectors[id] == nil else {
        throw ModelGenerationFailure(.invalidRequest, "Duplicate model provider: \(id)")
      }
      self.connectors[id] = connector
    }
  }

  public func register(_ connector: any ModelProviderConnector) throws {
    let id = connector.descriptor.id
    guard connectors[id] == nil else {
      throw ModelGenerationFailure(.invalidRequest, "Duplicate model provider: \(id)")
    }
    connectors[id] = connector
  }

  @discardableResult
  public func unregister(providerID: String) -> Bool {
    connectors.removeValue(forKey: providerID) != nil
  }

  public func providers() -> [ModelProviderDescriptor] {
    connectors.values.map(\.descriptor).sorted { $0.id < $1.id }
  }

  public func availability(providerID: String) async throws -> ModelProviderAvailability {
    try Task.checkCancellation()
    let result = try await connector(providerID: providerID).availability()
    try Task.checkCancellation()
    return result
  }

  public func models(providerID: String) async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    let connector = try connector(providerID: providerID)
    let models = try await connector.models()
    try Task.checkCancellation()
    try Self.validate(models: models, providerID: providerID)
    return models
  }

  /// Compatibility API with its original ownership-transfer contract.
  public func makeRuntime(_ selection: ModelProviderSelection) async throws -> ModelRuntime {
    let access = try await acquireRuntime(selection)
    guard case .owned(let runtime) = access else {
      throw ModelGenerationFailure(
        .invalidRequest,
        "A shared runtime cannot transfer ownership; use acquireRuntime and release its access.")
    }
    return runtime
  }

  public func acquireRuntime(_ selection: ModelProviderSelection) async throws -> ModelRuntimeAccess
  {
    try Task.checkCancellation()
    let connector = try connector(providerID: selection.providerID)
    let availability = try await connector.availability()
    try Task.checkCancellation()
    switch availability {
    case .available:
      break
    case .authenticationRequired:
      throw ModelGenerationFailure(
        .authenticationRequired,
        "Provider \(selection.providerID) requires authentication."
      )
    case .unavailable(let reason):
      throw ModelGenerationFailure(
        .sourceUnavailable,
        reason.isEmpty ? "Provider \(selection.providerID) is unavailable." : reason
      )
    }

    let access = try await connector.acquireRuntime(modelID: selection.modelID)
    do {
      try Task.checkCancellation()
    } catch {
      // A noncooperative connector may return after caller cancellation. Until
      // delivery, this boundary owns that access: release owned resources but
      // never shut down a borrowed host. Cleanup failure outranks cancellation.
      try await access.release()
      throw error
    }
    let runtime = access.runtime
    if runtime.providerID != selection.providerID {
      try await Self.reject(
        access,
        reason: "Provider connector returned a runtime for a different provider."
      )
    }
    if let modelID = selection.modelID, runtime.modelDescriptor.id != modelID {
      try await Self.reject(
        access,
        reason: "Provider connector returned a runtime for a different model."
      )
    }
    return access
  }

  private static func reject(_ access: ModelRuntimeAccess, reason: String) async throws -> Never {
    do {
      try await access.release()
    } catch {
      throw ModelRuntimeFailure(
        .cleanupFailed,
        "\(reason) Rejected runtime cleanup failed."
      )
    }
    throw ModelGenerationFailure(.sourceUnavailable, reason)
  }

  private func connector(providerID: String) throws -> any ModelProviderConnector {
    guard let connector = connectors[providerID] else {
      throw ModelGenerationFailure(.sourceUnavailable, "Unknown model provider: \(providerID)")
    }
    return connector
  }

  private static func validate(models: [ModelDescriptor], providerID: String) throws {
    var ids = Set<String>()
    for model in models {
      guard model.providerID == providerID, !model.id.isEmpty, ids.insert(model.id).inserted else {
        throw ModelGenerationFailure(
          .sourceUnavailable,
          "Provider model catalog contains an invalid or duplicate model identity."
        )
      }
      try model.validateGenerationContract()
    }
  }
}
