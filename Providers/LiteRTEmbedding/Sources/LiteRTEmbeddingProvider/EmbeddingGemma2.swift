import EmbeddingCore
import Foundation
import LiteRTNative

/// Qualified generic CPU artifact; SoC variants, Gemma 1, other dimensions and
/// prompt dialects require a different profile and an explicitly rebuilt index.
public enum EmbeddingGemma2 {
  public static let artifactByteCount = 164_626_432
  public static let artifactSHA256 = "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb"
  public static let repositoryRevision = "9be6e8b90982095dc05c2bd162e4b954ee4dbac7"
  public static let maximumInputTokens = 1024
  public static let profile: EmbeddingProfile = {
    // All arguments are checked constants, not caller-controlled configuration.
    try! EmbeddingProfile(
      modelID: "google/embeddinggemma-2/text-270m",
      modelRevision: repositoryRevision, artifactSHA256: artifactSHA256,
      quantization: "generic-int4-weights-float32-activations-cpu",
      runtimeRevision: "litert-lm-\(LiteRTNativeRuntime.version)-cpu",
      promptRevision: "google-model-card-2-20261006-search-v1",
      inputPolicyRevision: "trim-bos-eos-max1024-overflow-error-v1",
      nativeDimensions: 768, dimensions: 256
    )
  }()

  public static func formattedText(for input: EmbeddingInput) throws -> String {
    func clean(_ value: String) throws -> String {
      guard !value.contains("\0") else { throw EmbeddingFailure.invalidInput }
      let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !result.isEmpty else { throw EmbeddingFailure.invalidInput }
      return result
    }
    switch input {
    case .query(let query):
      return "task: search result | query: \(try clean(query))"
    case .document(let text, let title):
      let heading = try title.map(clean) ?? "none"
      return "title: \(heading) | text: \(try clean(text))"
    }
  }
}
