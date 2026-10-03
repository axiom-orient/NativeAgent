import ModelArtifactStore
import CryptoKit
import Foundation
import HuggingFace

public enum MLXHubModelError: Error, Equatable, Sendable {
  case invalidAddress
  case invalidReference
  case repositoryNotFound
  case authenticationRequired
  case hubUnavailable
  case unresolvedRevision
  case emptyModel
  case requiredFileMissing
  case unsupportedFile
  case invalidFile
  case fileLimitExceeded
  case insufficientDisk
}

/// An immutable Hugging Face model identity. Floating branches are deliberately rejected.
public struct MLXHubReference: Codable, Hashable, Sendable {
  public static let maximumRepositoryPartUTF8Bytes = 96
  public static let gitCommitHexCharacters = 40

  public let repositoryID: String
  public let revision: String

  public init(repositoryID: String, revision: String) throws {
    let parts = repositoryID.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumRepositoryPartUTF8Bytes }),
      repositoryID == "\(parts[0])/\(parts[1])",
      parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("..") }),
      revision.utf8.count == Self.gitCommitHexCharacters,
      revision.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
      })
    else { throw MLXHubModelError.invalidReference }
    self.repositoryID = repositoryID
    self.revision = revision.lowercased()
  }
}

/// File selection is a backend contract, not a model manifest. It lets a model change within a
/// supported MLX family without changing package code while preventing unrelated repo files from
/// entering the app sandbox.
public struct MLXHubFilePolicy: Hashable, Sendable {
  public static let standardMaximumFiles = 4_096
  public static let standardMaximumTotalBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
  public static let maximumIdentifierUTF8Bytes = 32
  public static let supportedMaximumFiles = 100_000

  public let identifier: String
  public let allowedExtensions: Set<String>
  public let requiredPaths: Set<String>
  public let requiredExtensions: Set<String>
  public let maxFiles: Int
  public let maxTotalBytes: UInt64

  public init(
    identifier: String,
    allowedExtensions: Set<String>,
    requiredPaths: Set<String> = [],
    requiredExtensions: Set<String> = [],
    maxFiles: Int = Self.standardMaximumFiles,
    maxTotalBytes: UInt64 = Self.standardMaximumTotalBytes
  ) throws {
    let normalizedExtensions = Set(
      allowedExtensions.map {
        $0.lowercased().hasPrefix(".") ? $0.lowercased() : ".\($0.lowercased())"
      })
    guard !identifier.isEmpty, identifier.utf8.count <= Self.maximumIdentifierUTF8Bytes,
      identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
      !normalizedExtensions.isEmpty, (1...Self.supportedMaximumFiles).contains(maxFiles),
      maxTotalBytes > 0
    else { throw MLXHubModelError.invalidReference }
    self.identifier = identifier
    self.allowedExtensions = normalizedExtensions
    self.requiredPaths = requiredPaths
    self.requiredExtensions = Set(
      requiredExtensions.map {
        $0.lowercased().hasPrefix(".") ? $0.lowercased() : ".\($0.lowercased())"
      })
    self.maxFiles = maxFiles
    self.maxTotalBytes = maxTotalBytes
  }

  public static let mlxText = try! Self(
    identifier: "text",
    allowedExtensions: [".json", ".jinja", ".txt", ".model", ".safetensors"],
    requiredPaths: ["config.json"],
    requiredExtensions: [".safetensors"])

  public static let mlxVision = try! Self(
    identifier: "vision",
    allowedExtensions: [".json", ".jinja", ".txt", ".model", ".safetensors"],
    requiredPaths: ["config.json"],
    requiredExtensions: [".safetensors"])

  public static let mlxAudio = try! Self(
    identifier: "audio",
    allowedExtensions: [".json", ".jinja", ".txt", ".model", ".safetensors"],
    requiredPaths: ["config.json"],
    requiredExtensions: [".safetensors"])

  public static let onnxAudio = try! Self(
    identifier: "onnx-audio",
    allowedExtensions: [".json", ".onnx"],
    requiredPaths: ["onnx/tts.json"],
    requiredExtensions: [".onnx"])
}

public struct MLXHubDownloadProgress: Hashable, Sendable {
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let currentFile: String?
}

public struct MLXResolvedArtifact: Hashable, Sendable {
  public let reference: MLXHubReference
  public let manifest: ArtifactManifest
}

public struct MLXHubModelInspection: Hashable, Sendable {
  public let reference: MLXHubReference
  public let filePaths: [String]
  public let totalBytes: UInt64

  public init(reference: MLXHubReference, filePaths: [String], totalBytes: UInt64) {
    self.reference = reference
    self.filePaths = filePaths
    self.totalBytes = totalBytes
  }
}

