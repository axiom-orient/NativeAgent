import Foundation

public struct TutorPlanDraft: Codable, Sendable, Equatable {
    public var headline: String
    public var focusTopics: [String]
    public var actions: [String]
    public var rationale: [String]

    public init(headline: String, focusTopics: [String], actions: [String], rationale: [String]) {
        self.headline = headline
        self.focusTopics = focusTopics
        self.actions = actions
        self.rationale = rationale
    }
}

public struct TutorPlanModelRequest: Codable, Sendable, Equatable {
    public var learner: LearnerProfile
    public var recentSessions: [TutorSessionContext]
    public var dueConcepts: [TutorConceptState]
    public var knowledgeHealth: TutorKnowledgeHealthSnapshot

    public init(
        learner: LearnerProfile,
        recentSessions: [TutorSessionContext],
        dueConcepts: [TutorConceptState],
        knowledgeHealth: TutorKnowledgeHealthSnapshot
    ) {
        self.learner = learner
        self.recentSessions = recentSessions
        self.dueConcepts = dueConcepts
        self.knowledgeHealth = knowledgeHealth
    }
}
