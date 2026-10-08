import ASK
import Foundation

/// Public serialization boundary. Domain work is delegated to focused, stateless use cases.
public actor TutorKernel {
  private let lifecycle: TutorLifecycleUseCase
  private let narrative: TutorNarrativeUseCase
  private let practice: TutorPracticeUseCase
  private let study: TutorStudyUseCase
  private let reads: TutorReadUseCase
  private var mutationState = TutorMutationState()
  private let configuration: TutorConfiguration

  /// Creates the production tutor over ASK's canonical knowledge workspace.
  /// ASK owns source/evidence/knowledge truth; ASKTutor owns only learner/session/practice state.
  public init(
    ask: ASKConfiguration,
    model: any TutorModelClient,
    store: any TutorStore,
    configuration: TutorConfiguration = TutorConfiguration()
  ) {
    self.init(
      knowledge: ASKTutorKnowledgeProvider(configuration: ask),
      model: model,
      store: store,
      configuration: configuration
    )
  }

  /// Injection boundary kept internal so production callers cannot replace ASK as
  /// the knowledge authority. Tests may inject deterministic doubles via @testable.
  init(
    knowledge: any TutorKnowledgeProvider,
    model: any TutorModelClient,
    store: any TutorStore,
    configuration: TutorConfiguration = TutorConfiguration()
  ) {
    let repository = TutorRepository(store: store)
    self.configuration = configuration
    self.lifecycle = TutorLifecycleUseCase(
      knowledge: knowledge,
      repository: repository,
      configuration: configuration
    )
    self.narrative = TutorNarrativeUseCase(
      knowledge: knowledge,
      model: model,
      repository: repository,
      configuration: configuration
    )
    self.practice = TutorPracticeUseCase(
      knowledge: knowledge,
      model: model,
      repository: repository,
      configuration: configuration
    )
    self.study = TutorStudyUseCase(
      knowledge: knowledge,
      model: model,
      repository: repository,
      configuration: configuration
    )
    self.reads = TutorReadUseCase(
      knowledge: knowledge,
      repository: repository
    )
  }

  public func bootstrap(_ request: TutorBootstrapRequest) async throws -> LearnerProfile {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    let scopes: Set<TutorMutationScope> = [.learner(request.learnerID)]
    try acquire(scopes)
    defer { release(scopes) }
    return try await lifecycle.bootstrap(request)
  }

  public func startSession(_ request: TutorStartSessionRequest) async throws -> TutorSession {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    let scopes: Set<TutorMutationScope> = [.learner(request.learnerID)]
    try acquire(scopes)
    defer { release(scopes) }
    return try await lifecycle.startSession(request)
  }

  public func explain(_ request: TutorExplainRequest) async throws -> TutorReply {
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    let scopes: Set<TutorMutationScope> = [.session(request.sessionID)]
    try acquire(scopes)
    defer { release(scopes) }
    return try await narrative.perform(
      sessionID: request.sessionID,
      prompt: request.prompt,
      requestedAt: request.requestedAt,
      intent: .explain
    )
  }

  public func solve(_ request: TutorSolveRequest) async throws -> TutorReply {
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    let scopes: Set<TutorMutationScope> = [.session(request.sessionID)]
    try acquire(scopes)
    defer { release(scopes) }
    return try await narrative.perform(
      sessionID: request.sessionID,
      prompt: request.prompt,
      requestedAt: request.requestedAt,
      intent: .solve
    )
  }

  public func makePracticeSet(_ request: TutorPracticeRequest) async throws -> TutorPracticeSet {
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    let scopes: Set<TutorMutationScope> = [.session(request.sessionID)]
    try acquire(scopes)
    defer { release(scopes) }
    return try await practice.makePracticeSet(request)
  }

  public func gradePractice(
    _ request: TutorGradePracticeRequest
  ) async throws -> TutorPracticeEvaluation {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    try TutorRuntimeValidation.ensurePathSafeID(request.sessionID, field: "sessionID")
    try TutorRuntimeValidation.ensurePathSafeID(request.practiceSetID, field: "practiceSetID")
    let scopes: Set<TutorMutationScope> = [
      .learner(request.learnerID),
      .session(request.sessionID),
      .practiceSet(request.practiceSetID),
    ]
    try acquire(scopes)
    defer { release(scopes) }
    return try await practice.gradePractice(request)
  }

  public func studyPlan(_ request: TutorPlanRequest) async throws -> TutorStudyPlan {
    try TutorRuntimeValidation.ensurePathSafeID(request.learnerID, field: "learnerID")
    let scopes: Set<TutorMutationScope> = [.learner(request.learnerID)]
    try acquire(scopes)
    defer { release(scopes) }
    return try await study.studyPlan(request)
  }

  public func practiceHistory(
    _ request: TutorPracticeHistoryRequest
  ) async throws -> [TutorPracticeEvaluation] {
    try await reads.practiceHistory(request)
  }

  public func studyPlanHistory(
    _ request: TutorStudyPlanHistoryRequest
  ) async throws -> [TutorStudyPlan] {
    try await reads.studyPlanHistory(request)
  }

  public func learnerProfile(_ request: TutorLearnerLookupRequest) async throws -> LearnerProfile {
    try await reads.learnerProfile(request)
  }

  public func listLearners() async throws -> [LearnerProfile] {
    try await reads.listLearners()
  }

  public func sessions(_ request: TutorSessionListRequest) async throws -> [TutorSession] {
    try await reads.sessions(request)
  }

  public func session(_ request: TutorSessionLookupRequest) async throws -> TutorSession {
    try await reads.session(request)
  }

  public func practiceSet(_ request: TutorPracticeSetLookupRequest) async throws -> TutorPracticeSet
  {
    try await reads.practiceSet(request)
  }

  public func practiceEvaluation(
    _ request: TutorPracticeEvaluationLookupRequest
  ) async throws -> TutorPracticeEvaluation {
    try await reads.practiceEvaluation(request)
  }

  public func knowledgeState() async throws -> TutorKnowledgeStateSummary {
    try await reads.knowledgeState()
  }

  public func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot {
    try await reads.knowledgeHealth()
  }

  private func acquire(_ scopes: Set<TutorMutationScope>) throws {
    try configuration.validate()
    switch TutorMutationReducer.reduce(
      state: mutationState,
      event: .acquire(scopes)
    ) {
    case .accepted(let next):
      mutationState = next
    case .conflict(let conflicts):
      let names = conflicts.sorted().map(\.description).joined(separator: ", ")
      throw ASKTutorError.storage(
        "concurrent tutor mutation conflicts with active scope: \(names)"
      )
    }
  }

  private func release(_ scopes: Set<TutorMutationScope>) {
    mutationState = TutorMutationReducer.releasing(
      state: mutationState,
      scopes: scopes
    )
  }
}
