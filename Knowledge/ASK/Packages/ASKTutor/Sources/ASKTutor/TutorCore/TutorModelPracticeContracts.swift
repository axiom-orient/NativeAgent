import Foundation

public struct TutorPracticeDraftQuestion: Codable, Sendable, Equatable {
    public var prompt: String
    public var idealAnswer: String
    public var hints: [String]
    public var conceptIDs: [String]

    public init(prompt: String, idealAnswer: String, hints: [String], conceptIDs: [String]) {
        self.prompt = prompt
        self.idealAnswer = idealAnswer
        self.hints = hints
        self.conceptIDs = conceptIDs
    }
}

public struct TutorPracticeDraft: Codable, Sendable, Equatable {
    public var topic: String
    public var recap: [String]
    public var questions: [TutorPracticeDraftQuestion]

    public init(topic: String, recap: [String], questions: [TutorPracticeDraftQuestion]) {
        self.topic = topic
        self.recap = recap
        self.questions = questions
    }
}

public struct TutorPracticeModelRequest: Codable, Sendable, Equatable {
    public var learner: LearnerProfile
    public var session: TutorSessionContext
    public var topic: String
    public var evidence: [TutorEvidenceHit]
    public var projection: TutorProjectionSnapshot?
    public var questionCount: Int

    public init(
        learner: LearnerProfile,
        session: TutorSessionContext,
        topic: String,
        evidence: [TutorEvidenceHit],
        projection: TutorProjectionSnapshot?,
        questionCount: Int
    ) {
        self.learner = learner
        self.session = session
        self.topic = topic
        self.evidence = evidence
        self.projection = projection
        self.questionCount = questionCount
    }
}

public struct TutorGradeDraftItem: Codable, Sendable, Equatable {
    public var questionID: String
    public var score: Double
    public var verdict: String
    public var feedback: String
    public var expectedPoints: [String]
    public var conceptIDs: [String]

    public init(
        questionID: String,
        score: Double,
        verdict: String,
        feedback: String,
        expectedPoints: [String],
        conceptIDs: [String]
    ) {
        self.questionID = questionID
        self.score = score
        self.verdict = verdict
        self.feedback = feedback
        self.expectedPoints = expectedPoints
        self.conceptIDs = conceptIDs
    }
}

public struct TutorGradeDraft: Codable, Sendable, Equatable {
    public var summary: String
    public var overallScore: Double
    public var itemResults: [TutorGradeDraftItem]
    public var recommendedFocusTopics: [String]

    public init(
        summary: String,
        overallScore: Double,
        itemResults: [TutorGradeDraftItem],
        recommendedFocusTopics: [String]
    ) {
        self.summary = summary
        self.overallScore = overallScore
        self.itemResults = itemResults
        self.recommendedFocusTopics = recommendedFocusTopics
    }
}

public struct TutorGradeModelRequest: Codable, Sendable, Equatable {
    public var learner: LearnerProfile
    public var session: TutorSessionContext
    public var practiceSet: TutorPracticeSet
    public var responses: [TutorPracticeResponse]

    public init(
        learner: LearnerProfile,
        session: TutorSessionContext,
        practiceSet: TutorPracticeSet,
        responses: [TutorPracticeResponse]
    ) {
        self.learner = learner
        self.session = session
        self.practiceSet = practiceSet
        self.responses = responses
    }
}
