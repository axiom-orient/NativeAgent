import LanguageModelCore
import LanguageModelRuntime
import ModelHub
import Testing

@Suite("Hugging Face model onboarding")
struct HubModelInstallerTests {
  private struct StubBackend: HubModelImportBackend {
    let hubBackendID: String
    let hubProviderID: String
    let path: String
    let revision: String

    func inspectModel(at address: HubModelAddress) async throws -> HubModelImportCandidate? {
      guard address.repositoryID == "acme/model" else { return nil }
      return try HubModelImportCandidate(
        backendID: hubBackendID,
        providerID: hubProviderID,
        repositoryID: address.repositoryID,
        revision: revision,
        displayName: hubBackendID,
        artifactPaths: [path],
        totalBytes: 128)
    }

    func installModel(
      _ candidate: HubModelImportCandidate,
      progress: (@Sendable (HubModelDownloadProgress) -> Void)?
    ) async throws -> ModelDescriptor {
      ModelDescriptor(id: candidate.id, providerID: hubProviderID, displayName: hubBackendID)
    }
  }

  @Test("automatically installs when exactly one backend accepts the repository")
  func installsUniqueBackend() async throws {
    let backend = StubBackend(
      hubBackendID: "mlx", hubProviderID: "mlx.text", path: "model.safetensors",
      revision: String(repeating: "a", count: 40))
    let installer = try HubModelInstaller(backends: [backend])
    let installed = try await installer.install(from: "acme/model")
    #expect(installed.providerID == "mlx.text")
  }

  @Test("returns explicit backend choices instead of guessing for mixed repositories")
  func mixedRepositoryRequiresChoice() async throws {
    let revision = String(repeating: "c", count: 40)
    let installer = try HubModelInstaller(backends: [
      StubBackend(
        hubBackendID: "mlx", hubProviderID: "mlx.text", path: "model.safetensors",
        revision: revision),
      StubBackend(
        hubBackendID: "litert-lm", hubProviderID: "litert-lm.text", path: "model.litertlm",
        revision: revision),
    ])
    do {
      _ = try await installer.install(from: "acme/model")
      Issue.record("Expected an explicit backend choice.")
    } catch let error as HubModelImportError {
      guard case .backendSelectionRequired(let options) = error else {
        Issue.record("Unexpected model-import error: \(error)")
        return
      }
      #expect(options.map(\.backendID).sorted() == ["litert-lm", "mlx"])
    }
  }

  @Test("rejects repositories unsupported by every registered provider")
  func rejectsUnsupportedRepository() async throws {
    let backend = StubBackend(
      hubBackendID: "mlx", hubProviderID: "mlx.text", path: "model.safetensors",
      revision: String(repeating: "d", count: 40))
    let installer = try HubModelInstaller(backends: [backend])
    do {
      _ = try await installer.install(from: "other/model")
      Issue.record("Expected the unsupported-model result.")
    } catch let error as HubModelImportError {
      #expect(error == .unsupportedModel)
    }
  }

  @Test("accepts model pages and pins supported revision syntax")
  func parsesModelPage() throws {
    let latest = try HubModelAddress("https://huggingface.co/acme/model")
    #expect(latest.repositoryID == "acme/model")
    #expect(latest.revision == nil)

    let commit = String(repeating: "a", count: 40)
    let pinned = try HubModelAddress("huggingface.co/acme/model/commit/\(commit)")
    #expect(pinned.repositoryID == "acme/model")
    #expect(pinned.revision == commit)
    #expect(pinned.pageAddress.hasSuffix("/commit/\(commit)"))
  }

  @Test("uses one strict repository identity contract for addresses and candidates")
  func repositoryIdentityContractIsShared() throws {
    let invalidRepositoryIDs = [
      ".owner/model",
      "owner-/model",
      "owner/model.git",
      "owner/model--variant",
      "owner/model..variant",
      "owner/" + String(repeating: "a", count: 91),
    ]

    for repositoryID in invalidRepositoryIDs {
      #expect(throws: HubModelAddressError.invalidAddress) {
        try HubModelAddress(repositoryID)
      }
      #expect(throws: HubModelImportError.invalidCandidate) {
        try HubModelImportCandidate(
          backendID: "mlx",
          providerID: "mlx.text",
          repositoryID: repositoryID,
          revision: String(repeating: "a", count: 40),
          displayName: "Fixture",
          artifactPaths: ["model.safetensors"],
          totalBytes: 128
        )
      }
    }
  }

  @Test("candidate identity includes the provider authority")
  func candidateIdentityIncludesProvider() throws {
    let revision = String(repeating: "a", count: 40)
    let first = try HubModelImportCandidate(
      backendID: "runtime", providerID: "provider.one", repositoryID: "acme/model",
      revision: revision, displayName: "Fixture", artifactPaths: ["model.bin"], totalBytes: 128)
    let second = try HubModelImportCandidate(
      backendID: "runtime", providerID: "provider.two", repositoryID: "acme/model",
      revision: revision, displayName: "Fixture", artifactPaths: ["model.bin"], totalBytes: 128)

    #expect(first.id != second.id)
  }

  @Test("candidate identity cannot collide through artifact path delimiters")
  func candidateIdentityIsUnambiguous() throws {
    let revision = String(repeating: "a", count: 40)
    let first = try HubModelImportCandidate(
      backendID: "mlx", providerID: "mlx.text", repositoryID: "acme/model",
      revision: revision, displayName: "Fixture", artifactPaths: ["a,b", "c"], totalBytes: 128)
    let second = try HubModelImportCandidate(
      backendID: "mlx", providerID: "mlx.text", repositoryID: "acme/model",
      revision: revision, displayName: "Fixture", artifactPaths: ["a", "b,c"], totalBytes: 128)

    #expect(first.id != second.id)
  }

  @Test("rejects unsafe or non-Hugging-Face addresses")
  func rejectsUnsafeAddresses() {
    for address in [
      "http://huggingface.co/acme/model",
      "https://huggingface.co/acme/model?download=true",
      "https://example.com/acme/model",
      "https://huggingface.co/acme/%2e%2e",
      "https://huggingface.co/acme/model/commit/main",
      "https://huggingface.co/acme/model/tree/.hidden",
      "https://huggingface.co/acme/model/tree/release.lock",
      "https://huggingface.co/acme/model/tree/feature/.hidden",
    ] {
      #expect(throws: HubModelAddressError.invalidAddress) {
        try HubModelAddress(address)
      }
    }
  }
}
