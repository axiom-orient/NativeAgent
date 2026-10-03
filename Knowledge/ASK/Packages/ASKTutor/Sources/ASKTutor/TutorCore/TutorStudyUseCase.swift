import Foundation

struct TutorStudyUseCase: Sendable {
  let knowledge: any TutorKnowledgeProvider
  let model: any TutorModelClient
  let repository: TutorRepository
  let configuration: TutorConfiguration

  func studyPlan(_ request: TutorPlanRequest) async throws -> TutorStudyPlan {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    try TutorRuntimeValidation.ensureRFC3339(request.requestedAt, field: "requestedAt")
    let learner = try await repository.requireLearner(request.learnerID)
    let sessions = try await repository.store.listSessions(learnerID: request.learnerID)
    let dueConcepts = TutorStudyPlanning.dueConcepts(
      from: learner.conceptStates,
      requestedAt: request.requestedAt
    )
    let knowledgeHealth = try await knowledge.knowledgeHealth()
    let draft = try await model.plan(
      TutorPlanModelRequest(
        learner: learner,
        recentSessions: Array(sessions.prefix(3)).map {
          TutorSessionProjection.context(
            from: $0,
            recentTranscriptLimit: configuration.recentTranscriptLimit
          )
        },
        dueConcepts: dueConcepts,
        knowledgeHealth: knowledgeHealth
      )
    )
    try Task.checkCancellation()
    let plan = TutorStudyPlan(
      learnerID: learner.learnerID,
      generatedAt: request.requestedAt,
      headline: draft.headline,
      focusTopics: draft.focusTopics,
      actions: draft.actions,
      rationale: draft.rationale,
      dueConceptIDs: dueConcepts.map(\.conceptID),
      knowledgeMaintenance: knowledgeHealth.maintenanceItems
    )
    try await repository.store.saveStudyPlan(plan)
    return plan
  }
}
