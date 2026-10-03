import Foundation

struct TutorReadUseCase: Sendable {
  let knowledge: any TutorKnowledgeProvider
  let repository: TutorRepository

  func practiceHistory(
    _ request: TutorPracticeHistoryRequest
  ) async throws -> [TutorPracticeEvaluation] {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    _ = try await repository.requireLearner(request.learnerID)
    return try await repository.store.listPracticeEvaluations(
      learnerID: request.learnerID,
      limit: max(1, request.limit)
    )
  }

  func studyPlanHistory(
    _ request: TutorStudyPlanHistoryRequest
  ) async throws -> [TutorStudyPlan] {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    _ = try await repository.requireLearner(request.learnerID)
    return try await repository.store.listStudyPlans(
      learnerID: request.learnerID,
      limit: max(1, request.limit)
    )
  }

  func learnerProfile(_ request: TutorLearnerLookupRequest) async throws -> LearnerProfile {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    return try await repository.requireLearner(request.learnerID)
  }

  func listLearners() async throws -> [LearnerProfile] {
    try await repository.store.listLearners()
  }

  func sessions(_ request: TutorSessionListRequest) async throws -> [TutorSession] {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    _ = try await repository.requireLearner(request.learnerID)
    return try await repository.store.listSessions(learnerID: request.learnerID)
  }

  func session(_ request: TutorSessionLookupRequest) async throws -> TutorSession {
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    return try await repository.requireSession(request.sessionID)
  }

  func practiceSet(_ request: TutorPracticeSetLookupRequest) async throws -> TutorPracticeSet {
    try TutorRuntimeValidation.ensurePathSafeID(request.practiceSetID, field: "practiceSetID")
    return try await repository.requirePracticeSet(request.practiceSetID)
  }

  func practiceEvaluation(
    _ request: TutorPracticeEvaluationLookupRequest
  ) async throws -> TutorPracticeEvaluation {
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    try TutorRuntimeValidation.ensurePathSafeID(request.practiceSetID, field: "practiceSetID")
    return try await repository.requirePracticeEvaluation(
      sessionID: request.sessionID,
      practiceSetID: request.practiceSetID
    )
  }

  func knowledgeState() async throws -> TutorKnowledgeStateSummary {
    try await knowledge.stateSummary()
  }

  func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot {
    try await knowledge.knowledgeHealth()
  }
}
