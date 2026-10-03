import Foundation

struct TutorLifecycleUseCase: Sendable {
  let knowledge: any TutorKnowledgeProvider
  let repository: TutorRepository
  let configuration: TutorConfiguration

  func bootstrap(_ request: TutorBootstrapRequest) async throws -> LearnerProfile {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    try TutorRuntimeValidation.ensureRFC3339(request.requestedAt, field: "requestedAt")
    try await knowledge.ensureKnowledgeBase()
    try await repository.store.ensureRoot()
    if let existing = try await repository.store.loadLearner(learnerID: request.learnerID) {
      return existing
    }

    let learner = LearnerProfile(
      learnerID: request.learnerID,
      displayName: request.displayName,
      goals: request.goals,
      preferences: TutorPreferences(
        practiceQuestionCount: configuration.defaultPracticeQuestionCount
      ),
      updatedAt: request.requestedAt
    )
    try await repository.store.saveLearner(learner)
    return learner
  }

  func startSession(_ request: TutorStartSessionRequest) async throws -> TutorSession {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    try TutorRuntimeValidation.ensureRFC3339(request.requestedAt, field: "requestedAt")
    _ = try await ensureLearnerExists(
      request.learnerID,
      requestedAt: request.requestedAt
    )

    let session = TutorSession(
      sessionID: TutorIdentifiers.sessionID(
        learnerID: request.learnerID,
        title: request.title,
        scope: request.scope,
        requestedAt: request.requestedAt
      ),
      learnerID: request.learnerID,
      title: request.title,
      scope: request.scope,
      createdAt: request.requestedAt,
      updatedAt: request.requestedAt
    )
    try await repository.store.saveSession(session)
    return session
  }

  private func ensureLearnerExists(
    _ learnerID: String,
    requestedAt: String
  ) async throws -> LearnerProfile {
    if let learner = try await repository.store.loadLearner(learnerID: learnerID) {
      return learner
    }
    return try await bootstrap(
      TutorBootstrapRequest(
        learnerID: learnerID,
        requestedAt: requestedAt
      )
    )
  }
}
