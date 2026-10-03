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
    func testNarrativeInsightCapturePersistsProvenanceAndSourceIDs() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in
                    TutorNarrativeDraft(
                        title: "ASK and Tutor",
                        summary: "Tutor should teach from ASK without owning the truth.",
                        sections: [
                            TutorNarrativeSection(
                                heading: "Boundary",
                                body: "Keep ASK as the truth owner and Tutor as the tutoring layer."
                            )
                        ],
                        comprehensionChecks: ["Who owns canonical knowledge?"],
                        followUpPrompts: ["Explain the read-only boundary."]
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

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T09:00:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK overview",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T09:01:00Z"
            )
        )
        let prompt = "How should Tutor use ASK knowledge?"
        let reply = try await runtime.tutor.explain(
            TutorExplainRequest(
                sessionID: session.sessionID,
                prompt: prompt,
                requestedAt: "2026-04-13T09:02:00Z"
            )
        )

        let capture = runtime.makeTutorInsightCapture()
        let candidate = try capture.captureNarrative(
            learnerID: learner.learnerID,
            session: session,
            prompt: prompt,
            reply: reply,
            candidateID: "candidate-narrative"
        )

        XCTAssertEqual(candidate.kind, .narrative)
        XCTAssertEqual(candidate.primaryProjectionSlug, "wiki/asktutor")
        XCTAssertEqual(candidate.sourceIDs, ["ask-src-1"])
        XCTAssertTrue(candidate.bodyMarkdown.contains("## Prompt"))
        XCTAssertTrue(candidate.bodyMarkdown.contains("## Boundary"))
        XCTAssertTrue(candidate.suggestedActions.contains(.updateProjection))
        XCTAssertTrue(candidate.suggestedActions.contains(.reviewKnowledgeGap))

        let persisted = try XCTUnwrap(runtime.tutorInsightStore.load(candidateID: "candidate-narrative"))
        XCTAssertEqual(persisted, candidate)
    }

    func testTutorInsightCaptureNarrativeSuggestedActionsStayCanonicalAndUnique() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let capture = TutorInsightCapture(store: TutorInsightCandidateStore(rootURL: rootURL.appendingPathComponent("pending")))
        let session = TutorSession(
            sessionID: "session-1",
            learnerID: "learner-1",
            title: "ASK overview",
            scope: .projection(slug: "wiki/asktutor"),
            createdAt: "2026-04-13T09:00:00Z",
            updatedAt: "2026-04-13T09:00:00Z"
        )
        let reply = TutorReply(
            sessionID: session.sessionID,
            turnID: "turn-1",
            intent: .explain,
            createdAt: "2026-04-13T09:01:00Z",
            title: "ASK and Tutor",
            summary: "Tutor should teach from ASK without owning the truth.",
            sections: [TutorNarrativeSection(heading: "Boundary", body: "ASK owns truth.")],
            comprehensionChecks: [],
            followUpPrompts: [],
            citations: [],
            knowledgeGap: TutorKnowledgeGap(
                patchID: "patch-1",
                requiresHumanApproval: true,
                requiresHumanChoice: false,
                warnings: ["review needed"]
            )
        )

        let candidate = try capture.captureNarrative(
            learnerID: "learner-1",
            session: session,
            prompt: "How should Tutor use ASK knowledge?",
            reply: reply,
            candidateID: "candidate-actions-narrative"
        )

        XCTAssertEqual(candidate.suggestedActions, [.updateProjection, .reviewKnowledgeGap])
    }

    func testTutorInsightCapturePracticeEvaluationSuggestedActionsIncludePracticeReviewOnce() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let capture = TutorInsightCapture(store: TutorInsightCandidateStore(rootURL: rootURL.appendingPathComponent("pending")))
        let session = TutorSession(
            sessionID: "session-1",
            learnerID: "learner-1",
            title: "Practice",
            scope: .projection(slug: "wiki/asktutor"),
            createdAt: "2026-04-13T10:00:00Z",
            updatedAt: "2026-04-13T10:00:00Z"
        )
        let practiceSet = TutorPracticeSet(
            practiceSetID: "practice-1",
            sessionID: session.sessionID,
            topic: "Grounding",
            createdAt: "2026-04-13T10:01:00Z",
            recap: ["Review grounding evidence."],
            questions: [
                TutorPracticeQuestion(
                    questionID: "q1",
                    prompt: "What owns truth?",
                    idealAnswer: "ASK owns truth.",
                    hints: [],
                    conceptIDs: ["ask.truth"],
                    citations: []
                )
            ],
            evidence: []
        )
        let evaluation = TutorPracticeEvaluation(
            sessionID: session.sessionID,
            practiceSetID: practiceSet.practiceSetID,
            createdAt: "2026-04-13T10:02:00Z",
            summary: "Needs more precision on grounding.",
            overallScore: 0.5,
            itemResults: [
                TutorPracticeItemResult(
                    questionID: "q1",
                    score: 0.5,
                    verdict: "partial",
                    feedback: "Mention ASK explicitly.",
                    expectedPoints: ["ASK owns truth"],
                    conceptIDs: ["ask.truth"]
                )
            ],
            updatedConceptStates: [],
            recommendedFocusTopics: ["Grounding"]
        )

        let candidate = try capture.capturePracticeEvaluation(
            learnerID: "learner-1",
            session: session,
            practiceSet: practiceSet,
            evaluation: evaluation,
            candidateID: "candidate-actions-practice-eval"
        )

        XCTAssertEqual(candidate.suggestedActions, [.updateProjection, .reviewKnowledgeGap, .reviewPracticeWeaknesses])
    }

    func testTutorInsightCaptureStudyPlanWithoutProjectionSuggestsCreateProjectionAndStudyPlanReview() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let capture = TutorInsightCapture(store: TutorInsightCandidateStore(rootURL: rootURL.appendingPathComponent("pending")))
        let plan = TutorStudyPlan(
            learnerID: "learner-1",
            generatedAt: "2026-04-13T11:00:00Z",
            headline: "ASK grounding plan",
            focusTopics: ["Grounding"],
            actions: ["Review ASK truth boundary"],
            rationale: ["Keep Tutor read-oriented until review closes."],
            dueConceptIDs: ["ask.truth"],
            knowledgeMaintenance: [TutorKnowledgeMaintenanceItem(kind: "review", summary: "Review truth boundary")]
        )

        let candidate = try capture.captureStudyPlan(
            learnerID: "learner-1",
            scope: nil,
            plan: plan,
            candidateID: "candidate-actions-study-plan"
        )

        XCTAssertEqual(candidate.suggestedActions, [.createProjection, .reviewKnowledgeGap, .reviewStudyPlan])
    }

    func testTutorInsightCapturePracticeSetResolvesProjectionAndSourceIDsFromEvidenceAndKnowledgeReader() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = ASKProductWorkspacePaths(rootURL: rootURL)
        let knowledgeReader = ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot)
        try knowledgeReader.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner.",
            sourceIDs: ["projection-src-1"]
        )

        let capture = TutorInsightCapture(
            store: TutorInsightCandidateStore(rootURL: rootURL.appendingPathComponent("pending")),
            knowledgeReader: knowledgeReader
        )
        let session = TutorSession(
            sessionID: "session-1",
            learnerID: "learner-1",
            title: "Practice",
            scope: .projection(slug: "wiki/asktutor"),
            createdAt: "2026-04-13T10:00:00Z",
            updatedAt: "2026-04-13T10:00:00Z"
        )
        let practiceSet = TutorPracticeSet(
            practiceSetID: "practice-1",
            sessionID: session.sessionID,
            topic: "Grounding",
            createdAt: "2026-04-13T10:01:00Z",
            recap: ["Review grounding evidence."],
            questions: [
                TutorPracticeQuestion(
                    questionID: "q1",
                    prompt: "What owns truth?",
                    idealAnswer: "ASK owns truth.",
                    hints: ["Name the canonical owner."],
                    conceptIDs: ["ask.truth", " ask.truth "],
                    citations: [
                        TutorCitation(docID: "doc-1", title: "ASK Tutor", projectionSlug: " wiki/asktutor ")
                    ]
                )
            ],
            evidence: [
                TutorEvidenceHit(
                    docID: "search-1",
                    docKind: "projection",
                    title: "ASK Tutor",
                    subjectKind: "topic",
                    subjectID: "asktutor",
                    projectionSlug: " wiki/asktutor ",
                    score: 1.0,
                    snippet: "ASK owns truth.",
                    metadata: ["source_ids": " hit-src-1 , projection-src-1 "]
                )
            ]
        )

        let candidate = try capture.capturePracticeSet(
            learnerID: "learner-1",
            session: session,
            practiceSet: practiceSet,
            candidateID: "candidate-practice-set"
        )

        XCTAssertEqual(candidate.kind, .practiceSet)
        XCTAssertEqual(candidate.primaryProjectionSlug, "wiki/asktutor")
        XCTAssertEqual(candidate.citationProjectionSlugs, ["wiki/asktutor"])
        XCTAssertEqual(candidate.sourceIDs, ["projection-src-1", "hit-src-1"])
        XCTAssertEqual(candidate.relatedConceptIDs, ["ask.truth"])
        XCTAssertEqual(candidate.evidence.count, 2)
        XCTAssertTrue(candidate.bodyMarkdown.contains("## Recap"))
        XCTAssertTrue(candidate.bodyMarkdown.contains("### Hints"))
        XCTAssertTrue(candidate.bodyMarkdown.contains("### Concepts"))
    }

    func testTutorInsightCaptureStudyPlanUsesProjectionSourceIDsAndFormatsMaintenance() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = ASKProductWorkspacePaths(rootURL: rootURL)
        let knowledgeReader = ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot)
        try knowledgeReader.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner.",
            sourceIDs: ["projection-src-1", "projection-src-2"]
        )

        let capture = TutorInsightCapture(
            store: TutorInsightCandidateStore(rootURL: rootURL.appendingPathComponent("pending")),
            knowledgeReader: knowledgeReader
        )
        let plan = TutorStudyPlan(
            learnerID: "learner-1",
            generatedAt: "2026-04-13T11:00:00Z",
            headline: "ASK grounding plan",
            focusTopics: ["Grounding"],
            actions: ["Review ASK truth boundary"],
            rationale: ["Keep Tutor read-oriented until review closes."],
            dueConceptIDs: ["ask.truth", " ask.truth "],
            knowledgeMaintenance: [
                TutorKnowledgeMaintenanceItem(kind: "review", summary: "Review truth boundary")
            ]
        )

        let candidate = try capture.captureStudyPlan(
            learnerID: "learner-1",
            scope: .projection(slug: "wiki/asktutor"),
            plan: plan,
            candidateID: "candidate-study-plan-with-projection"
        )

        XCTAssertEqual(candidate.primaryProjectionSlug, "wiki/asktutor")
        XCTAssertEqual(candidate.sourceIDs, ["projection-src-1", "projection-src-2"])
        XCTAssertEqual(candidate.relatedConceptIDs, ["ask.truth"])
        XCTAssertTrue(candidate.bodyMarkdown.contains("## Focus topics"))
        XCTAssertTrue(candidate.bodyMarkdown.contains("## Actions"))
        XCTAssertTrue(candidate.bodyMarkdown.contains("## Knowledge maintenance"))
    }

}
