import Foundation

package struct TutorReviewScheduler: Sendable {
    package let configuration: TutorConfiguration

    package init(configuration: TutorConfiguration) {
        self.configuration = configuration
    }

    package func updateConcept(_ existing: TutorConceptState?, conceptID: String, label: String, score: Double, reviewedAt: String) throws -> TutorConceptState {
        try configuration.validate()
        guard let reviewedDate = TutorTime.parse(reviewedAt) else {
            throw ASKTutorError.invalidInput("reviewedAt must be RFC3339")
        }
        guard score.isFinite else {
            throw ASKTutorError.invalidInput("score must be finite")
        }
        let normalizedScore = min(max(score, 0), 1)
        let oldAttempts = existing?.attempts ?? 0
        let oldStreak = existing?.consecutiveSuccesses ?? 0
        guard oldAttempts >= 0, oldStreak >= 0 else {
            throw ASKTutorError.invalidInput("concept counters must be non-negative")
        }
        let (attempts, attemptsOverflow) = oldAttempts.addingReportingOverflow(1)
        guard !attemptsOverflow else {
            throw ASKTutorError.invalidInput("concept attempt counter overflow")
        }

        let newStreak: Int
        let level: TutorMasteryLevel
        let nextDays: Int

        if normalizedScore >= configuration.highScoreThreshold {
            let (advancedStreak, streakOverflow) = oldStreak.addingReportingOverflow(1)
            guard !streakOverflow else {
                throw ASKTutorError.invalidInput("concept success counter overflow")
            }
            newStreak = advancedStreak
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
