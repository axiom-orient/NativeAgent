import Foundation

public struct TutorPracticeQuestion: Codable, Sendable, Equatable {
    public var questionID: String
    public var prompt: String
    public var idealAnswer: String
    public var hints: [String]
    public var conceptIDs: [String]
    public var citations: [TutorCitation]

    public init(
        questionID: String,
        prompt: String,
        idealAnswer: String,
        hints: [String],
        conceptIDs: [String],
        citations: [TutorCitation]
    ) {
        self.questionID = questionID
        self.prompt = prompt
        self.idealAnswer = idealAnswer
        self.hints = hints
        self.conceptIDs = conceptIDs
        self.citations = citations
    }
}

public struct TutorPracticeSet: Codable, Sendable, Equatable {
    public var practiceSetID: String
    public var sessionID: String
    public var topic: String
    public var createdAt: String
    public var recap: [String]
    public var questions: [TutorPracticeQuestion]
    public var evidence: [TutorEvidenceHit]

    public init(
        practiceSetID: String,
        sessionID: String,
        topic: String,
        createdAt: String,
        recap: [String],
        questions: [TutorPracticeQuestion],
        evidence: [TutorEvidenceHit]
    ) {
        self.practiceSetID = practiceSetID
        self.sessionID = sessionID
        self.topic = topic
        self.createdAt = createdAt
        self.recap = recap
        self.questions = questions
        self.evidence = evidence
    }
}

public struct TutorPracticeResponse: Codable, Sendable, Equatable {
    public var questionID: String
    public var answer: String

    public init(questionID: String, answer: String) {
        self.questionID = questionID
        self.answer = answer
    }
}

public struct TutorPracticeItemResult: Codable, Sendable, Equatable {
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

public struct TutorPracticeEvaluation: Codable, Sendable, Equatable {
    public var sessionID: String
    public var practiceSetID: String
    public var createdAt: String
    public var summary: String
    public var overallScore: Double
    public var itemResults: [TutorPracticeItemResult]
    public var updatedConceptStates: [TutorConceptState]
    public var recommendedFocusTopics: [String]

    public init(
        sessionID: String,
        practiceSetID: String,
        createdAt: String,
        summary: String,
        overallScore: Double,
        itemResults: [TutorPracticeItemResult],
        updatedConceptStates: [TutorConceptState],
        recommendedFocusTopics: [String]
    ) {
        self.sessionID = sessionID
        self.practiceSetID = practiceSetID
        self.createdAt = createdAt
        self.summary = summary
        self.overallScore = overallScore
        self.itemResults = itemResults
        self.updatedConceptStates = updatedConceptStates
        self.recommendedFocusTopics = recommendedFocusTopics
    }
}
