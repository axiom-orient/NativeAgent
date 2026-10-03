import Foundation
import Testing

@testable import ASKTutor

struct TutorKernelConcurrencyTests {
  @Test
  func overlappingMutationOfSameSessionFailsExplicitly() async throws {
    let root = makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let gate = NarrativeGate()
    let store = JSONFileTutorStore(rootURL: root)
    let kernel = TutorKernel(
      knowledge: NarrativeKnowledgeProvider(),
      model: BlockingNarrativeModel(gate: gate),
      store: store
    )
    _ = try await kernel.bootstrap(
      TutorBootstrapRequest(
        learnerID: "learner-1",
        requestedAt: "2026-04-10T00:00:00Z"
      )
    )
    let session = try await kernel.startSession(
      TutorStartSessionRequest(
        learnerID: "learner-1",
        title: "Concurrency",
        scope: .global,
        requestedAt: "2026-04-10T00:01:00Z"
      )
    )

    async let firstReply = kernel.explain(
      TutorExplainRequest(
        sessionID: session.sessionID,
        prompt: "First",
        requestedAt: "2026-04-10T00:02:00Z"
      )
    )
    await gate.waitUntilBlocked()

    do {
      _ = try await kernel.solve(
        TutorSolveRequest(
          sessionID: session.sessionID,
          prompt: "Second",
          requestedAt: "2026-04-10T00:03:00Z"
        )
      )
      Issue.record("Expected overlapping session mutation to fail")
    } catch let error as ASKTutorError {
      guard case .storage(let message) = error else {
        Issue.record("Unexpected ASKTutorError: \(error)")
        await gate.release()
        _ = try await firstReply
        return
      }
      #expect(message.contains("session:"))
    }

    await gate.release()
    _ = try await firstReply
    let persisted = try #require(await store.loadSession(sessionID: session.sessionID))
    #expect(persisted.transcript.count == 2)
  }


  @Test
  func cancelledNarrativeDoesNotPersistLateModelResult() async throws {
    let root = makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = NarrativeGate()
    let store = JSONFileTutorStore(rootURL: root)
    let kernel = TutorKernel(
      knowledge: NarrativeKnowledgeProvider(),
      model: BlockingNarrativeModel(gate: gate),
      store: store
    )
    _ = try await kernel.bootstrap(TutorBootstrapRequest(
      learnerID: "learner-cancel", requestedAt: "2026-04-10T00:00:00Z"
    ))
    let session = try await kernel.startSession(TutorStartSessionRequest(
      learnerID: "learner-cancel", title: "Cancellation", scope: .global,
      requestedAt: "2026-04-10T00:01:00Z"
    ))
    let before = try #require(await store.loadSession(sessionID: session.sessionID))
    let task = Task {
      try await kernel.explain(TutorExplainRequest(
        sessionID: session.sessionID, prompt: "Cancelled question",
        requestedAt: "2026-04-10T00:02:00Z"
      ))
    }
    await gate.waitUntilBlocked()
    task.cancel()
    await gate.release()
    do {
      _ = try await task.value
      Issue.record("A cancelled narrative accepted a late model result")
    } catch is CancellationError {
      // Expected. Cancellation must be checked by the domain before persistence.
    }
    let after = try #require(await store.loadSession(sessionID: session.sessionID))
    #expect(after.transcript == before.transcript)
    #expect(after.updatedAt == before.updatedAt)
  }

  @Test
  func mutationReducerIsDeterministic() {
    let scopes: Set<TutorMutationScope> = [.learner("learner-1"), .session("session-1")]
    let initial = TutorMutationState()
    let first = TutorMutationReducer.reduce(state: initial, event: .acquire(scopes))
    let second = TutorMutationReducer.reduce(state: initial, event: .acquire(scopes))
    #expect(first == second)

    guard case .accepted(let acquired) = first else {
      Issue.record("Expected initial acquisition to succeed")
      return
    }
    guard
      case .conflict(let conflicts) = TutorMutationReducer.reduce(
        state: acquired,
        event: .acquire([.session("session-1")])
      )
    else {
      Issue.record("Expected overlapping scope to conflict")
      return
    }
    #expect(conflicts == [.session("session-1")])

    let released = TutorMutationReducer.releasing(
      state: acquired,
      scopes: [.session("session-1")]
    )
    #expect(released.activeScopes == [.learner("learner-1")])
  }
}

private actor NarrativeGate {
  private var blocked = false
  private var blockWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func block() async {
    blocked = true
    let waiters = blockWaiters
    blockWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    if blocked { return }
    await withCheckedContinuation { continuation in
      blockWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor NarrativeKnowledgeProvider: TutorKnowledgeProvider {
  func ensureKnowledgeBase() async throws {}

  func stateSummary() async throws -> TutorKnowledgeStateSummary {
    throw UnexpectedTestCall.invoked
  }

  func projection(slug: String) async throws -> TutorProjectionSnapshot? {
    nil
  }

  func search(_ query: String, limit: Int) async throws -> [TutorEvidenceHit] {
    throw UnexpectedTestCall.invoked
  }

  func ground(
    question: String,
    requestedAt: String,
    fileBackSlug: String?
  ) async throws -> TutorGrounding {
    TutorGrounding(
      question: question,
      answer: "Grounded",
      citations: [],
      results: [],
      knowledgeGap: nil
    )
  }

  func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot {
    throw UnexpectedTestCall.invoked
  }
}

private actor BlockingNarrativeModel: TutorModelClient {
  let gate: NarrativeGate

  init(gate: NarrativeGate) {
    self.gate = gate
  }

  func explain(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
    await gate.block()
    return TutorNarrativeDraft(
      title: "Answer",
      summary: "Summary",
      sections: [],
      comprehensionChecks: [],
      followUpPrompts: []
    )
  }

  func solve(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
    throw UnexpectedTestCall.invoked
  }

  func makePracticeSet(_ request: TutorPracticeModelRequest) async throws -> TutorPracticeDraft {
    throw UnexpectedTestCall.invoked
  }

  func grade(_ request: TutorGradeModelRequest) async throws -> TutorGradeDraft {
    throw UnexpectedTestCall.invoked
  }

  func plan(_ request: TutorPlanModelRequest) async throws -> TutorPlanDraft {
    throw UnexpectedTestCall.invoked
  }
}
