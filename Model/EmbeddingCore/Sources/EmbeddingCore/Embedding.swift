import Foundation

public enum EmbeddingFailure: Error, Sendable, Equatable {
  case invalidProfile
  case invalidInput
  case incompatibleProfile
  case invalidDimension
  case invalidVector
  case busy
  case closed
  case artifactMismatch
  case unsupportedHost
  case nativeFailure(code: Int)
}

/// Persist this entire value alongside an index. Equality, not a model name,
/// determines whether vectors may be compared or inserted into that index.
public struct EmbeddingProfile: Codable, Hashable, Sendable {
  public let modelID: String
  public let modelRevision: String
  public let artifactSHA256: String
  public let quantization: String
  public let runtimeRevision: String
  public let promptRevision: String
  public let inputPolicyRevision: String
  public let nativeDimensions: Int
  public let dimensions: Int
  public let normalizationRevision: String

  public init(
    modelID: String, modelRevision: String, artifactSHA256: String,
    quantization: String, runtimeRevision: String, promptRevision: String,
    inputPolicyRevision: String, nativeDimensions: Int, dimensions: Int,
    normalizationRevision: String = "prefix-then-l2-v1"
  ) throws {
    self.modelID = modelID
    self.modelRevision = modelRevision
    self.artifactSHA256 = artifactSHA256
    self.quantization = quantization
    self.runtimeRevision = runtimeRevision
    self.promptRevision = promptRevision
    self.inputPolicyRevision = inputPolicyRevision
    self.nativeDimensions = nativeDimensions
    self.dimensions = dimensions
    self.normalizationRevision = normalizationRevision
    try validate()
  }

  public func validate() throws {
    let identifiers = [modelID, modelRevision, quantization, runtimeRevision,
                       promptRevision, inputPolicyRevision]
    guard identifiers.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
      artifactSHA256.utf8.count == 64,
      artifactSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      nativeDimensions > 0, dimensions > 0, dimensions <= nativeDimensions,
      normalizationRevision == "prefix-then-l2-v1"
    else { throw EmbeddingFailure.invalidProfile }
  }

  public func requireCompatibility(with other: Self) throws {
    try validate()
    try other.validate()
    guard self == other else { throw EmbeddingFailure.incompatibleProfile }
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      modelID: values.decode(String.self, forKey: .modelID),
      modelRevision: values.decode(String.self, forKey: .modelRevision),
      artifactSHA256: values.decode(String.self, forKey: .artifactSHA256),
      quantization: values.decode(String.self, forKey: .quantization),
      runtimeRevision: values.decode(String.self, forKey: .runtimeRevision),
      promptRevision: values.decode(String.self, forKey: .promptRevision),
      inputPolicyRevision: values.decode(String.self, forKey: .inputPolicyRevision),
      nativeDimensions: values.decode(Int.self, forKey: .nativeDimensions),
      dimensions: values.decode(Int.self, forKey: .dimensions),
      normalizationRevision: values.decode(String.self, forKey: .normalizationRevision)
    )
  }
}

public enum EmbeddingInput: Sendable, Equatable {
  case query(String)
  case document(text: String, title: String? = nil)
}

/// A finite unit vector with its complete index compatibility identity.
/// Decoding also validates: persisted vectors cannot bypass these invariants.
public struct EmbeddingVector: Codable, Sendable, Equatable {
  public let profile: EmbeddingProfile
  public let values: [Float]

  /// Validates the complete native output, keeps leading MRL dimensions, then
  /// normalizes in Double precision to avoid Float overflow/underflow.
  public init(nativeValues: [Float], profile: EmbeddingProfile) throws {
    try profile.validate()
    guard nativeValues.count == profile.nativeDimensions else {
      throw EmbeddingFailure.invalidDimension
    }
    guard nativeValues.allSatisfy(\.isFinite) else { throw EmbeddingFailure.invalidVector }
    let prefix = nativeValues.prefix(profile.dimensions)
    let norm = sqrt(prefix.reduce(0.0) { $0 + Double($1) * Double($1) })
    guard norm.isFinite, norm > 0 else { throw EmbeddingFailure.invalidVector }
    self.profile = profile
    self.values = prefix.map { Float(Double($0) / norm) }
    try validate()
  }

  public func validate() throws {
    try profile.validate()
    guard values.count == profile.dimensions else { throw EmbeddingFailure.invalidDimension }
    guard values.allSatisfy(\.isFinite) else { throw EmbeddingFailure.invalidVector }
    let squaredNorm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
    guard squaredNorm > 0, abs(squaredNorm - 1) <= 0.0001 else {
      throw EmbeddingFailure.invalidVector
    }
  }

  /// Call this before storing a vector in an existing index.
  public func validate(for indexProfile: EmbeddingProfile) throws {
    try validate()
    try indexProfile.requireCompatibility(with: profile)
  }

  public func cosineSimilarity(to other: Self) throws -> Double {
    try validate()
    try other.validate(for: profile)
    return zip(values, other.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profile = try container.decode(EmbeddingProfile.self, forKey: .profile)
    values = try container.decode([Float].self, forKey: .values)
    try validate()
  }
}

/// One host-selected local embedding resident. Cancellation must join native
/// work before returning; shutdown stops admission, drains, then frees resources.
/// Callers share the same instance and the host alone calls shutdown.
public protocol EmbeddingModel: Sendable {
  var profile: EmbeddingProfile { get }
  func embed(_ input: EmbeddingInput) async throws -> EmbeddingVector
  func shutdown() async throws
}
