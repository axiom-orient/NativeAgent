import Foundation
import HuggingFace
import ModelArtifactStore

extension EmbeddingGemma2 {
  public static let repositoryID = "litert-community/embeddinggemma-2-text-270m-litert-lm"
  public static let artifactFilename = "embeddinggemma-2-text-270m.litertlm"
  public static let artifactManifest: ArtifactManifest = {
    try! ArtifactManifest(
      artifactID: "embeddinggemma2-text-270m-" + repositoryRevision,
      files: [try! ArtifactEntry(path: artifactFilename, byteCount: UInt64(artifactByteCount),
        sha256: ArtifactDigest(rawValue: artifactSHA256)!)]
    )
  }()

  /// Explicitly prepares the immutable artifact. A valid cached artifact needs
  /// no network. Corrupt cache and I/O errors propagate; only absence downloads.
  public static func prepare(in store: ModelArtifactStore) async throws {
    try await prepare(in: store) { destination in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      let session = URLSession(configuration: configuration)
      defer { session.finishTasksAndInvalidate() }
      let client = HubClient(session: session,
        host: HubClient.defaultHost, bearerToken: nil, cache: nil)
      _ = try await client.downloadFile(at: artifactFilename,
        from: Repo.ID(rawValue: repositoryID)!, to: destination,
        revision: repositoryRevision, cachePolicy: .reloadIgnoringLocalCacheData,
        transport: .lfs)
    }
  }

  /// Imports the exact artifact from an existing local directory without network.
  public static func importArtifact(from directory: URL, into store: ModelArtifactStore) async throws {
    try Task.checkCancellation()
    let staging = try await store.beginStaging(for: artifactManifest)
    do {
      try staging.importFiles(from: directory)
      try Task.checkCancellation()
      let lease = try await store.publish(staging)
      lease.close()
      try Task.checkCancellation()
    } catch { staging.abandon(); throw error }
  }

  static func prepare(
    in store: ModelArtifactStore,
    download: @Sendable (URL) async throws -> Void
  ) async throws {
    try Task.checkCancellation()
    do {
      let cached = try await store.open(artifactManifest)
      cached.close()
      try Task.checkCancellation()
      return
    } catch ArtifactStoreError.missingFile { }
    try Task.checkCancellation()
    let staging = try await store.beginStaging(for: artifactManifest)
    do {
      try await download(staging.directoryURL.appendingPathComponent(artifactFilename))
      try Task.checkCancellation()
      let lease = try await store.publish(staging)
      lease.close()
      try Task.checkCancellation()
    } catch { staging.abandon(); throw error }
  }
}
