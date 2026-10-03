import Foundation
import LanguageModelCore
import LanguageModelRuntime

public struct HubModelDownloadProgress: Hashable, Sendable {
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let currentFile: String?

  public init(completedBytes: UInt64, totalBytes: UInt64, currentFile: String?) {
    self.completedBytes = completedBytes
    self.totalBytes = totalBytes
    self.currentFile = currentFile
  }
}

/// A backend-specific compatibility result pinned to one Hub commit and file set.
public struct HubModelImportCandidate: Hashable, Sendable, Identifiable {
  public let id: String
  public let backendID: String
  public let providerID: String
  public let repositoryID: String
  public let revision: String
  public let displayName: String
  public let artifactPaths: [String]
  public let totalBytes: UInt64

  public init(
    backendID: String,
    providerID: String,
    repositoryID: String,
    revision: String,
    displayName: String,
    artifactPaths: [String],
    totalBytes: UInt64
  ) throws {
    let normalizedBackend = backendID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isIdentifier(normalizedBackend), Self.isIdentifier(normalizedProvider),
      !normalizedName.isEmpty, normalizedName.utf8.count <= 256,
      HubRepositorySyntax.isValidRepositoryID(repositoryID), HubRepositorySyntax.isCommit(revision),
      !artifactPaths.isEmpty, artifactPaths.count <= 100_000, totalBytes > 0,
      Set(artifactPaths).count == artifactPaths.count,
      artifactPaths.allSatisfy(Self.isSafeArtifactPath)
    else { throw HubModelImportError.invalidCandidate }
    self.backendID = normalizedBackend
    self.providerID = normalizedProvider
    self.repositoryID = repositoryID
    self.revision = revision.lowercased()
    self.displayName = normalizedName
    let canonicalArtifactPaths = artifactPaths.sorted()
    self.artifactPaths = canonicalArtifactPaths
    self.totalBytes = totalBytes
    let encodedPaths = canonicalArtifactPaths.map { "\($0.utf8.count):\($0)" }.joined()
    id =
      "\(normalizedBackend):\(normalizedProvider):\(repositoryID)@\(revision.lowercased()):\(encodedPaths)"
  }

  private static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 46 || $0 == 95
      }
  }

  private static func isSafeArtifactPath(_ value: String) -> Bool {
    guard (1...4_096).contains(value.utf8.count), !value.hasPrefix("/"),
      !value.contains("\\"), !value.contains("\0")
    else { return false }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count <= 32
      && parts.allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
      }
  }
}

public enum HubModelImportError: Error, Equatable, Sendable {
  case invalidCandidate
  case unsupportedModel
  case backendBusy(String)
  case backendSelectionRequired([HubModelImportCandidate])
  case backendUnavailable(String)
}

/// Each native provider owns its file-format policy, compatibility checks and acquisition logic.
public protocol HubModelImportBackend: Sendable {
  var hubBackendID: String { get }
  var hubProviderID: String { get }
  func inspectModel(at address: HubModelAddress) async throws -> HubModelImportCandidate?
  func installModel(
    _ candidate: HubModelImportCandidate,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)?
  ) async throws -> ModelDescriptor
}

/// Inspects a pasted model page against the installed backends and automatically installs a
/// unique compatible format. A repository containing formats for multiple engines is surfaced as
/// choices instead of silently selecting an engine.
public struct HubModelInstaller: Sendable {
  private let backends: [any HubModelImportBackend]

  public init(backends: [any HubModelImportBackend]) throws {
    var seen: Set<String> = []
    for backend in backends {
      guard seen.insert(backend.hubBackendID).inserted else {
        throw HubModelImportError.invalidCandidate
      }
    }
    self.backends = backends
  }

  public func candidates(for address: String) async throws -> [HubModelImportCandidate] {
    try Task.checkCancellation()
    let parsed = try HubModelAddress(address)
    return try await withThrowingTaskGroup(of: (Int, HubModelImportCandidate?).self) { group in
      for (index, backend) in backends.enumerated() {
        group.addTask {
          try Task.checkCancellation()
          let candidate = try await backend.inspectModel(at: parsed)
          try Task.checkCancellation()
          if let candidate,
            candidate.backendID != backend.hubBackendID
              || candidate.providerID != backend.hubProviderID
              || candidate.repositoryID != parsed.repositoryID
          {
            throw HubModelImportError.invalidCandidate
          }
          return (index, candidate)
        }
      }
      var ordered: [(Int, HubModelImportCandidate)] = []
      for try await (index, candidate) in group {
        if let candidate { ordered.append((index, candidate)) }
      }
      try Task.checkCancellation()
      return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  public func install(
    from address: String,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)? = nil
  ) async throws -> ModelDescriptor {
    let candidate = try await uniqueCandidate(for: address)
    return try await install(candidate, progress: progress)
  }

  /// Installs the uniquely compatible backend and immediately creates its selected runtime.
  /// The returned runtime is owned by the caller and must be shut down after use.
  public func installAndLoad(
    from address: String,
    using registry: ModelProviderRegistry,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)? = nil
  ) async throws -> (model: ModelDescriptor, runtime: ModelRuntime) {
    let selection = try await uniqueCandidate(for: address)
    let registeredProviders = await registry.providers()
    guard registeredProviders.contains(where: { $0.id == selection.providerID }) else {
      throw HubModelImportError.backendUnavailable(selection.providerID)
    }
    let model = try await install(selection, progress: progress)
    let modelSelection = try ModelProviderSelection(providerID: model.providerID, modelID: model.id)
    let runtime = try await registry.makeRuntime(modelSelection)
    return (model, runtime)
  }

  private func uniqueCandidate(for address: String) async throws -> HubModelImportCandidate {
    let options = try await candidates(for: address)
    guard !options.isEmpty else { throw HubModelImportError.unsupportedModel }
    guard options.count == 1 else {
      throw HubModelImportError.backendSelectionRequired(options)
    }
    return options[0]
  }

  public func install(
    _ candidate: HubModelImportCandidate,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)? = nil
  ) async throws -> ModelDescriptor {
    try Task.checkCancellation()
    guard let backend = backends.first(where: { $0.hubBackendID == candidate.backendID }) else {
      throw HubModelImportError.backendUnavailable(candidate.backendID)
    }
    guard backend.hubProviderID == candidate.providerID else {
      throw HubModelImportError.invalidCandidate
    }
    let model = try await backend.installModel(candidate, progress: progress)
    // Installation may already have committed files. Validate the observed result without
    // replacing it with cancellation; the next load owns its own pre-effect cancellation gate.
    try model.validateGenerationContract()
    guard model.providerID == candidate.providerID else {
      throw HubModelImportError.invalidCandidate
    }
    return model
  }
}
