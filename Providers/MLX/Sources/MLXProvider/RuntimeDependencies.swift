import ModelArtifactStore
import MLXModelRegistry
import Foundation
import LanguageModelCore

protocol MLXLoadedSession: Sendable {
  func generate(
    request: ModelRequest,
    emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws
  func shutdown() async
}

struct MLXSessionLoader: Sendable {
  var load: @Sendable (URL, MLXModelSpecification) async throws -> any MLXLoadedSession
  var clearCache: @Sendable () async -> Void
}
