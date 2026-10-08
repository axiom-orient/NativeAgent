import Foundation
import Testing
@testable import ASKTutor

struct TutorPracticeEvaluationTests {
    @Test
    func nonFiniteOverallScoreIsRejectedBeforePersistenceStateIsBuilt() throws {
        let (learner, session, practiceSet) = fixtures()
        let draft = TutorGradeDraft(
            summary: "summary",
            overallScore: .nan,
            itemResults: [],
            recommendedFocusTopics: []
        )

        #expect(throws: ASKTutorError.self) {
            _ = try TutorPracticeEvaluationReducer.reduce(
                learner: learner,
                session: session,
                practiceSet: practiceSet,
                draft: draft,
                configuration: TutorConfiguration(),
                requestedAt: "2026-04-10T00:00:00Z"
            )
        }
    }

    @Test
    func nonFiniteItemScoreIsRejectedBeforeConceptMutation() throws {
        let (learner, session, practiceSet) = fixtures()
        let draft = TutorGradeDraft(
            summary: "summary",
            overallScore: 0.5,
            itemResults: [
                TutorGradeDraftItem(
                    questionID: "q1",
                    score: .infinity,
                    verdict: "invalid",
                    feedback: "invalid",
                    expectedPoints: [],
                    conceptIDs: []
                )
            ],
            recommendedFocusTopics: []
        )

        #expect(throws: ASKTutorError.self) {
            _ = try TutorPracticeEvaluationReducer.reduce(
                learner: learner,
                session: session,
                practiceSet: practiceSet,
                draft: draft,
                configuration: TutorConfiguration(),
                requestedAt: "2026-04-10T00:00:00Z"
            )
        }
    }

    private func fixtures() -> (LearnerProfile, TutorSession, TutorPracticeSet) {
        (
            LearnerProfile(learnerID: "learner-1", updatedAt: "2026-04-10T00:00:00Z"),
            TutorSession(
                sessionID: "session-1",
                learnerID: "learner-1",
                title: "Review",
                scope: .global,
                createdAt: "2026-04-10T00:00:00Z",
                updatedAt: "2026-04-10T00:00:00Z"
            ),
            TutorPracticeSet(
                practiceSetID: "practice-1",
                sessionID: "session-1",
                topic: "Topic",
                createdAt: "2026-04-10T00:00:00Z",
                recap: [],
                questions: [],
                evidence: []
            )
        )
    }
}
