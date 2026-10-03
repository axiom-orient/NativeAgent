import Foundation
import LanguageModelCore

public enum LiteRTBackend: String, Codable, Hashable, Sendable {
  case cpu
  case gpu
}

public enum LiteRTSampling: String, Codable, Hashable, Sendable {
  case modelDefault
  case greedy
}

/// One explicitly selected local LiteRT-LM text model.
///
/// The caller owns acquisition of `modelURL`. This provider never downloads,
/// searches for, or silently substitutes model artifacts.
public struct LiteRTTextModel: Hashable, Sendable {
  /// Enable only for an artifact whose template and native parser support tools.
  public let supportsToolCalls: Bool
  public var capabilities: ModelCapabilities {
    supportsToolCalls ? LiteRTProvider.capabilities : [.textInput, .textOutput, .structuredOutput]
  }
  public let sampling: LiteRTSampling
  public let id: String
  public let modelURL: URL
  public let displayName: String?
  public let backend: LiteRTBackend
  public let contextWindowTokens: Int?
  public let cacheDirectoryURL: URL?

  public init(
    id: String,
    modelURL: URL,
    displayName: String? = nil,
    backend: LiteRTBackend = .cpu,
    contextWindowTokens: Int? = nil,
    cacheDirectoryURL: URL? = nil,
    sampling: LiteRTSampling = .modelDefault,
    supportsToolCalls: Bool = false
  ) throws {
    let descriptor = ModelDescriptor(
      id: id,
      providerID: LiteRTProvider.providerID,
      displayName: displayName,
      capabilities: LiteRTProvider.capabilities,
      contextWindowTokens: contextWindowTokens
    )
    try descriptor.validateGenerationContract()
    guard modelURL.isFileURL,
      cacheDirectoryURL.map(\.isFileURL) ?? true
    else {
      throw ModelGenerationFailure(
        .invalidRequest,
        "LiteRT-LM model and cache locations must be local file URLs."
      )
    }
    self.supportsToolCalls = supportsToolCalls
    self.sampling = sampling
    self.id = id
    self.modelURL = modelURL.standardizedFileURL
    self.displayName = displayName
    self.backend = backend
    self.contextWindowTokens = contextWindowTokens
    self.cacheDirectoryURL = cacheDirectoryURL?.standardizedFileURL
  }
}
