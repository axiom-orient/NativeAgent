import Foundation
import Testing
import ASKTutor

struct TutorSchedulerTests {
    @Test
    func highScoreAdvancesThroughReviewIntervals() async throws {
        let scheduler = TutorReviewScheduler(configuration: TutorConfiguration(reviewIntervalsDays: [1, 3, 7]))
        let first = try scheduler.updateConcept(nil, conceptID: "c1", label: "Concept", score: 0.95, reviewedAt: "2026-04-10T00:00:00Z")
        #expect(first.level == .practiced)
        #expect(first.consecutiveSuccesses == 1)

        let second = try scheduler.updateConcept(first, conceptID: "c1", label: "Concept", score: 0.95, reviewedAt: "2026-04-11T00:00:00Z")
        #expect(second.level == .strong)
        #expect(second.consecutiveSuccesses == 2)

        let third = try scheduler.updateConcept(second, conceptID: "c1", label: "Concept", score: 0.95, reviewedAt: "2026-04-14T00:00:00Z")
        #expect(third.level == .mastered)
        #expect(third.consecutiveSuccesses == 3)
    }

    @Test
    func partialScoreKeepsConceptInPracticedState() async throws {
        let scheduler = TutorReviewScheduler(configuration: TutorConfiguration(highScoreThreshold: 0.85, partialScoreThreshold: 0.55, reviewIntervalsDays: [1, 3, 7]))
        let existing = TutorConceptState(conceptID: "c1", label: "Concept", level: .exposed, attempts: 1, consecutiveSuccesses: 0, lastScore: 0.4, lastReviewedAt: "2026-04-09T00:00:00Z", nextReviewAt: "2026-04-10T00:00:00Z")
        let updated = try scheduler.updateConcept(existing, conceptID: "c1", label: "Concept", score: 0.6, reviewedAt: "2026-04-10T00:00:00Z")
        #expect(updated.level == TutorMasteryLevel.practiced)
        #expect(updated.consecutiveSuccesses == 1)
    }

    @Test
    func attemptCounterOverflowIsRejected() throws {
        let scheduler = TutorReviewScheduler(configuration: TutorConfiguration())
        let existing = TutorConceptState(
            conceptID: "c1",
            label: "Concept",
            level: .exposed,
            attempts: Int.max,
            consecutiveSuccesses: 0,
            lastScore: 0,
            lastReviewedAt: nil,
            nextReviewAt: nil
        )

        #expect(throws: ASKTutorError.self) {
            _ = try scheduler.updateConcept(
                existing,
                conceptID: "c1",
                label: "Concept",
                score: 0.5,
                reviewedAt: "2026-04-10T00:00:00Z"
            )
        }
    }

    @Test
    func negativeConceptCountersAreRejected() throws {
        let scheduler = TutorReviewScheduler(configuration: TutorConfiguration())
        let existing = TutorConceptState(
            conceptID: "c1",
            label: "Concept",
            level: .exposed,
            attempts: -1,
            consecutiveSuccesses: 0,
            lastScore: 0,
            lastReviewedAt: nil,
            nextReviewAt: nil
        )

        #expect(throws: ASKTutorError.self) {
            _ = try scheduler.updateConcept(
                existing,
                conceptID: "c1",
                label: "Concept",
                score: 0.5,
                reviewedAt: "2026-04-10T00:00:00Z"
            )
        }
    }

    @Test
    func nonFiniteScoreIsRejected() throws {
        let scheduler = TutorReviewScheduler(configuration: TutorConfiguration())

        #expect(throws: ASKTutorError.self) {
            _ = try scheduler.updateConcept(
                nil,
                conceptID: "c1",
                label: "Concept",
                score: .nan,
                reviewedAt: "2026-04-10T00:00:00Z"
            )
        }
    }
}