public struct MLXHubArtifactResolver: Sendable {
  private enum Limits {
    static let minimumFreeSpaceReserveBytes: UInt64 = 128 * 1_024 * 1_024
    static let maximumRemotePathUTF8Bytes = 4_096
    static let hashReadChunkBytes = 1 * 1_024 * 1_024
    static let progressPollInterval: Duration = .milliseconds(400)
  }

  private let client: HubClient

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    client = HubClient(
      session: URLSession(configuration: configuration),
      host: HubClient.defaultHost,
      bearerToken: nil,
      cache: nil)
  }

  /// Creates a resolver with a caller-configured client, including authentication for gated
  /// repositories. The resolver still accepts only Hugging Face model-page addresses.
  public init(hubClient: HubClient) {
    self.client = hubClient
  }

  /// Resolves a branch, tag, or repository page to the exact commit that will be downloaded.
  /// Supplying a commit URL avoids the metadata request.
  public func resolveReference(for address: MLXHubModelAddress) async throws -> MLXHubReference {
    guard let repository = Repo.ID(rawValue: address.repositoryID),
      repository.rawValue == address.repositoryID
    else { throw MLXHubModelError.invalidAddress }

    if let revision = address.revision,
      revision.utf8.count == MLXHubReference.gitCommitHexCharacters,
      revision.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
      })
    {
      return try MLXHubReference(repositoryID: address.repositoryID, revision: revision)
    }

    let model: HuggingFace.Model
    do {
      model = try await client.getModel(repository, revision: address.revision)
    } catch {
      throw Self.classifyHubError(error)
    }
    guard let revision = model.sha else { throw MLXHubModelError.unresolvedRevision }
    do {
      return try MLXHubReference(repositoryID: address.repositoryID, revision: revision)
    } catch {
      throw MLXHubModelError.unresolvedRevision
    }
  }

  /// Checks whether a pinned repository contains the file layout required by a backend policy.
  /// This performs metadata lookup only; it never downloads model weights.
  public func inspect(
    reference: MLXHubReference,
    policy: MLXHubFilePolicy
  ) async throws -> MLXHubModelInspection? {
    guard let repository = Repo.ID(rawValue: reference.repositoryID) else {
      throw MLXHubModelError.invalidReference
    }
    let tree: [Git.TreeEntry]
    do {
      tree = try await client.modelTree(repository, revision: reference.revision)
    } catch {
      throw Self.classifyHubError(error)
    }
    let files: [Git.TreeEntry]
    do {
      files = try selectFiles(tree, policy: policy)
    } catch MLXHubModelError.emptyModel, MLXHubModelError.requiredFileMissing {
      return nil
    }
    var totalBytes: UInt64 = 0
    for file in files {
      guard let size = file.size, size >= 0, UInt64(size) <= policy.maxTotalBytes else {
        throw MLXHubModelError.fileLimitExceeded
      }
      let (next, overflow) = totalBytes.addingReportingOverflow(UInt64(size))
      guard !overflow, next <= policy.maxTotalBytes else {
        throw MLXHubModelError.fileLimitExceeded
      }
      totalBytes = next
    }
    return MLXHubModelInspection(
      reference: reference,
      filePaths: files.map(\.path),
      totalBytes: totalBytes)
  }

  /// Resolves the immutable tree, downloads only policy-approved files, hashes them, and publishes
  /// one verified artifact. The model adapter never receives a partially downloaded directory.
  public func materialize(
    reference: MLXHubReference,
    policy: MLXHubFilePolicy,
    store: ModelArtifactStore,
    progress: (@Sendable (MLXHubDownloadProgress) -> Void)? = nil
  ) async throws -> MLXResolvedArtifact {
    guard let repository = Repo.ID(rawValue: reference.repositoryID) else {
      throw MLXHubModelError.invalidReference
    }
    let tree: [Git.TreeEntry]
    do {
      tree = try await client.modelTree(repository, revision: reference.revision)
    } catch {
      throw Self.classifyHubError(error)
    }
    let files = try selectFiles(tree, policy: policy)
    var totalBytes: UInt64 = 0
    for file in files {
      guard let size = file.size, size >= 0, UInt64(size) <= policy.maxTotalBytes else {
        throw MLXHubModelError.fileLimitExceeded
      }
      let (next, overflow) = totalBytes.addingReportingOverflow(UInt64(size))
      guard !overflow, next <= policy.maxTotalBytes else {
        throw MLXHubModelError.fileLimitExceeded
      }
      totalBytes = next
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(path: "native-agent-mlx-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let available = try temporaryDirectory.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage
    let (downloadAndPublishBytes, overflow) = totalBytes.addingReportingOverflow(totalBytes)
    guard !overflow, let available, available >= 0,
      UInt64(available) >= downloadAndPublishBytes + Limits.minimumFreeSpaceReserveBytes
    else { throw MLXHubModelError.insufficientDisk }

    var entries: [ArtifactEntry] = []
    var completed: UInt64 = 0
    progress?(.init(completedBytes: 0, totalBytes: totalBytes, currentFile: nil))
    for file in files {
      try Task.checkCancellation()
      let destination = temporaryDirectory.appending(path: file.path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      progress?(.init(completedBytes: completed, totalBytes: totalBytes, currentFile: file.path))
      // swift-huggingface mutates a caller-supplied Foundation Progress with
      // live byte counts but never calls back; without this poll the UI shows
      // one frozen "current file" line for the entire multi-hundred-MB
      // transfer, which users read as a stalled download.
      let fileProgress = Progress()
      let progressBox = MLXProgressBox(fileProgress)
      let filePath = file.path
      let baseCompleted = completed
      let monitor = Task {
        var lastReported = Int64(0)
        while !Task.isCancelled {
          let current = progressBox.completedUnitCount
          if current > lastReported {
            lastReported = current
            progress?(
              .init(
                completedBytes: baseCompleted + UInt64(current),
                totalBytes: totalBytes, currentFile: filePath))
          }
          try? await Task.sleep(for: Limits.progressPollInterval)
        }
      }
      do {
        _ = try await client.downloadFile(
          at: file.path,
          from: repository,
          to: destination,
          revision: reference.revision,
          cachePolicy: .reloadIgnoringLocalCacheData,
          progress: fileProgress,
          transport: .lfs)
      } catch {
        monitor.cancel()
        throw error
      }
      monitor.cancel()
      let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, values.fileSize == file.size else {
        throw MLXHubModelError.invalidFile
      }
      let digest = try sha256(of: destination)
      guard let artifactDigest = ArtifactDigest(rawValue: digest) else {
        throw MLXHubModelError.invalidFile
      }
      entries.append(
        try ArtifactEntry(
          path: file.path, byteCount: UInt64(file.size ?? 0), sha256: artifactDigest))
      completed += UInt64(file.size ?? 0)
    }

    let manifest = try ArtifactManifest(
      artifactID: artifactID(reference: reference, policy: policy),
      files: entries.sorted { $0.path < $1.path })
    let staging = try await store.beginStaging(for: manifest)
    do {
      try staging.importFiles(from: temporaryDirectory)
      let lease = try await store.publish(staging)
      lease.close()
    } catch {
      staging.abandon()
      throw error
    }
    progress?(.init(completedBytes: completed, totalBytes: totalBytes, currentFile: nil))
    return .init(reference: reference, manifest: manifest)
  }

  private func selectFiles(
    _ tree: [Git.TreeEntry], policy: MLXHubFilePolicy
  ) throws -> [Git.TreeEntry] {
    let files = tree.filter { entry in
      guard entry.type == .file, let size = entry.size, size >= 0,
        entry.path.utf8.count <= Limits.maximumRemotePathUTF8Bytes,
        !entry.path.hasPrefix("."),
        !entry.path.split(separator: "/").contains(where: { $0.hasPrefix(".") })
      else { return false }
      let lower = entry.path.lowercased()
      if lower.hasSuffix(".md") || lower.hasSuffix(".html") || lower.hasSuffix(".py") {
        return false
      }
      return policy.allowedExtensions.contains { lower.hasSuffix($0) }
    }.sorted { $0.path < $1.path }
    guard !files.isEmpty, files.count <= policy.maxFiles else {
      throw MLXHubModelError.emptyModel
    }
    let paths = Set(files.map(\.path))
    guard policy.requiredPaths.isSubset(of: paths) else {
      throw MLXHubModelError.requiredFileMissing
    }
    guard
      policy.requiredExtensions.isEmpty
        || policy.requiredExtensions.contains(where: { ext in
          files.contains { $0.path.lowercased().hasSuffix(ext) }
        })
    else { throw MLXHubModelError.requiredFileMissing }
    return files
  }

  private func artifactID(reference: MLXHubReference, policy: MLXHubFilePolicy) -> String {
    let digest = SHA256.hash(
      data: Data("\(reference.repositoryID)@\(reference.revision)#\(policy.identifier)".utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
    return "mlx-\(policy.identifier)-\(digest)"
  }

  private static func classifyHubError(_ error: any Error) -> MLXHubModelError {
    guard let error = error as? HTTPClientError else { return .hubUnavailable }
    switch error {
    case .responseError(let response, _), .decodingError(let response, _):
      if response.statusCode == 401 || response.statusCode == 403 { return .authenticationRequired }
      if response.statusCode == 404 { return .repositoryNotFound }
      return .hubUnavailable
    case .requestError(_), .unexpectedError(_):
      return .hubUnavailable
    }
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: Limits.hashReadChunkBytes) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Foundation `Progress` is mutated from the download session's internal
/// threads and is not Sendable; this box makes the byte count readable from a
/// polling task under strict concurrency without touching the object itself.
private final class MLXProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private let progress: Progress

  init(_ progress: Progress) { self.progress = progress }

  var completedUnitCount: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return max(0, progress.completedUnitCount)
  }
}
