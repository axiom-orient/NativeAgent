import EmbeddingCore
import Foundation
import Testing

private func profile(
  model: String = "model", revision: String = "revision", quantization: String = "int4",
  runtime: String = "runtime", prompt: String = "prompt", input: String = "input",
  dimensions: Int = 2, digest: String = String(repeating: "a", count: 64)
) throws -> EmbeddingProfile {
  try EmbeddingProfile(modelID: model, modelRevision: revision, artifactSHA256: digest,
    quantization: quantization, runtimeRevision: runtime, promptRevision: prompt,
    inputPolicyRevision: input, nativeDimensions: 3, dimensions: dimensions)
}

@Test func truncationPrecedesNormalizationAndPersistsIdentity() throws {
  let p = try profile()
  let vector = try EmbeddingVector(nativeValues: [3, 4, 100], profile: p)
  #expect(vector.values == [0.6, 0.8])
  #expect(abs(try vector.cosineSimilarity(to: vector) - 1) < 0.0001)
  let restored = try JSONDecoder().decode(EmbeddingVector.self, from: JSONEncoder().encode(vector))
  #expect(restored == vector)
}

@Test func validatesFullNativeOutputAndNonzeroTruncatedPrefix() throws {
  let p = try profile()
  for values: [Float] in [[3, 4], [3, 4, .nan], [3, 4, .infinity], [0, 0, 10]] {
    #expect(throws: EmbeddingFailure.self) { try EmbeddingVector(nativeValues: values, profile: p) }
  }
  let large = try EmbeddingVector(nativeValues: [.greatestFiniteMagnitude, .greatestFiniteMagnitude, 0], profile: p)
  let small = try EmbeddingVector(nativeValues: [.leastNonzeroMagnitude, .leastNonzeroMagnitude, 0], profile: p)
  try large.validate()
  try small.validate()
}

@Test func rejectsEveryMaterialIndexMismatch() throws {
  let p = try profile()
  let vector = try EmbeddingVector(nativeValues: [1, 2, 3], profile: p)
  let changes = [try profile(model: "other"), try profile(revision: "other"),
    try profile(quantization: "float32"), try profile(runtime: "other"),
    try profile(prompt: "other"), try profile(input: "other"),
    try profile(dimensions: 3), try profile(digest: String(repeating: "b", count: 64))]
  for changed in changes {
    #expect(throws: EmbeddingFailure.incompatibleProfile) { try vector.validate(for: changed) }
    let other = try EmbeddingVector(nativeValues: [1, 2, 3], profile: changed)
    #expect(throws: EmbeddingFailure.incompatibleProfile) { try vector.cosineSimilarity(to: other) }
  }
}

@Test func persistedVectorsCannotBypassValidation() throws {
  let vector = try EmbeddingVector(nativeValues: [1, 2, 3], profile: profile())
  var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector)) as? [String: Any])
  for values in [[0, 0], [1], [2, 2]] {
    json["values"] = values
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: EmbeddingFailure.self) { try JSONDecoder().decode(EmbeddingVector.self, from: data) }
  }
}

@Test func persistedProfilesCannotBypassIdentityValidation() throws {
  let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile())) as? [String: Any])
  for (key, value): (String, Any) in [("dimensions", 0), ("artifactSHA256", "wrong"), ("promptRevision", ""), ("normalizationRevision", "unknown")] {
    var modified = json
    modified[key] = value
    let data = try JSONSerialization.data(withJSONObject: modified)
    #expect(throws: EmbeddingFailure.invalidProfile) { try JSONDecoder().decode(EmbeddingProfile.self, from: data) }
  }
}
