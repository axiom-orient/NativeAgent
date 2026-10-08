import CryptoKit
import Foundation
import HuggingFace
import ModelArtifactStore
import LanguageModelCore
import ModelHub
import LanguageModelRuntime

/// Installs a single `.litertlm` bundle from a Hugging Face model page into the host artifact store.
/// LiteRT-LM never receives MLX safetensors or LEAP GGUF files through this adapter.
public actor LiteRTHuggingFaceModelProviderConnector: ModelProviderConnector, HubModelImportBackend {
  private struct Catalog: Codable {
    let formatVersion: Int
    let defaultModelID: String?
    let entries: [CatalogEntry]
  }

  private struct CatalogEntry: Codable {
    let id: String
    let repositoryID: String
    let revision: String
    let modelPath: String
    let byteCount: UInt64
    let manifest: ArtifactManifest
  }

  private enum Limits {
    static let maximumModelBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumRemotePathBytes = 4_096
    static let progressPollInterval: Duration = .milliseconds(350)
    static let hashChunkBytes = 1 * 1_024 * 1_024
  }

  public nonisolated let descriptor: ModelProviderDescriptor
  public nonisolated let hubBackendID = "litert-lm"
  public nonisolated let hubProviderID = LiteRTProvider.providerID

  private let store: ModelArtifactStore
  private let client: HubClient
  private let catalogURL: URL
  private let backend: LiteRTBackend
  private let policy: ModelRuntimePolicy
  private var modelsByID: [String: LiteRTTextModel] = [:]
  private var catalogEntriesByID: [String: CatalogEntry] = [:]
  private var leasesByID: [String: ArtifactLease] = [:]
  private var defaultModelID: String?
  private var catalogLoaded = false
  private var modelMutationInProgress = false

  public init(
    store: ModelArtifactStore,
    catalogPersistenceURL: URL,
    hubClient: HubClient? = nil,
    backend: LiteRTBackend = .cpu,
    defaultModelID: String? = nil,
    policy: ModelRuntimePolicy = .default
  ) throws {
    guard catalogPersistenceURL.isFileURL else {
      throw ModelGenerationFailure(.invalidRequest, "LiteRT model catalog must use a local file URL.")
    }
    descriptor = try ModelProviderDescriptor(
      id: LiteRTProvider.providerID,
      displayName: "LiteRT-LM",
      kind: .onDevice)
    self.store = store
    client = hubClient ?? Self.makeDefaultHubClient()
    catalogURL = catalogPersistenceURL.standardizedFileURL
    self.backend = backend
    self.defaultModelID = defaultModelID
    self.policy = policy
  }

  public func inspectModel(at address: HubModelAddress) async throws -> HubModelImportCandidate? {
    #if !os(iOS) && !os(macOS)
      return nil
    #else
    let (repositoryID, revision) = try await resolve(address)
    guard let repository = Repo.ID(rawValue: repositoryID) else {
      throw HubModelAddressError.invalidAddress
    }
    let files = try await client.listFiles(in: repository, revision: revision, recursive: true)
      .filter {
        $0.type == .file && $0.path.lowercased().hasSuffix(".litertlm")
          && Self.isSafeHubPath($0.path)
      }
    guard files.count == 1, let bytes = files[0].size, bytes > 0 else { return nil }
    guard UInt64(bytes) <= Limits.maximumModelBytes else {
      throw ModelGenerationFailure(
        .invalidRequest, "The selected LiteRT-LM model exceeds the 8 GiB install limit.")
    }
    return try HubModelImportCandidate(
      backendID: hubBackendID,
      providerID: hubProviderID,
      repositoryID: repositoryID,
      revision: revision,
      displayName: repositoryID,
      artifactPaths: [files[0].path],
      totalBytes: UInt64(bytes))
    #endif
  }

  public func installModel(
    _ candidate: HubModelImportCandidate,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)?
  ) async throws -> ModelDescriptor {
    guard candidate.backendID == hubBackendID, candidate.providerID == hubProviderID,
      candidate.artifactPaths.count == 1,
      candidate.artifactPaths[0].lowercased().hasSuffix(".litertlm"),
      Self.isSafeHubPath(candidate.artifactPaths[0])
    else { throw HubModelImportError.invalidCandidate }
    try beginModelMutation()
    defer { modelMutationInProgress = false }
    try await loadCatalogIfNeeded()

    let pinned = try HubModelAddress(
      "https://huggingface.co/\(candidate.repositoryID)/commit/\(candidate.revision)")
    guard let current = try await inspectModel(at: pinned), current.id == candidate.id else {
      throw HubModelImportError.invalidCandidate
    }
    guard let repository = Repo.ID(rawValue: candidate.repositoryID) else {
      throw HubModelAddressError.invalidAddress
    }

    let modelPath = candidate.artifactPaths[0]
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(
        path: "native-agent-litert-hub-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let destination = temporaryDirectory.appending(path: modelPath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    let downloadProgress = Progress(totalUnitCount: Int64(candidate.totalBytes))
    let progressBox = LiteRTHubProgressBox(downloadProgress)
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
    guard values.isRegularFile == true, let actualSize = values.fileSize,
      actualSize >= 0, UInt64(actualSize) == candidate.totalBytes
    else {
      throw ModelGenerationFailure(
        .sourceUnavailable, "The downloaded LiteRT-LM model has an unexpected size.")
    }
    let digest = try Self.sha256(of: destination)
    guard let artifactDigest = ArtifactDigest(rawValue: digest) else {
      throw ModelGenerationFailure(
        .sourceUnavailable, "The downloaded LiteRT-LM model could not be verified.")
    }
    let manifest = try ArtifactManifest(
      artifactID: Self.artifactID(candidate),
      files: [try ArtifactEntry(
        path: modelPath, byteCount: candidate.totalBytes, sha256: artifactDigest)])
    let staging = try await store.beginStaging(for: manifest)
    do {
      try Task.checkCancellation()
      try staging.importFiles(from: temporaryDirectory)
      try Task.checkCancellation()
    } catch {
      staging.abandon()
      throw error
    }
    let lease = try await store.publish(staging)
    let id = Self.modelID(candidate)
    let model = try LiteRTTextModel(
      id: id,
      modelURL: lease.directoryURL.appending(path: modelPath),
      displayName: candidate.displayName,
      backend: backend)
    let entry = CatalogEntry(
      id: id,
      repositoryID: candidate.repositoryID,
      revision: candidate.revision,
      modelPath: modelPath,
      byteCount: candidate.totalBytes,
      manifest: manifest)
    let previousDefault = defaultModelID
    modelsByID[id] = model
    catalogEntriesByID[id] = entry
    leasesByID[id] = lease
    defaultModelID = id
    do {
      try persistCatalog()
    } catch {
      modelsByID.removeValue(forKey: id)
      catalogEntriesByID.removeValue(forKey: id)
      leasesByID.removeValue(forKey: id)?.close()
      defaultModelID = previousDefault
      do {
        try await store.remove(manifest)
      } catch {
        throw ModelGenerationFailure(
          .sourceUnavailable,
          "The LiteRT catalog write failed and the new artifact could not be rolled back.")
      }
      throw error
    }
    return LiteRTProvider.modelDescriptor(for: model)
  }

  public func availability() async throws -> ModelProviderAvailability {
    try await loadCatalogIfNeeded()
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
    try await loadCatalogIfNeeded()
    return modelsByID.values.map(LiteRTProvider.modelDescriptor(for:)).sorted { $0.id < $1.id }
  }

  public func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess {
    try await loadCatalogIfNeeded()
    guard !modelsByID.isEmpty else {
      throw ModelGenerationFailure(.sourceUnavailable, "No LiteRT-LM model has been installed.")
    }
    let selectedID = modelID ?? defaultModelID ?? modelsByID.keys.sorted()[0]
    guard let model = modelsByID[selectedID] else {
      throw ModelGenerationFailure(.invalidRequest, "Unknown LiteRT-LM model: \(selectedID)")
    }
    guard let manifest = catalogEntriesByID[selectedID]?.manifest else {
      throw ModelGenerationFailure(.sourceUnavailable, "The selected LiteRT-LM artifact manifest is missing.")
    }
    let runtimeLease = try await store.open(manifest)
    return .owned(try await LiteRTProvider.loadRuntime(
      model, policy: policy, artifactLease: runtimeLease))
  }

  private func resolve(_ address: HubModelAddress) async throws -> (String, String) {
    guard let repository = Repo.ID(rawValue: address.repositoryID),
      repository.rawValue == address.repositoryID
    else { throw HubModelAddressError.invalidAddress }
    let metadata = try await client.getModel(repository, revision: address.revision)
    guard let revision = metadata.sha, Self.isCommit(revision) else {
      throw ModelGenerationFailure(
        .sourceUnavailable, "Hugging Face did not return an immutable model revision.")
    }
    return (address.repositoryID, revision.lowercased())
  }

  private func beginModelMutation() throws {
    guard !modelMutationInProgress else {
      throw HubModelImportError.backendBusy(hubBackendID)
    }
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
      throw ModelGenerationFailure(.sourceUnavailable, "The LiteRT model catalog version is unsupported.")
    }
    var models: [String: LiteRTTextModel] = [:]
    var entries: [String: CatalogEntry] = [:]
    var leases: [String: ArtifactLease] = [:]
    do {
      for entry in archive.entries {
        guard Self.isCommit(entry.revision), Self.isSafeHubPath(entry.modelPath),
          entry.modelPath.lowercased().hasSuffix(".litertlm"), entry.byteCount > 0,
          entry.manifest.files.count == 1,
          let artifact = entry.manifest.files.first,
          artifact.path == entry.modelPath, artifact.byteCount == entry.byteCount,
          Self.isModelID(entry.id), models[entry.id] == nil
        else { throw HubModelImportError.invalidCandidate }
        _ = try HubModelAddress(entry.repositoryID)
        let candidate = try HubModelImportCandidate(
          backendID: hubBackendID,
          providerID: hubProviderID,
          repositoryID: entry.repositoryID,
          revision: entry.revision,
          displayName: entry.repositoryID,
          artifactPaths: [entry.modelPath],
          totalBytes: entry.byteCount)
        guard Self.modelID(candidate) == entry.id else {
          throw HubModelImportError.invalidCandidate
        }
        let lease = try await store.open(entry.manifest)
        let model = try LiteRTTextModel(
          id: entry.id,
          modelURL: lease.directoryURL.appending(path: entry.modelPath),
          displayName: entry.repositoryID,
          backend: backend)
        models[entry.id] = model
        entries[entry.id] = entry
        leases[entry.id] = lease
      }
    } catch {
      for lease in leases.values { lease.close() }
      throw error
    }
    let resolvedDefault = defaultModelID ?? archive.defaultModelID
    guard resolvedDefault.map({ models[$0] != nil }) ?? true else {
      for lease in leases.values { lease.close() }
      throw HubModelImportError.invalidCandidate
    }
    modelsByID = models
    catalogEntriesByID = entries
    leasesByID = leases
    defaultModelID = resolvedDefault
    catalogLoaded = true
  }

  private func persistCatalog() throws {
    let entries = catalogEntriesByID.values.sorted { $0.id < $1.id }
    guard entries.count == modelsByID.count else { throw HubModelImportError.invalidCandidate }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(
      Catalog(formatVersion: 1, defaultModelID: defaultModelID, entries: entries))
    try FileManager.default.createDirectory(
      at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: catalogURL, options: .atomic)
  }

  private static func modelID(_ candidate: HubModelImportCandidate) -> String {
    "litertlm-\(candidateDigest(candidate))"
  }

  private static func isModelID(_ value: String) -> Bool {
    value.hasPrefix("litertlm-") && value.utf8.count == "litertlm-".utf8.count + 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0) || $0 == 45
      }
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
    "litert-hub-\(candidateDigest(candidate))"
  }

  private static func candidateDigest(_ candidate: HubModelImportCandidate) -> String {
    SHA256.hash(data: Data(candidate.id.utf8))
      .map { String(format: "%02x", $0) }.joined()
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

private final class LiteRTHubProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private let progress: Progress

  init(_ progress: Progress) { self.progress = progress }

  var completedUnitCount: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return max(0, progress.completedUnitCount)
  }
}
