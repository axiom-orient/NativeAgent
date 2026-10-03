import Foundation

public struct TutorGoal: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct TutorPreferences: Codable, Sendable, Equatable {
    public var responseStyle: TutorResponseStyle
    public var practiceQuestionCount: Int

    public init(responseStyle: TutorResponseStyle = .standard, practiceQuestionCount: Int = 5) {
        self.responseStyle = responseStyle
        self.practiceQuestionCount = max(1, practiceQuestionCount)
    }
}

public struct TutorConceptState: Codable, Sendable, Equatable {
    public var conceptID: String
    public var label: String
    public var level: TutorMasteryLevel
    public var attempts: Int
    public var consecutiveSuccesses: Int
    public var lastScore: Double?
    public var lastReviewedAt: String?
    public var nextReviewAt: String?

    public init(
        conceptID: String,
        label: String,
        level: TutorMasteryLevel,
        attempts: Int,
        consecutiveSuccesses: Int,
        lastScore: Double?,
        lastReviewedAt: String?,
        nextReviewAt: String?
    ) {
        self.conceptID = conceptID
        self.label = label
        self.level = level
        self.attempts = attempts
        self.consecutiveSuccesses = consecutiveSuccesses
        self.lastScore = lastScore
        self.lastReviewedAt = lastReviewedAt
        self.nextReviewAt = nextReviewAt
    }
}

public struct LearnerProfile: Codable, Sendable, Equatable {
    public var learnerID: String
    public var displayName: String?
    public var goals: [TutorGoal]
    public var preferences: TutorPreferences
    public var conceptStates: [String: TutorConceptState]
    public var updatedAt: String

    public init(
        learnerID: String,
        displayName: String? = nil,
        goals: [TutorGoal] = [],
        preferences: TutorPreferences = TutorPreferences(),
        conceptStates: [String: TutorConceptState] = [:],
        updatedAt: String
    ) {
        self.learnerID = learnerID
        self.displayName = displayName
        self.goals = goals
        self.preferences = preferences
        self.conceptStates = conceptStates
        self.updatedAt = updatedAt
    }
}
