import Foundation

public struct TutorConfiguration: Sendable, Equatable, Codable {
    public var searchLimit: Int
    public var maxCitations: Int
    public var defaultPracticeQuestionCount: Int
    public var recentTranscriptLimit: Int
    public var highScoreThreshold: Double
    public var partialScoreThreshold: Double
    public var reviewIntervalsDays: [Int]

    private enum CodingKeys: String, CodingKey {
        case searchLimit, maxCitations, defaultPracticeQuestionCount, recentTranscriptLimit
        case highScoreThreshold, partialScoreThreshold, reviewIntervalsDays
    }

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
        self.highScoreThreshold = highScoreThreshold.isFinite ? min(max(highScoreThreshold, 0), 1) : highScoreThreshold
        self.partialScoreThreshold = partialScoreThreshold.isFinite ? min(max(partialScoreThreshold, 0), 1) : partialScoreThreshold
        self.reviewIntervalsDays = reviewIntervalsDays.isEmpty ? [1, 3, 7, 14, 30] : reviewIntervalsDays.map { max(1, $0) }
    }

    func validate() throws {
        guard searchLimit > 0, maxCitations > 0, defaultPracticeQuestionCount > 0,
              recentTranscriptLimit > 0, highScoreThreshold.isFinite, partialScoreThreshold.isFinite,
              (0...1).contains(highScoreThreshold), (0...1).contains(partialScoreThreshold),
              partialScoreThreshold <= highScoreThreshold,
              !reviewIntervalsDays.isEmpty, reviewIntervalsDays.allSatisfy({ $0 > 0 }) else {
            throw ASKTutorError.invalidInput("tutor configuration is outside its supported bounds")
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        searchLimit = try values.decode(Int.self, forKey: .searchLimit)
        maxCitations = try values.decode(Int.self, forKey: .maxCitations)
        defaultPracticeQuestionCount = try values.decode(Int.self, forKey: .defaultPracticeQuestionCount)
        recentTranscriptLimit = try values.decode(Int.self, forKey: .recentTranscriptLimit)
        highScoreThreshold = try values.decode(Double.self, forKey: .highScoreThreshold)
        partialScoreThreshold = try values.decode(Double.self, forKey: .partialScoreThreshold)
        reviewIntervalsDays = try values.decode([Int].self, forKey: .reviewIntervalsDays)
        try validate()
    }
}
