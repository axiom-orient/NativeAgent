import Foundation

public struct TutorStudyPlan: Codable, Sendable, Equatable {
    public var learnerID: String
    public var generatedAt: String
    public var headline: String
    public var focusTopics: [String]
    public var actions: [String]
    public var rationale: [String]
    public var dueConceptIDs: [String]
    public var knowledgeMaintenance: [TutorKnowledgeMaintenanceItem]

    public init(
        learnerID: String,
        generatedAt: String,
        headline: String,
        focusTopics: [String],
        actions: [String],
        rationale: [String],
        dueConceptIDs: [String],
        knowledgeMaintenance: [TutorKnowledgeMaintenanceItem]
    ) {
        self.learnerID = learnerID
        self.generatedAt = generatedAt
        self.headline = headline
        self.focusTopics = focusTopics
        self.actions = actions
        self.rationale = rationale
        self.dueConceptIDs = dueConceptIDs
        self.knowledgeMaintenance = knowledgeMaintenance
    }
}
