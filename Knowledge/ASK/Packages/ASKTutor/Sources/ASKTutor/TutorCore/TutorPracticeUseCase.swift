import Foundation

struct TutorPracticeUseCase: Sendable {
  let knowledge: any TutorKnowledgeProvider
  let model: any TutorModelClient
  let repository: TutorRepository
  let configuration: TutorConfiguration

  func makePracticeSet(_ request: TutorPracticeRequest) async throws -> TutorPracticeSet {
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    try TutorRuntimeValidation.ensureRFC3339(request.requestedAt, field: "requestedAt")
    var session = try await repository.requireSession(request.sessionID)
    let learner = try await repository.requireLearner(session.learnerID)
    let questionCount = try TutorRequestValidation.practiceQuestionCount(
      request.questionCount,
      defaultValue: learner.preferences.practiceQuestionCount
    )
    let evidence = try await knowledge.search(
      request.topic,
      limit: configuration.searchLimit
    )
    let projection = try await projectionContext(for: session.scope)
    let draft = try await model.makePracticeSet(
      TutorPracticeModelRequest(
        learner: learner,
        session: TutorSessionProjection.context(
          from: session,
          recentTranscriptLimit: configuration.recentTranscriptLimit
        ),
        topic: request.topic,
        evidence: evidence,
        projection: projection,
        questionCount: questionCount
      )
    )

    try Task.checkCancellation()
    var practiceIDOrdinal = 0
    let materialization = TutorPracticeSetMaterializer.materialize(
      sessionID: session.sessionID,
      requestedAt: request.requestedAt,
      draft: draft,
      evidence: evidence,
      maxCitations: configuration.maxCitations,
      makeID: { purpose in
        practiceIDOrdinal += 1
        return TutorIdentifiers.transcriptEntryID(
          sessionID: session.sessionID,
          role: .system,
          requestedAt: request.requestedAt,
          purpose: "practice:\(purpose):\(request.topic)",
          ordinal: practiceIDOrdinal
        )
      },
      makePracticeSetID: {
        TutorIdentifiers.practiceSetID(
          sessionID: session.sessionID,
          requestedAt: request.requestedAt,
          topic: request.topic
        )
      }
    )
    session.lastPracticeSetID = materialization.practiceSet.practiceSetID
    session.updatedAt = request.requestedAt
    session.transcript.append(materialization.sessionTranscriptEntry)
    try await repository.saveBatch(
      TutorStoreBatch(
        sessions: [session],
        practiceSets: [materialization.practiceSet]
      )
    )
    return materialization.practiceSet
  }

  func gradePractice(
    _ request: TutorGradePracticeRequest
  ) async throws -> TutorPracticeEvaluation {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    try TutorRuntimeValidation.ensurePathSafeID(request.practiceSetID, field: "practiceSetID")
    try TutorRuntimeValidation.ensureRFC3339(request.requestedAt, field: "requestedAt")

    async let learnerLoad = repository.requireLearner(request.learnerID)
    async let sessionLoad = repository.requireSession(request.sessionID)
    async let practiceSetLoad = repository.requirePracticeSet(request.practiceSetID)
    let learner = try await learnerLoad
    let session = try await sessionLoad
    let practiceSet = try await practiceSetLoad

    guard session.learnerID == request.learnerID else {
      throw ASKTutorError.invalidInput("session does not belong to learner")
    }
    try TutorGradeValidation.ensurePracticeBelongsToSession(
      practiceSet,
      sessionID: session.sessionID
    )
    let draft = try await model.grade(
      TutorGradeModelRequest(
        learner: learner,
        session: TutorSessionProjection.context(
          from: session,
          recentTranscriptLimit: configuration.recentTranscriptLimit
        ),
        practiceSet: practiceSet,
        responses: request.responses
      )
    )
    try Task.checkCancellation()
    let outcome = try TutorPracticeEvaluationReducer.reduce(
      learner: learner,
      session: session,
      practiceSet: practiceSet,
      draft: draft,
      configuration: configuration,
      requestedAt: request.requestedAt
    )
    try await repository.saveBatch(
      TutorStoreBatch(
        learners: [outcome.learner],
        practiceEvaluations: [outcome.evaluation]
      )
    )
    return outcome.evaluation
  }

  private func projectionContext(for scope: TutorScope) async throws -> TutorProjectionSnapshot? {
    guard let slug = scope.projectionSlug else { return nil }
    return try await knowledge.projection(slug: slug)
  }
}
