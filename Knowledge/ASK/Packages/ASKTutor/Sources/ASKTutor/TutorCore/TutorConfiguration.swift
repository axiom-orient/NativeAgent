import Foundation

public struct TutorConfiguration: Sendable, Equatable, Codable {
    public var searchLimit: Int
    public var maxCitations: Int
    public var defaultPracticeQuestionCount: Int
    public var recentTranscriptLimit: Int
    public var highScoreThreshold: Double
    public var partialScoreThreshold: Double
    public var reviewIntervalsDays: [Int]

    public init(
        searchLimit: Int = 8,
        maxCitations: Int = 5,
        defaultPracticeQuestionCount: Int = 5,
        recentTranscriptLimit: Int = 8,
        highScoreThreshold: Double = 0.85,
        partialScoreThreshold: Double = 0.55,
        reviewIntervalsDays: [Int] = [1, 3, 7, 14, 30]
    ) {
        self.searchLimit = max(1, searchLimit)
        self.maxCitations = max(1, maxCitations)
        self.defaultPracticeQuestionCount = max(1, defaultPracticeQuestionCount)
        self.recentTranscriptLimit = max(1, recentTranscriptLimit)
        self.highScoreThreshold = min(max(highScoreThreshold, 0), 1)
        self.partialScoreThreshold = min(max(partialScoreThreshold, 0), 1)
        self.reviewIntervalsDays = reviewIntervalsDays.isEmpty ? [1, 3, 7, 14, 30] : reviewIntervalsDays.map { max(1, $0) }
    }
}
