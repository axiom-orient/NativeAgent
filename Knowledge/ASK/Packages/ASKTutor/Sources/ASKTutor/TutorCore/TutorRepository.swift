import Foundation

struct TutorRepository: Sendable {
  let store: any TutorStore

  func requireLearner(_ learnerID: String) async throws -> LearnerProfile {
    guard let learner = try await store.loadLearner(learnerID: learnerID) else {
      throw ASKTutorError.notFound("unknown learner `\(learnerID)`")
    }
    return learner
  }

  func requireSession(_ sessionID: String) async throws -> TutorSession {
    guard let session = try await store.loadSession(sessionID: sessionID) else {
      throw ASKTutorError.notFound("unknown session `\(sessionID)`")
    }
    return session
  }

  func requirePracticeSet(_ practiceSetID: String) async throws -> TutorPracticeSet {
    guard let practiceSet = try await store.loadPracticeSet(practiceSetID: practiceSetID) else {
      throw ASKTutorError.notFound("unknown practice set `\(practiceSetID)`")
    }
    return practiceSet
  }

  func requirePracticeEvaluation(
    sessionID: String,
    practiceSetID: String
  ) async throws -> TutorPracticeEvaluation {
    guard
      let evaluation = try await store.loadPracticeEvaluation(
        sessionID: sessionID,
        practiceSetID: practiceSetID
      )
    else {
      throw ASKTutorError.notFound(
        "unknown practice evaluation `\(sessionID):\(practiceSetID)`"
      )
    }
    return evaluation
  }

  func saveBatch(_ batch: TutorStoreBatch) async throws {
    try Task.checkCancellation()
    guard let batchStore = store as? any TutorBatchStore else {
      throw ASKTutorError.storage(
        "atomic batch persistence is required for multi-record tutor transitions"
      )
    }
    try await batchStore.saveBatch(batch)
  }
}
