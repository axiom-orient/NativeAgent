import Foundation

public struct TutorLearnerLookupRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public init(learnerID: String) { self.learnerID = learnerID }
}

public struct TutorSessionListRequest: Sendable, Equatable, Codable {
    public var learnerID: String
    public init(learnerID: String) { self.learnerID = learnerID }
}

public struct TutorSessionLookupRequest: Sendable, Equatable, Codable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct TutorPracticeSetLookupRequest: Sendable, Equatable, Codable {
    public var practiceSetID: String
    public init(practiceSetID: String) { self.practiceSetID = practiceSetID }
}

public struct TutorPracticeEvaluationLookupRequest: Sendable, Equatable, Codable {
    public var sessionID: String
    public var practiceSetID: String
    public init(sessionID: String, practiceSetID: String) {
        self.sessionID = sessionID
        self.practiceSetID = practiceSetID
    }
}
