import MLXModelRegistry
import Testing

struct MLXModelRegistryTests {
  @Test func modelAddressAcceptsRepositoryAndHuggingFacePageURLs() throws {
    let repository = try MLXHubModelAddress("mlx-community/example")
    #expect(repository.repositoryID == "mlx-community/example")
    #expect(repository.revision == nil)

    let page = try MLXHubModelAddress("https://huggingface.co/mlx-community/example/")
    #expect(page.repositoryID == repository.repositoryID)
    #expect(page.revision == nil)

    let branch = try MLXHubModelAddress(
      "https://huggingface.co/mlx-community/example/tree/refs%2Fpr%2F42")
    #expect(branch.repositoryID == repository.repositoryID)
    #expect(branch.revision == "refs/pr/42")
  }

  @Test func modelAddressRejectsNonHubAndUnsafeURLs() {
    for address in [
      "http://huggingface.co/mlx-community/example",
      "https://example.com/mlx-community/example",
      "https://huggingface.co/mlx-community/example?token=secret",
      "https://huggingface.co/mlx-community/../example",
      "mlx-community//example",
      "https://huggingface.co/mlx-community/example/blob/main/config.json",
    ] {
      #expect(throws: MLXHubModelError.invalidAddress) {
        _ = try MLXHubModelAddress(address)
      }
    }
  }

  @Test func referenceRequiresImmutableCommit() throws {
    let reference = try MLXHubReference(
      repositoryID: "mlx-community/example", revision: String(repeating: "a", count: 40))
    #expect(reference.revision.count == 40)
    #expect(throws: MLXHubModelError.invalidReference) {
      _ = try MLXHubReference(repositoryID: "mlx-community/example", revision: "main")
    }
  }

  @Test func policiesNormalizeExtensions() throws {
    let policy = try MLXHubFilePolicy(
      identifier: "test", allowedExtensions: ["json"], requiredPaths: ["config.json"])
    #expect(policy.allowedExtensions == [".json"])
  }
}
