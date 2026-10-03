import Foundation
import XCTest
@testable import ASKTutor
import KnowledgeCore
import KnowledgeRuntime
import EvidenceIndex
import PageIndex
import DocumentCore
import DocumentRuntime

extension ASKProductIntegrationTests {
    func testTutorLivePresentationResolverBuildsBoundEvidenceDrawerItems() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in
                    TutorNarrativeDraft(
                        title: "ASK and Tutor",
                        summary: "Tutor teaches from grounded ASK pages.",
                        sections: [
                            TutorNarrativeSection(
                                heading: "Grounding",
                                body: "Resolve the live presentation from the scoped projection and its indexed evidence."
                            )
                        ],
                        comprehensionChecks: ["What is grounded?"],
                        followUpPrompts: ["Inspect the evidence drawer."]
                    )
                }
            )
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try await seedPageIndex(
            workspace: runtime.workspace,
            askSourceID: "ask-src-1",
            projectionSlug: "wiki/asktutor"
        )

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T09:40:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK live presentation",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T09:41:00Z"
            )
        )
        let reply = try await runtime.tutor.explain(
            TutorExplainRequest(
                sessionID: session.sessionID,
                prompt: "Show the grounded page context.",
                requestedAt: "2026-04-13T09:42:00Z"
            )
        )

        let presentation = try await ASKTutorLivePresentationResolver().resolve(
            reply: reply,
            session: session,
            runtime: runtime
        )

        XCTAssertEqual(presentation.sessionID, session.sessionID)
        XCTAssertEqual(presentation.turnID, reply.turnID)
        XCTAssertEqual(presentation.projectionSlug, "wiki/asktutor")
        XCTAssertEqual(presentation.readingContext.runtimePackage.document.title, "ASK Tutor")
        XCTAssertEqual(presentation.evidence.count, 1)

        let item = try XCTUnwrap(presentation.evidence.first)
        XCTAssertEqual(item.askSourceID, "ask-src-1")
        XCTAssertEqual(item.title, "ASK source")
        XCTAssertEqual(item.rawRelpath, "raw/evidence/2026-04-13/ask-src-1.md")
        XCTAssertEqual(item.status, .bound)
        XCTAssertFalse(item.catalogEntries.isEmpty)
        XCTAssertFalse(item.resolvedAnchors.isEmpty)
    }

    func testTutorLivePresentationResolverMarksMissingSourceReceipts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in
                    TutorNarrativeDraft(
                        title: "ASK and Tutor",
                        summary: "The page should still open even if source receipts are missing.",
                        sections: [
                            TutorNarrativeSection(
                                heading: "Missing evidence",
                                body: "The resolver should report missing source receipts instead of fabricating bindings."
                            )
                        ],
                        comprehensionChecks: ["What is missing?"],
                        followUpPrompts: ["Review the evidence drawer state."]
                    )
                }
            )
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-missing"]
        )

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T09:50:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK missing evidence",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T09:51:00Z"
            )
        )
        let reply = try await runtime.tutor.explain(
            TutorExplainRequest(
                sessionID: session.sessionID,
                prompt: "Open the page even if evidence receipts are missing.",
                requestedAt: "2026-04-13T09:52:00Z"
            )
        )

        let presentation = try await ASKTutorLivePresentationResolver().resolve(
            reply: reply,
            session: session,
            runtime: runtime
        )

        XCTAssertEqual(presentation.readingContext.runtimePackage.document.title, "ASK Tutor")
        XCTAssertEqual(presentation.evidence.count, 1)

        let item = try XCTUnwrap(presentation.evidence.first)
        XCTAssertEqual(item.askSourceID, "ask-src-missing")
        XCTAssertEqual(item.status, .missingSourceReceipt)
        XCTAssertNil(item.title)
        XCTAssertNil(item.rawRelpath)
        XCTAssertTrue(item.catalogEntries.isEmpty)
        XCTAssertTrue(item.resolvedAnchors.isEmpty)
        XCTAssertEqual(presentation.readingContext.unboundSourceIDs, ["ask-src-missing"])
    }

    func testTutorHistoryPresentationResolverResolvesLinkedSessionTranscript() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in
                    TutorNarrativeDraft(
                        title: "ASK session history",
                        summary: "Resolve linked history from the scoped projection.",
                        sections: [
                            TutorNarrativeSection(
                                heading: "History",
                                body: "Session history should link transcript citations back to the projection reading context."
                            )
                        ],
                        comprehensionChecks: ["What is linked in history?"],
                        followUpPrompts: ["Inspect the transcript history."]
                    )
                }
            )
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try await seedPageIndex(
            workspace: runtime.workspace,
            askSourceID: "ask-src-1",
            projectionSlug: "wiki/asktutor"
        )

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T10:10:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK history",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T10:11:00Z"
            )
        )
        let reply = try await runtime.tutor.explain(
            TutorExplainRequest(
                sessionID: session.sessionID,
                prompt: "Explain the ASK/Tutor boundary.",
                requestedAt: "2026-04-13T10:12:00Z"
            )
        )

        let history = try await ASKTutorHistoryPresentationResolver().resolveSession(
            sessionID: session.sessionID,
            runtime: runtime
        )

        XCTAssertEqual(history.session.sessionID, session.sessionID)
        XCTAssertEqual(history.scopePresentation.sessionID, session.sessionID)
        XCTAssertEqual(history.scopePresentation.projectionLink.projectionSlug, "wiki/asktutor")
        XCTAssertEqual(history.scopePresentation.projectionLink.status, .linked)
        XCTAssertEqual(history.scopePresentation.projectionLink.readingContext?.runtimePackage.document.title, "ASK Tutor")
        XCTAssertEqual(history.transcript.count, 2)
        XCTAssertEqual(history.transcript.last?.entry.role, .tutor)
        XCTAssertEqual(history.transcript.last?.citationLinks.count, reply.citations.count)
        XCTAssertEqual(history.transcript.last?.citationLinks.first?.status, .linked)
        XCTAssertEqual(history.transcript.last?.citationLinks.first?.projectionSlug, "wiki/asktutor")
    }

    func testTutorHistoryPresentationResolverThrowsUnknownSessionForMissingSession() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()

        do {
            _ = try await ASKTutorHistoryPresentationResolver().resolveSession(
                sessionID: "missing-session",
                runtime: runtime
            )
            XCTFail("Expected unknownSession error")
        } catch let error as ASKTutorHistoryPresentationResolverError {
            XCTAssertEqual(error, .unknownSession(sessionID: "missing-session"))
        }
    }

    func testTutorHistoryPresentationResolverThrowsUnknownPracticeSetForMissingPracticeSet() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()

        do {
            _ = try await ASKTutorHistoryPresentationResolver().resolvePracticeSet(
                practiceSetID: "missing-practice-set",
                runtime: runtime
            )
            XCTFail("Expected unknownPracticeSet error")
        } catch let error as ASKTutorHistoryPresentationResolverError {
            XCTAssertEqual(error, .unknownPracticeSet(practiceSetID: "missing-practice-set"))
        }
    }

    func testTutorHistoryPresentationResolverMarksMissingSessionProjection() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(workspace: ASKProductWorkspacePaths(rootURL: rootURL))
        try runtime.ensureKnowledgeBase()

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T10:20:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "Missing projection",
                scope: .projection(slug: "wiki/missing"),
                requestedAt: "2026-04-13T10:21:00Z"
            )
        )

        let history = try await ASKTutorHistoryPresentationResolver().resolveSession(
            sessionID: session.sessionID,
            runtime: runtime
        )

        XCTAssertEqual(history.session.sessionID, session.sessionID)
        XCTAssertEqual(history.scopePresentation.projectionLink.projectionSlug, "wiki/missing")
        XCTAssertEqual(history.scopePresentation.projectionLink.status, .projectionNotFound)
        XCTAssertNil(history.scopePresentation.projectionLink.readingContext)
        XCTAssertTrue(history.transcript.isEmpty)
    }

    func testTutorHistoryPresentationResolverResolvesPracticeEvaluationHistory() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in throw TestFailure.unexpectedCall("explain") },
                practiceHandler: { request in
                    XCTAssertFalse(request.evidence.isEmpty)
                    return TutorPracticeDraft(
                        topic: request.topic,
                        recap: ["Practice from grounded ASK evidence."],
                        questions: [
                            TutorPracticeDraftQuestion(
                                prompt: "Who owns canonical knowledge?",
                                idealAnswer: "ASK owns canonical knowledge.",
                                hints: ["Look at the source of truth."],
                                conceptIDs: ["concept.ask.boundary"]
                            )
                        ]
                    )
                },
                gradeHandler: { request in
                    let questionID = try XCTUnwrap(request.practiceSet.questions.first?.questionID)
                    return TutorGradeDraft(
                        summary: "The learner identified the correct boundary.",
                        overallScore: 0.9,
                        itemResults: [
                            TutorGradeDraftItem(
                                questionID: questionID,
                                score: 0.9,
                                verdict: "correct",
                                feedback: "Correctly identified ASK as the truth owner.",
                                expectedPoints: ["ASK owns the canonical knowledge base."],
                                conceptIDs: ["concept.ask.boundary"]
                            )
                        ],
                        recommendedFocusTopics: ["Grounded tutoring"]
                    )
                }
            )
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try await seedPageIndex(
            workspace: runtime.workspace,
            askSourceID: "ask-src-1",
            projectionSlug: "wiki/asktutor"
        )
        XCTAssertFalse(try runtime.knowledge.search("grounded", limit: 8).hits.isEmpty)

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T10:30:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK practice history",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T10:31:00Z"
            )
        )
        let practiceSet = try await runtime.tutor.makePracticeSet(
            TutorPracticeRequest(
                sessionID: session.sessionID,
                topic: "grounded",
                questionCount: 1,
                requestedAt: "2026-04-13T10:32:00Z"
            )
        )
        XCTAssertFalse(practiceSet.questions.isEmpty)
        XCTAssertFalse(practiceSet.evidence.isEmpty)

        let evaluation = try await runtime.tutor.gradePractice(
            TutorGradePracticeRequest(
                learnerID: learner.learnerID,
                sessionID: session.sessionID,
                practiceSetID: practiceSet.practiceSetID,
                responses: [
                    TutorPracticeResponse(
                        questionID: try XCTUnwrap(practiceSet.questions.first?.questionID),
                        answer: "ASK owns canonical knowledge."
                    )
                ],
                requestedAt: "2026-04-13T10:33:00Z"
            )
        )

        let presentation = try await ASKTutorHistoryPresentationResolver().resolvePracticeEvaluation(
            sessionID: session.sessionID,
            practiceSetID: practiceSet.practiceSetID,
            runtime: runtime
        )

        XCTAssertEqual(presentation.evaluation.practiceSetID, evaluation.practiceSetID)
        XCTAssertEqual(presentation.practiceSetPresentation.practiceSet.practiceSetID, practiceSet.practiceSetID)
        XCTAssertEqual(presentation.practiceSetPresentation.scopePresentation.projectionLink.status, .linked)
        XCTAssertEqual(presentation.practiceSetPresentation.questions.count, 1)
        XCTAssertNil(practiceSet.questions.first?.citations.first?.projectionSlug)
        XCTAssertEqual(presentation.practiceSetPresentation.questions.first?.citationLinks.first?.status, .noProjection)
        XCTAssertEqual(presentation.practiceSetPresentation.evidence.count, practiceSet.evidence.count)
        XCTAssertNil(practiceSet.evidence.first?.projectionSlug)
        XCTAssertEqual(presentation.practiceSetPresentation.evidence.first?.projectionLink.status, .noProjection)
        XCTAssertNil(presentation.practiceSetPresentation.evidence.first?.projectionLink.projectionSlug)
    }

}
