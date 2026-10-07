import Foundation

public struct EmbeddingRecord: Codable, Sendable, Equatable {
  public let id: String
  public let vector: EmbeddingVector
  public init(id: String, vector: EmbeddingVector) throws {
    guard !id.isEmpty, id.utf8.count <= 1024, !id.contains("\0") else {
      throw EmbeddingFailure.invalidInput
    }
    try vector.validate()
    self.id = id
    self.vector = vector
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(id: c.decode(String.self, forKey: .id), vector: c.decode(EmbeddingVector.self, forKey: .vector))
  }
}

public struct EmbeddingMatch: Sendable, Equatable {
  public let id: String
  public let similarity: Double
}

/// A host-owned exact cosine index. It owns no model, text database or I/O.
/// Persist the complete Codable value; a profile mismatch fails without migration.
public struct EmbeddingIndex: Codable, Sendable, Equatable {
  public static let currentFormatVersion = 1
  public let formatVersion: Int
  public let profile: EmbeddingProfile
  private var vectors: [String: EmbeddingVector]
  public var count: Int { vectors.count }

  public init(profile: EmbeddingProfile, records: [EmbeddingRecord] = []) throws {
    try profile.validate()
    self.formatVersion = Self.currentFormatVersion
    self.profile = profile
    self.vectors = [:]
    try upsert(records)
  }

  /// Validates the entire update before changing the value. Duplicate IDs in
  /// one update are rejected; existing IDs are intentionally replaced.
  public mutating func upsert(_ records: [EmbeddingRecord]) throws {
    var ids = Set<String>()
    for record in records {
      guard ids.insert(record.id).inserted else { throw EmbeddingFailure.invalidInput }
      try record.vector.validate(for: profile)
    }
    for record in records { vectors[record.id] = record.vector }
  }

  @discardableResult
  public mutating func remove(id: String) -> Bool { vectors.removeValue(forKey: id) != nil }

  /// minimumSimilarity is a caller-calibrated filter, never an SDK relevance
  /// guarantee. Stable ID ordering breaks equal-score ties deterministically.
  public func search(
    _ query: EmbeddingVector, limit: Int = 5, minimumSimilarity: Double? = nil
  ) throws -> [EmbeddingMatch] {
    guard limit > 0, minimumSimilarity.map({ $0.isFinite && (-1...1).contains($0) }) ?? true else {
      throw EmbeddingFailure.invalidInput
    }
    try query.validate(for: profile)
    var matches: [EmbeddingMatch] = []
    for (id, vector) in vectors {
      // Immutable corpus vectors were validated on insertion/decoding; validate
      // the query once rather than revalidating it for every corpus entry.
      let dot = zip(query.values, vector.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
      let score = min(1, max(-1, dot))
      if minimumSimilarity.map({ score >= $0 }) ?? true {
        matches.append(.init(id: id, similarity: score))
      }
    }
    matches.sort {
      if $0.similarity == $1.similarity { return $0.id < $1.id }
      return $0.similarity > $1.similarity
    }
    return Array(matches.prefix(limit))
  }

  private enum CodingKeys: String, CodingKey { case formatVersion, profile, records }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(formatVersion, forKey: .formatVersion)
    try c.encode(profile, forKey: .profile)
    let records = try vectors.map { try EmbeddingRecord(id: $0.key, vector: $0.value) }.sorted { $0.id < $1.id }
    try c.encode(records, forKey: .records)
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(Int.self, forKey: .formatVersion) == Self.currentFormatVersion else {
      throw EmbeddingFailure.invalidInput
    }
    try self.init(profile: c.decode(EmbeddingProfile.self, forKey: .profile), records: c.decode([EmbeddingRecord].self, forKey: .records))
  }
}
