import Foundation
import LanguageModelCore
import ModelArtifactStore
import ModelHub
import Testing

@testable import LEAPProvider

@Suite struct LeapInstallationOwnershipTests {
  @Test func repeatedInstallCatalogFailurePreservesPriorEntryBytesAndCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "leap-install-ownership-\(UUID().uuidString)", directoryHint: .isDirectory)
    let catalogDirectory = root.appending(path: "catalog", directoryHint: .isDirectory)
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: catalogDirectory.path)
      try? FileManager.default.removeItem(at: root)
    }
    let payload = Data("verified model bytes".utf8)
    let modelPath = "LFM2-Q4_0.gguf"
    try payload.write(to: source.appending(path: modelPath))
    let candidate = try HubModelImportCandidate(
      backendID: "leap-lfm", providerID: "leap.text", repositoryID: "fixture/LFM2",
      revision: String(repeating: "a", count: 40), displayName: "Prior install",
      artifactPaths: [modelPath], totalBytes: UInt64(payload.count))
    let store = try ModelArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory), minimumFreeBytes: 0)
    #expect(!ProcessResidency.shared.isPoisoned(), "Prior poisoning tests must run in a separate process from catalog I/O tests.")
    let runtime = LeapRuntime(store: store)
    let catalogURL = catalogDirectory.appending(path: "models.json")
    let connector = try LEAPHuggingFaceModelProviderConnector(
      runtime: runtime, catalogPersistenceURL: catalogURL)
    #expect(try await connector.models().isEmpty)

    let installed = try await connector.installDownloadedModel(candidate, from: source)
    let priorCatalog = try Data(contentsOf: catalogURL)
    let priorModels = try await connector.models()
    #expect(priorModels.map(\.id) == [installed.id])
    let artifactFiles = try artifactPayloads(in: root.appending(path: "artifacts/artifacts"))
    #expect(artifactFiles.count == 1)
    let artifactURL = try #require(artifactFiles.first)
    #expect(try Data(contentsOf: artifactURL) == payload)

    // Atomic replacement needs to create a file in the parent directory.
    // Make that real filesystem write fail while the prior catalog stays readable.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: catalogDirectory.path)
    do {
      _ = try await connector.installDownloadedModel(candidate, from: source)
      Issue.record("The catalog write unexpectedly succeeded in its read-only directory.")
    } catch {
      let failure = error as NSError
      #expect(failure.domain == NSCocoaErrorDomain)
      #expect(failure.code == NSFileWriteNoPermissionError)
    }
    #expect(try await connector.models() == priorModels)
    #expect(try Data(contentsOf: catalogURL) == priorCatalog)
    #expect(try Data(contentsOf: artifactURL) == payload)
  }

  private func artifactPayloads(in root: URL) throws -> [URL] {
    let enumerator = try #require(FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    return try enumerator.compactMap { entry in
      guard let url = entry as? URL, url.pathExtension == "gguf" else { return nil }
      return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
    }
  }
}
