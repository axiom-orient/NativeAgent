import Foundation

struct TutorNarrativeUseCase: Sendable {
  let knowledge: any TutorKnowledgeProvider
  let model: any TutorModelClient
  let repository: TutorRepository
  let configuration: TutorConfiguration

  func perform(
    sessionID: String,
    prompt: String,
    requestedAt: String,
    intent: TutorIntent
  ) async throws -> TutorReply {
    try TutorRuntimeValidation.ensurePathSafeID(sessionID, field: "sessionID")
    try TutorRuntimeValidation.ensureRFC3339(requestedAt, field: "requestedAt")
    guard intent == .explain || intent == .solve else {
      throw ASKTutorError.invalidInput(
        "narrative use case supports explain and solve only"
      )
    }

    var session = try await repository.requireSession(sessionID)
    let learner = try await repository.requireLearner(session.learnerID)
    let grounding = try await knowledge.ground(
      question: prompt,
      requestedAt: requestedAt,
      fileBackSlug: session.scope.projectionSlug
    )
    let projection = try await projectionContext(for: session.scope)
    let input = TutorExplainModelRequest(
      learner: learner,
      session: TutorSessionProjection.context(
        from: session,
        recentTranscriptLimit: configuration.recentTranscriptLimit
      ),
      grounding: grounding,
      projection: projection,
      responseStyle: learner.preferences.responseStyle
    )
    let draft: TutorNarrativeDraft
    if intent == .solve {
      draft = try await model.solve(input)
    } else {
      draft = try await model.explain(input)
    }
    try Task.checkCancellation()

    var transcriptOrdinal = session.transcript.count
    let turn = TutorNarrativeComposer.compose(
      intent: intent,
      sessionID: session.sessionID,
      prompt: prompt,
      requestedAt: requestedAt,
      grounding: grounding,
      draft: draft,
      makeID: { role in
        transcriptOrdinal += 1
        return TutorIdentifiers.transcriptEntryID(
          sessionID: session.sessionID,
          role: role,
          requestedAt: requestedAt,
          purpose: "\(intent.rawValue):\(prompt)",
          ordinal: transcriptOrdinal
        )
      }
    )
    session.transcript.append(turn.userEntry)
    session.transcript.append(turn.tutorEntry)
    session.updatedAt = requestedAt
    try await repository.store.saveSession(session)
    return turn.reply
  }

  private func projectionContext(for scope: TutorScope) async throws -> TutorProjectionSnapshot? {
    guard let slug = scope.projectionSlug else { return nil }
    return try await knowledge.projection(slug: slug)
  }
}
