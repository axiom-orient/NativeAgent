import EmbeddingCore
import Foundation
import LiteRTEmbeddingProvider
import ModelArtifactStore

enum EmbeddingWorkflowFailure: Error { case failed(String) }
public enum EmbeddingWorkflowQualification {
  public static func run(root: URL) async throws -> Data {
    let cache = root.appendingPathComponent("native-cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let store = try ModelArtifactStore(rootURL: root.appendingPathComponent("artifacts"))
    try await EmbeddingGemma2.prepare(in: store)
    let documents = KoreanEmbeddingFixtures.documents
    let queries = KoreanEmbeddingFixtures.queries.compactMap { text, expected in expected == nil ? nil : text }
    var results: [[String: Int]] = []
    for dimension in EmbeddingGemma2Dimensions.allCases {
      let model = try await LiteRTEmbeddingModel.load(store: store, cacheDirectory: cache, dimensions: dimension)
      do {
        // An active engine's lease must prevent removal of its model bytes.
        do { try await store.remove(EmbeddingGemma2.artifactManifest); throw EmbeddingWorkflowFailure.failed("Resident artifact removed") }
        catch ArtifactStoreError.busy { }
        let vectors = try await model.embed(documents.map { .document(text: $0) })
        var index = try EmbeddingIndex(profile: model.profile)
        try index.upsert(try vectors.enumerated().map { try EmbeddingRecord(id: String($0.offset), vector: $0.element) })
        let persisted = try JSONEncoder().encode(index)
        let restored = try JSONDecoder().decode(EmbeddingIndex.self, from: persisted)
        guard restored == index else { throw EmbeddingWorkflowFailure.failed("Index restore mismatch") }
        let queryVectors = try await model.embed(queries.map(EmbeddingInput.query))
        var hits = 0
        for (i, query) in queryVectors.enumerated() {
          if try restored.search(query, limit: 1).first?.id == String(i) { hits += 1 }
        }
        guard hits == 8 else { throw EmbeddingWorkflowFailure.failed("Korean retrieval misses at \(dimension.rawValue): \(hits)/8") }
        if dimension != .d256 {
          let incompatible = try EmbeddingIndex(profile: EmbeddingGemma2.profile)
          do { _ = try incompatible.search(queryVectors[0]); throw EmbeddingWorkflowFailure.failed("Mixed dimensions accepted") }
          catch EmbeddingFailure.incompatibleProfile { }
        }
        try await model.shutdown()
        results.append(["dimensions": dimension.rawValue, "koreanMatches": hits, "corpusCount": restored.count])
      } catch { try await model.shutdown(); throw error }
    }
    // Cached preparation must be usable again; after all engines close the host
    // can remove the exact artifact, with no dangling native file readers.
    try await EmbeddingGemma2.prepare(in: store)
    try await store.remove(EmbeddingGemma2.artifactManifest)
    let data = try JSONSerialization.data(withJSONObject: ["status": "PASS", "dimensions": results,
      "leasedRemovalRejected": true, "releasedRemovalSucceeded": true], options: [.prettyPrinted, .sortedKeys])
    return data
  }
}
