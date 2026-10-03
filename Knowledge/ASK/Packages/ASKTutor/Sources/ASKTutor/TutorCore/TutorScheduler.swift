import Foundation

package struct TutorReviewScheduler: Sendable {
    package let configuration: TutorConfiguration

    package init(configuration: TutorConfiguration) {
        self.configuration = configuration
    }

    package func updateConcept(_ existing: TutorConceptState?, conceptID: String, label: String, score: Double, reviewedAt: String) throws -> TutorConceptState {
        guard let reviewedDate = TutorTime.parse(reviewedAt) else {
            throw ASKTutorError.invalidInput("reviewedAt must be RFC3339")
        }
        let normalizedScore = min(max(score, 0), 1)
        let attempts = (existing?.attempts ?? 0) + 1
        let oldStreak = existing?.consecutiveSuccesses ?? 0

        let newStreak: Int
        let level: TutorMasteryLevel
        let nextDays: Int

        if normalizedScore >= configuration.highScoreThreshold {
            newStreak = oldStreak + 1
            let intervalIndex = min(newStreak - 1, configuration.reviewIntervalsDays.count - 1)
            nextDays = configuration.reviewIntervalsDays[intervalIndex]
            switch newStreak {
            case 1: level = .practiced
            case 2: level = .strong
            default: level = .mastered
            }
        } else if normalizedScore >= configuration.partialScoreThreshold {
            newStreak = max(1, oldStreak)
            nextDays = configuration.reviewIntervalsDays.first ?? 1
            level = .practiced
        } else {
            newStreak = 0
            nextDays = configuration.reviewIntervalsDays.first ?? 1
            level = .exposed
        }

        let nextReview = Calendar(identifier: .gregorian).date(byAdding: .day, value: nextDays, to: reviewedDate) ?? reviewedDate
        return TutorConceptState(
            conceptID: conceptID,
            label: label,
            level: level,
            attempts: attempts,
            consecutiveSuccesses: newStreak,
            lastScore: normalizedScore,
            lastReviewedAt: reviewedAt,
            nextReviewAt: TutorTime.format(nextReview)
        )
    }
}
