import EmbeddingCore
import Foundation
import Testing

private func indexProfile(_ revision: String = "r1") throws -> EmbeddingProfile {
  try .init(modelID: "fixture", modelRevision: revision, artifactSHA256: String(repeating: "a", count: 64),
    quantization: "q", runtimeRevision: "runtime", promptRevision: "search", inputPolicyRevision: "input",
    nativeDimensions: 3, dimensions: 3)
}

@Test func exactRankingStableTiesAndCalibratedFilter() throws {
  let p = try indexProfile()
  func vector(_ v: [Float]) throws -> EmbeddingVector { try .init(nativeValues: v, profile: p) }
  let q = try vector([1, 0, 0])
  let index = try EmbeddingIndex(profile: p, records: [
    .init(id: "b", vector: q), .init(id: "a", vector: q),
    .init(id: "opposite", vector: vector([-1, 0, 0])), .init(id: "orthogonal", vector: vector([0, 1, 0]))
  ])
  #expect(try index.search(q).map(\.id) == ["a", "b", "orthogonal", "opposite"])
  #expect(try index.search(q, limit: 1).map(\.id) == ["a"])
  #expect(try index.search(q, minimumSimilarity: 0.5).map(\.id) == ["a", "b"])
  for value in [Double.nan, .infinity, -1.1, 1.1] {
    #expect(throws: EmbeddingFailure.invalidInput) { try index.search(q, minimumSimilarity: value) }
  }
  #expect(throws: EmbeddingFailure.invalidInput) { try index.search(q, limit: 0) }
}

@Test func bulkIndexMutationIsAtomicOnProfileOrIDFailure() throws {
  let p = try indexProfile()
  let v = try EmbeddingVector(nativeValues: [1, 0, 0], profile: p)
  let other = try EmbeddingVector(nativeValues: [1, 0, 0], profile: indexProfile("r2"))
  var index = try EmbeddingIndex(profile: p, records: [.init(id: "original", vector: v)])
  let before = index
  #expect(throws: EmbeddingFailure.incompatibleProfile) {
    try index.upsert([.init(id: "valid", vector: v), .init(id: "foreign", vector: other)])
  }
  #expect(index == before)
  #expect(throws: EmbeddingFailure.invalidInput) { try index.upsert([.init(id: "dup", vector: v), .init(id: "dup", vector: v)]) }
  #expect(index == before)
  try index.upsert([.init(id: "original", vector: v)])
  #expect(index.count == 1)
  let removed = index.remove(id: "original")
  let missing = index.remove(id: "original")
  #expect(removed)
  #expect(!missing)
  #expect(throws: EmbeddingFailure.incompatibleProfile) { try index.search(other) }
}

@Test func persistedIndexValidatesItsEntireCorpus() throws {
  let p = try indexProfile()
  let v = try EmbeddingVector(nativeValues: [1, 2, 3], profile: p)
  let original = try EmbeddingIndex(profile: p, records: [.init(id: "document", vector: v)])
  let data = try JSONEncoder().encode(original)
  #expect(try JSONDecoder().decode(EmbeddingIndex.self, from: data) == original)
  var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var future = json; future["formatVersion"] = 2
  #expect(throws: EmbeddingFailure.invalidInput) {
    try JSONDecoder().decode(EmbeddingIndex.self, from: JSONSerialization.data(withJSONObject: future))
  }
  let records = try #require(json["records"] as? [[String: Any]])
  json["records"] = records + records
  #expect(throws: EmbeddingFailure.invalidInput) {
    try JSONDecoder().decode(EmbeddingIndex.self, from: JSONSerialization.data(withJSONObject: json))
  }
  json["records"] = records
  var profile = try #require(json["profile"] as? [String: Any]); profile["modelRevision"] = "foreign"
  json["profile"] = profile
  #expect(throws: EmbeddingFailure.incompatibleProfile) {
    try JSONDecoder().decode(EmbeddingIndex.self, from: JSONSerialization.data(withJSONObject: json))
  }
}
