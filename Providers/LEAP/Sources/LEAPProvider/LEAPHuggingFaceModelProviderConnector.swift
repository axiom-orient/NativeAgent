import CryptoKit
import Foundation
import HuggingFace
import ModelArtifactStore
import LanguageModelCore
import ModelHub
import LanguageModelRuntime

/// Dynamically installs one compatible LFM2 GGUF from a Hugging Face repository.
/// LEAP's existing fixed-catalog connector remains available for bundled/pinned models.
public actor LEAPHuggingFaceModelProviderConnector: ModelProviderConnector, HubModelImportBackend {
  private struct ResolvedHubReference {
    let repositoryID: String
    let revision: String
  }

  private struct Catalog: Codable {
    let formatVersion: Int
    let entries: [CatalogEntry]
  }

  private struct CatalogEntry: Codable {
    let repositoryID: String
    let revision: String
    let modelPath: String
    let displayName: String
    let manifest: ArtifactManifest
  }

  private enum Limits {
    static let maximumModelBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumRemotePathBytes = 4_096
    static let progressPollInterval: Duration = .milliseconds(350)
    static let hashChunkBytes = 1 * 1_024 * 1_024
  }

  public nonisolated let descriptor: ModelProviderDescriptor
  public nonisolated let hubBackendID = "leap-lfm"
  public nonisolated let hubProviderID = "leap.text"

  private let runtime: LeapRuntime
  private let client: HubClient
  private let catalogURL: URL
  private let policy: ModelRuntimePolicy
  private var modelsByID: [String: LeapPreparedTextModel] = [:]
  private var defaultModelID: String?
  private var catalogLoaded = false
  private var modelMutationInProgress = false

  public init(
    runtime: LeapRuntime,
    catalogPersistenceURL: URL,
    hubClient: HubClient? = nil,
    defaultModelID: String? = nil,
    policy: ModelRuntimePolicy = .default
  ) throws {
    guard catalogPersistenceURL.isFileURL else {
      throw ModelGenerationFailure(.invalidRequest, "LEAP model catalog must use a local file URL.")
    }
    descriptor = try ModelProviderDescriptor(
      id: "leap.text", displayName: "LEAP", kind: .onDevice)
    self.runtime = runtime
    client = hubClient ?? Self.makeDefaultHubClient()
    catalogURL = catalogPersistenceURL.standardizedFileURL
    self.defaultModelID = defaultModelID
    self.policy = policy
  }

  public func inspectModel(at address: HubModelAddress) async throws -> HubModelImportCandidate? {
    let reference = try await resolve(address)
    guard let repository = Repo.ID(rawValue: reference.repositoryID) else {
      throw HubModelAddressError.invalidAddress
    }
    let metadata = try await client.getModel(repository, revision: reference.revision, fetchConfig: true)
    guard Self.isLFM2Text(metadata, repositoryID: reference.repositoryID) else { return nil }
    let tree = try await client.listFiles(in: repository, revision: reference.revision, recursive: true)
    let files = tree.filter { entry in
      entry.type == .file && entry.path.lowercased().hasSuffix(".gguf")
        && Self.isSafeHubPath(entry.path) && !Self.isCompanionAsset(entry.path)
        && (entry.size ?? 0) > 0
    }
    guard !files.isEmpty else { return nil }
    let selected = files.min { left, right in
      let leftRank = Self.quantizationRank(left.path)
      let rightRank = Self.quantizationRank(right.path)
      if leftRank != rightRank { return leftRank < rightRank }
      if left.size != right.size { return (left.size ?? .max) < (right.size ?? .max) }
      return left.path < right.path
    }!
    guard let size = selected.size, size > 0 else { return nil }
    guard UInt64(size) <= Limits.maximumModelBytes else {
      throw ModelGenerationFailure(.invalidRequest, "The selected LEAP GGUF exceeds the 8 GiB install limit.")
    }
    return try HubModelImportCandidate(
      backendID: hubBackendID,
      providerID: hubProviderID,
      repositoryID: reference.repositoryID,
      revision: reference.revision,
      displayName: reference.repositoryID,
      artifactPaths: [selected.path],
      totalBytes: UInt64(size))
  }

  public func installModel(
    _ candidate: HubModelImportCandidate,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)?
  ) async throws -> ModelDescriptor {
    guard candidate.backendID == hubBackendID, candidate.providerID == hubProviderID,
      candidate.artifactPaths.count == 1, Self.isCommit(candidate.revision),
      Self.isSafeHubPath(candidate.artifactPaths[0])
    else { throw HubModelImportError.invalidCandidate }
    try beginModelMutation()
    defer { modelMutationInProgress = false }
    try await loadCatalogIfNeeded()

    let address = try HubModelAddress(
      "https://huggingface.co/\(candidate.repositoryID)/commit/\(candidate.revision)")
    guard let current = try await inspectModel(at: address), current.id == candidate.id else {
      throw HubModelImportError.invalidCandidate
    }
    guard let repository = Repo.ID(rawValue: candidate.repositoryID) else {
      throw HubModelAddressError.invalidAddress
    }
    let modelPath = candidate.artifactPaths[0]
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(path: "native-agent-leap-hub-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let destination = temporaryDirectory.appending(path: modelPath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let downloadProgress = Progress(totalUnitCount: Int64(candidate.totalBytes))
    let progressBox = LEAPHuggingFaceProgressBox(downloadProgress)
    let monitor = Task {
      var lastReported: Int64 = -1
      while !Task.isCancelled {
        let completed = progressBox.completedUnitCount
        if completed != lastReported {
          lastReported = completed
          progress?(.init(
            completedBytes: UInt64(max(0, completed)),
            totalBytes: candidate.totalBytes,
            currentFile: modelPath))
        }
        try? await Task.sleep(for: Limits.progressPollInterval)
      }
    }
    do {
      _ = try await client.downloadFile(
        at: modelPath,
        from: repository,
        to: destination,
        revision: candidate.revision,
        cachePolicy: .reloadIgnoringLocalCacheData,
        progress: downloadProgress,
        transport: .lfs)
    } catch {
      monitor.cancel()
      throw error
    }
    monitor.cancel()
    try Task.checkCancellation()

    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize,
      fileSize >= 0, UInt64(fileSize) == candidate.totalBytes
    else { throw ModelGenerationFailure(.sourceUnavailable, "The downloaded LEAP GGUF has an unexpected size.") }
    let digest = try Self.sha256(of: destination)
    guard let artifactDigest = ArtifactDigest(rawValue: digest) else {
      throw ModelGenerationFailure(.sourceUnavailable, "The downloaded LEAP GGUF could not be verified.")
    }
    let manifest = try ArtifactManifest(
      artifactID: Self.artifactID(candidate),
      files: [try ArtifactEntry(path: modelPath, byteCount: candidate.totalBytes, sha256: artifactDigest)])
    let model = try LeapTextModel(
      repositoryID: candidate.repositoryID,
      revision: candidate.revision,
      modelPath: modelPath,
      manifest: manifest,
      displayName: candidate.displayName)
    let prepared = try await runtime.importModel(model, from: temporaryDirectory)
    let modelID = Self.modelID(prepared)
    modelsByID[modelID] = prepared
    do {
      try persistCatalog()
    } catch let catalogError {
      modelsByID.removeValue(forKey: modelID)
      do {
        try await runtime.remove(model)
      } catch {
        throw ModelGenerationFailure(
          .sourceUnavailable, "The LEAP catalog write failed and the new artifact could not be rolled back.")
      }
      throw catalogError
    }
    defaultModelID = modelID
    return Self.descriptor(for: prepared, providerID: hubProviderID)
  }

  public func availability() async throws -> ModelProviderAvailability {
    try await loadCatalogIfNeeded()
    var sawBusy = false
    for prepared in modelsByID.values {
      switch try await runtime.readiness(for: prepared.model) {
      case .ready: return .available
      case .busy: sawBusy = true
      case .missing: continue
      }
    }
    return .unavailable(sawBusy ? "LEAP runtime is busy." : "No installed LFM2 GGUF is available.")
  }

  public func models() async throws -> [ModelDescriptor] {
    try await loadCatalogIfNeeded()
    return modelsByID.values
      .map { Self.descriptor(for: $0, providerID: hubProviderID) }
      .sorted { $0.id < $1.id }
  }

  public func makeRuntime(modelID: String?) async throws -> ModelRuntime {
    try await loadCatalogIfNeeded()
    guard !modelsByID.isEmpty else {
      throw ModelGenerationFailure(.sourceUnavailable, "No LFM2 model has been installed.")
    }
    let selectedID = modelID ?? defaultModelID ?? modelsByID.keys.sorted()[0]
    guard let prepared = modelsByID[selectedID] else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown LEAP model: \(selectedID)")
    }
    return try await runtime.makeTextRuntime(prepared, policy: policy)
  }

  private func resolve(_ address: HubModelAddress) async throws -> ResolvedHubReference {
    guard let repository = Repo.ID(rawValue: address.repositoryID),
      repository.rawValue == address.repositoryID
    else { throw HubModelAddressError.invalidAddress }
    let metadata = try await client.getModel(repository, revision: address.revision)
    guard let revision = metadata.sha, Self.isCommit(revision) else {
      throw ModelGenerationFailure(.sourceUnavailable, "Hugging Face did not return an immutable model revision.")
    }
    return ResolvedHubReference(repositoryID: address.repositoryID, revision: revision.lowercased())
  }

  private func beginModelMutation() throws {
    guard !modelMutationInProgress else { throw LeapError.busy }
    modelMutationInProgress = true
  }

  private func loadCatalogIfNeeded() async throws {
    guard !catalogLoaded else { return }
    guard FileManager.default.fileExists(atPath: catalogURL.path) else {
      catalogLoaded = true
      return
    }
    let archive = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    guard archive.formatVersion == 1 else {
      throw ModelGenerationFailure(.sourceUnavailable, "The LEAP model catalog version is unsupported.")
    }
    var loaded: [String: LeapPreparedTextModel] = [:]
    for entry in archive.entries {
      let model = try LeapTextModel(
        repositoryID: entry.repositoryID,
        revision: entry.revision,
        modelPath: entry.modelPath,
        manifest: entry.manifest,
        displayName: entry.displayName)
      let prepared = try await runtime.importModel(model, from: FileManager.default.temporaryDirectory)
      let modelID = Self.modelID(prepared)
      guard loaded[modelID] == nil else {
        throw ModelGenerationFailure(.sourceUnavailable, "The LEAP model catalog contains a duplicate model.")
      }
      loaded[modelID] = prepared
    }
    modelsByID = loaded
    catalogLoaded = true
  }

  private func persistCatalog() throws {
    var entries: [CatalogEntry] = []
    for prepared in modelsByID.values {
      let model = prepared.model
      let entry = CatalogEntry(
        repositoryID: model.repositoryID,
        revision: model.revision,
        modelPath: model.modelPath,
        displayName: model.displayName ?? model.repositoryID,
        manifest: model.manifest)
      entries.append(entry)
    }
    entries.sort {
      $0.repositoryID == $1.repositoryID
        ? $0.revision < $1.revision
        : $0.repositoryID < $1.repositoryID
    }
    let archive = Catalog(formatVersion: 1, entries: entries)
    let data = try JSONEncoder.sorted.encode(archive)
    try FileManager.default.createDirectory(
      at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: catalogURL, options: Data.WritingOptions.atomic)
  }

  private static func descriptor(
    for prepared: LeapPreparedTextModel,
    providerID: String
  ) -> ModelDescriptor {
    ModelDescriptor(
      id: modelID(prepared),
      providerID: providerID,
      displayName: prepared.model.displayName ?? prepared.model.repositoryID,
      capabilities: LeapModelClient.supportedCapabilities)
  }

  private static func modelID(_ prepared: LeapPreparedTextModel) -> String {
    "lfm2.5-qad-\(prepared.identity.manifestDigest.rawValue)"
  }

  private static func isLFM2Text(_ model: HuggingFace.Model, repositoryID: String) -> Bool {
    let config = model.config ?? [:]
    let modelType = config["model_type"]?.stringValue?.lowercased() ?? ""
    let architectures = config["architectures"]?.arrayValue?.compactMap(\.stringValue)
      .joined(separator: " ").lowercased() ?? ""
    let metadataSignal = modelType == "lfm2" || architectures.contains("lfm2")
    let repositoryName = repositoryID.lowercased()
    let repositorySignal = repositoryName.contains("lfm2")
    let audioOrVision = repositoryName.contains("audio") || repositoryName.contains("vision")
      || architectures.contains("audio") || architectures.contains("vision")
    return (metadataSignal || repositorySignal) && !audioOrVision
  }

  private static func isCompanionAsset(_ path: String) -> Bool {
    let lowercased = path.lowercased()
    return ["mmproj", "vocoder", "audio", "vision", "projector", "encoder", "decoder"]
      .contains(where: { lowercased.contains($0) })
  }

  private static func quantizationRank(_ path: String) -> Int {
    let path = path.lowercased()
    if path.contains("q4_0") { return 0 }
    if path.contains("q4_k_m") { return 1 }
    if path.contains("q4_k_s") { return 2 }
    if path.contains("q5") { return 3 }
    if path.contains("q8") { return 4 }
    return 5
  }

  private static func isSafeHubPath(_ path: String) -> Bool {
    guard (1...Limits.maximumRemotePathBytes).contains(path.utf8.count),
      !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0")
    else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return components.count <= 32 && components.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
    }
  }

  private static func isCommit(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
      }
  }

  private static func artifactID(_ candidate: HubModelImportCandidate) -> String {
    let digest = SHA256.hash(data: Data(candidate.id.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "leap-hub-\(digest)"
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: Limits.hashChunkBytes) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func makeDefaultHubClient() -> HubClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return HubClient(
      session: URLSession(configuration: configuration),
      host: HubClient.defaultHost,
      bearerToken: nil,
      cache: nil)
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

private final class LEAPHuggingFaceProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private let progress: Progress

  init(_ progress: Progress) { self.progress = progress }

  var completedUnitCount: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return max(0, progress.completedUnitCount)
  }
}
