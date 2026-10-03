import Foundation
import Testing

@testable import ASKTutor

struct TutorKernelValidationTests {
    @Test
    func startSessionDerivesStableIDFromRequest() async throws {
        let root = makeStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        let kernel = TutorKernel(
            knowledge: ReadyKnowledgeProvider(),
            model: ScriptedModelClient(
                explainHandler: { _ in try await unexpectedCall() },
                solveHandler: { _ in try await unexpectedCall() },
                practiceHandler: { _ in try await unexpectedCall() },
                gradeHandler: { _ in try await unexpectedCall() },
                planHandler: { _ in try await unexpectedCall() }
            ),
            store: store
        )
        let request = TutorStartSessionRequest(
            learnerID: "learner-1",
            title: "Projection review",
            scope: .projection(slug: "wiki/asktutor"),
            requestedAt: "2026-04-10T00:00:00Z"
        )

        let first = try await kernel.startSession(request)
        let second = try await kernel.startSession(request)
        let sessions = try await store.listSessions(learnerID: "learner-1")

        #expect(first.sessionID == second.sessionID)
        #expect(first.sessionID.hasPrefix("session_"))
        #expect(sessions.count == 1)
    }

    @Test
    func insightCaptureDerivesStableCandidateIDFromDomainInput() throws {
        let root = makeStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TutorInsightCandidateStore(rootURL: root)
        let capture = TutorInsightCapture(store: store)
        let session = TutorSession(
            sessionID: "session-1",
            learnerID: "learner-1",
            title: "Projection review",
            scope: .projection(slug: "wiki/asktutor"),
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let reply = TutorReply(
            sessionID: session.sessionID,
            turnID: "turn-1",
            intent: .explain,
            createdAt: "2026-04-10T00:01:00Z",
            title: "Grounded answer",
            summary: "ASK remains the source of truth.",
            sections: [],
            comprehensionChecks: [],
            followUpPrompts: [],
            citations: [],
            knowledgeGap: nil
        )

        let first = try capture.captureNarrative(
            learnerID: "learner-1",
            session: session,
            prompt: "Explain the projection.",
            reply: reply
        )
        let second = try capture.captureNarrative(
            learnerID: "learner-1",
            session: session,
            prompt: "Explain the projection.",
            reply: reply
        )

        #expect(first.candidateID == second.candidateID)
        #expect(first.candidateID.hasPrefix("insight_"))
        #expect(try store.list().count == 1)
    }

    @Test
    func bootstrapRejectsUnsafeLearnerIDBeforeTouchingDependencies() async throws {
        let kernel = TutorKernel(
            knowledge: UnexpectedKnowledgeProvider(),
            model: ScriptedModelClient(
                explainHandler: { _ in try await unexpectedCall() },
                solveHandler: { _ in try await unexpectedCall() },
                practiceHandler: { _ in try await unexpectedCall() },
                gradeHandler: { _ in try await unexpectedCall() },
                planHandler: { _ in try await unexpectedCall() }
            ),
            store: UnexpectedTutorStore()
        )

        do {
            _ = try await kernel.bootstrap(
                TutorBootstrapRequest(
                    learnerID: "bad/id",
                    requestedAt: "2026-04-10T00:00:00Z"
                )
            )
            Issue.record("Expected invalid learnerID to fail")
        } catch let error as ASKTutorError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Unexpected ASKTutorError: \(error)")
                return
            }
            #expect(message.contains("learnerID"))
        }
    }

    @Test
    func explainRejectsUnsafeSessionIDBeforeTouchingDependencies() async throws {
        let kernel = TutorKernel(
            knowledge: UnexpectedKnowledgeProvider(),
            model: ScriptedModelClient(
                explainHandler: { _ in try await unexpectedCall() },
                solveHandler: { _ in try await unexpectedCall() },
                practiceHandler: { _ in try await unexpectedCall() },
                gradeHandler: { _ in try await unexpectedCall() },
                planHandler: { _ in try await unexpectedCall() }
            ),
            store: UnexpectedTutorStore()
        )

        do {
            _ = try await kernel.explain(
                TutorExplainRequest(
                    sessionID: "bad/id",
                    prompt: "Explain",
                    requestedAt: "2026-04-10T00:00:00Z"
                )
            )
            Issue.record("Expected invalid sessionID to fail")
        } catch let error as ASKTutorError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Unexpected ASKTutorError: \(error)")
                return
            }
            #expect(message.contains("sessionID"))
        }
    }
}

