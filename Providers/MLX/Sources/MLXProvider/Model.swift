import ModelArtifactStore
import MLXModelRegistry
import Foundation

/// Runtime model configuration. The package owns no model catalog or file manifest.
public struct MLXModel: Codable, Hashable, Sendable {
  public let repositoryID: String
  public let revision: String
  public let extraEOSTokens: Set<String>
  public let disablesThinking: Bool
  public let sampling: MLXSampling

  public init(
    repositoryID: String,
    revision: String,
    extraEOSTokens: Set<String> = [],
    disablesThinking: Bool = false,
    sampling: MLXSampling = .default
  ) throws {
    do { _ = try MLXHubReference(repositoryID: repositoryID, revision: revision) } catch {
      throw MLXTextError.invalidModel
    }
    guard sampling.isValid else { throw MLXTextError.invalidModel }
    guard extraEOSTokens.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
      throw MLXTextError.invalidModel
    }
    self.repositoryID = repositoryID
    self.revision = revision.lowercased()
    self.extraEOSTokens = extraEOSTokens
    self.disablesThinking = disablesThinking
    self.sampling = sampling
  }

  private enum CodingKeys: String, CodingKey {
    case repositoryID
    case revision
    case extraEOSTokens
    case disablesThinking
    case sampling
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(repositoryID, forKey: .repositoryID)
    try container.encode(revision, forKey: .revision)
    try container.encode(extraEOSTokens.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, forKey: .extraEOSTokens)
    try container.encode(disablesThinking, forKey: .disablesThinking)
    try container.encode(sampling, forKey: .sampling)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      repositoryID: container.decode(String.self, forKey: .repositoryID),
      revision: container.decode(String.self, forKey: .revision),
      extraEOSTokens: container.decode(Set<String>.self, forKey: .extraEOSTokens),
      disablesThinking: container.decode(Bool.self, forKey: .disablesThinking),
      sampling: container.decode(MLXSampling.self, forKey: .sampling))
  }

  public var hubReference: MLXHubReference {
    try! MLXHubReference(repositoryID: repositoryID, revision: revision)
  }
}

struct MLXModelSpecification: Codable, Hashable, Sendable {
  let model: MLXModel
  let repositoryID: String
  let revision: String
  let manifest: ArtifactManifest
  let extraEOSTokens: Set<String>
  let disablesThinking: Bool
  let sampling: MLXSampling

  init(
    model: MLXModel,
    resolvedReference: MLXHubReference,
    resolvedManifest: ArtifactManifest
  ) throws {
    guard resolvedReference.repositoryID == model.repositoryID,
      resolvedReference.revision == model.revision
    else { throw MLXTextError.invalidModel }
    self.model = model
    self.repositoryID = resolvedReference.repositoryID
    self.revision = resolvedReference.revision
    self.manifest = resolvedManifest
    self.extraEOSTokens = model.extraEOSTokens
    self.disablesThinking = model.disablesThinking
    self.sampling = model.sampling
  }

  init(
    model: MLXModel, repositoryID: String, revision: String,
    files: [ArtifactEntry], extraEOSTokens: Set<String>, disablesThinking: Bool,
    sampling: MLXSampling
  ) throws {
    guard repositoryID == model.repositoryID, revision == model.revision else {
      throw MLXTextError.invalidModel
    }
    self.model = model
    self.repositoryID = repositoryID
    self.revision = revision
    self.manifest = try ArtifactManifest(
      artifactID: "mlx-" + repositoryID.replacingOccurrences(of: "/", with: "-") + "-" + revision,
      files: files)
    self.extraEOSTokens = extraEOSTokens
    self.disablesThinking = disablesThinking
    self.sampling = sampling
  }
}

public struct MLXSampling: Codable, Hashable, Sendable {
  public let temperature: Float
  public let topP: Float
  public let topK: Int
  public let repetitionPenalty: Float

  public init(temperature: Float, topP: Float, topK: Int, repetitionPenalty: Float) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.repetitionPenalty = repetitionPenalty
  }

  var isValid: Bool {
    temperature.isFinite && temperature >= 0 && topP.isFinite && topP > 0 && topP <= 1
      && topK >= 0 && repetitionPenalty.isFinite && repetitionPenalty > 0
  }

  public static let `default` = Self(
    temperature: 0.7, topP: 0.8, topK: 20, repetitionPenalty: 1.05)
}

public struct MLXDownloadProgress: Hashable, Sendable {
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let currentFile: String?

  public init(completedBytes: UInt64, totalBytes: UInt64, currentFile: String?) {
    self.completedBytes = completedBytes
    self.totalBytes = totalBytes
    self.currentFile = currentFile
  }
}

public enum MLXPins {
  public static let mlxSwift = "0.31.6"
  public static let mlxSwiftLM = "e3d4a20e9e20e7b8ab39aded7bbfad4ae22c9438"
  public static let swiftHuggingFace = "0.9.0"
  public static let swiftTransformers = "1.3.3"
}
