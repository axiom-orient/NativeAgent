import Foundation

public struct TutorBootstrapRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public var displayName: String?
    public var goals: [TutorGoal]
    public var requestedAt: String

    public init(learnerID: String, displayName: String? = nil, goals: [TutorGoal] = [], requestedAt: String) {
        self.learnerID = learnerID
        self.displayName = displayName
        self.goals = goals
        self.requestedAt = requestedAt
    }
}

public struct TutorStartSessionRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public var title: String
    public var scope: TutorScope
    public var requestedAt: String

    public init(learnerID: String, title: String, scope: TutorScope, requestedAt: String) {
        self.learnerID = learnerID
        self.title = title
        self.scope = scope
        self.requestedAt = requestedAt
    }
}

public struct TutorExplainRequest: Sendable, Equatable, Codable {
    public var sessionID: String
    public var prompt: String
    public var requestedAt: String

    public init(sessionID: String, prompt: String, requestedAt: String) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.requestedAt = requestedAt
    }
}

public struct TutorSolveRequest: Sendable, Equatable, Codable {
    public var sessionID: String
    public var prompt: String
    public var requestedAt: String

    public init(sessionID: String, prompt: String, requestedAt: String) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.requestedAt = requestedAt
    }
}

public struct TutorPracticeRequest: Sendable, Equatable, Codable {
    public var sessionID: String
    public var topic: String
    public var questionCount: Int?
    public var requestedAt: String

    public init(sessionID: String, topic: String, questionCount: Int? = nil, requestedAt: String) {
        self.sessionID = sessionID
        self.topic = topic
        self.questionCount = questionCount
        self.requestedAt = requestedAt
    }
}

public struct TutorGradePracticeRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public var sessionID: String
    public var practiceSetID: String
    public var responses: [TutorPracticeResponse]
    public var requestedAt: String

    public init(learnerID: String, sessionID: String, practiceSetID: String, responses: [TutorPracticeResponse], requestedAt: String) {
        self.learnerID = learnerID
        self.sessionID = sessionID
        self.practiceSetID = practiceSetID
        self.responses = responses
        self.requestedAt = requestedAt
    }
}

public struct TutorPlanRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public var requestedAt: String

    public init(learnerID: String, requestedAt: String) {
        self.learnerID = learnerID
        self.requestedAt = requestedAt
    }
}

public struct TutorPracticeHistoryRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public var limit: Int

    public init(learnerID: String, limit: Int = 20) {
        self.learnerID = learnerID
        self.limit = limit
    }
}

public struct TutorStudyPlanHistoryRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public var limit: Int

    public init(learnerID: String, limit: Int = 20) {
        self.learnerID = learnerID
        self.limit = limit
    }
}