private actor ReadyKnowledgeProvider: TutorKnowledgeProvider {
    func ensureKnowledgeBase() async throws {}

    func stateSummary() async throws -> TutorKnowledgeStateSummary {
        throw UnexpectedTestCall.invoked
    }

    func projection(slug: String) async throws -> TutorProjectionSnapshot? {
        throw UnexpectedTestCall.invoked
    }

    func search(_ query: String, limit: Int) async throws -> [TutorEvidenceHit] {
        throw UnexpectedTestCall.invoked
    }

    func ground(question: String, requestedAt: String, fileBackSlug: String?) async throws -> TutorGrounding {
        throw UnexpectedTestCall.invoked
    }

    func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot {
        throw UnexpectedTestCall.invoked
    }
}

private actor UnexpectedKnowledgeProvider: TutorKnowledgeProvider {
    func ensureKnowledgeBase() async throws {
        throw UnexpectedTestCall.invoked
    }

    func stateSummary() async throws -> TutorKnowledgeStateSummary {
        throw UnexpectedTestCall.invoked
    }

    func projection(slug: String) async throws -> TutorProjectionSnapshot? {
        throw UnexpectedTestCall.invoked
    }

    func search(_ query: String, limit: Int) async throws -> [TutorEvidenceHit] {
        throw UnexpectedTestCall.invoked
    }

    func ground(question: String, requestedAt: String, fileBackSlug: String?) async throws -> TutorGrounding {
        throw UnexpectedTestCall.invoked
    }

    func knowledgeHealth() async throws -> TutorKnowledgeHealthSnapshot {
        throw UnexpectedTestCall.invoked
    }
}

private actor UnexpectedTutorStore: TutorStore {
    func ensureRoot() async throws {
        throw UnexpectedTestCall.invoked
    }

    func loadLearner(learnerID: String) async throws -> LearnerProfile? {
        throw UnexpectedTestCall.invoked
    }

    func listLearners() async throws -> [LearnerProfile] {
        throw UnexpectedTestCall.invoked
    }

    func saveLearner(_ learner: LearnerProfile) async throws {
        throw UnexpectedTestCall.invoked
    }

    func loadSession(sessionID: String) async throws -> TutorSession? {
        throw UnexpectedTestCall.invoked
    }

    func saveSession(_ session: TutorSession) async throws {
        throw UnexpectedTestCall.invoked
    }

    func listSessions(learnerID: String) async throws -> [TutorSession] {
        throw UnexpectedTestCall.invoked
    }

    func loadPracticeSet(practiceSetID: String) async throws -> TutorPracticeSet? {
        throw UnexpectedTestCall.invoked
    }

    func savePracticeSet(_ practiceSet: TutorPracticeSet) async throws {
        throw UnexpectedTestCall.invoked
    }

    func loadPracticeEvaluation(sessionID: String, practiceSetID: String) async throws -> TutorPracticeEvaluation? {
        throw UnexpectedTestCall.invoked
    }

    func savePracticeEvaluation(_ evaluation: TutorPracticeEvaluation) async throws {
        throw UnexpectedTestCall.invoked
    }

    func listPracticeEvaluations(learnerID: String, limit: Int) async throws -> [TutorPracticeEvaluation] {
        throw UnexpectedTestCall.invoked
    }

    func loadStudyPlan(learnerID: String, generatedAt: String) async throws -> TutorStudyPlan? {
        throw UnexpectedTestCall.invoked
    }

    func saveStudyPlan(_ plan: TutorStudyPlan) async throws {
        throw UnexpectedTestCall.invoked
    }

    func listStudyPlans(learnerID: String, limit: Int) async throws -> [TutorStudyPlan] {
        throw UnexpectedTestCall.invoked
    }
}
