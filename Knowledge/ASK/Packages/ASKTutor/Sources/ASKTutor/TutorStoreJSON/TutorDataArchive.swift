import Foundation

public struct TutorDataArchive: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var exportedAt: String
    public var learner: LearnerProfile
    public var sessions: [TutorSession]
    public var practiceSets: [TutorPracticeSet]
    public var practiceEvaluations: [TutorPracticeEvaluation]
    public var studyPlans: [TutorStudyPlan]

    public init(
        schemaVersion: Int = 1,
        exportedAt: String,
        learner: LearnerProfile,
        sessions: [TutorSession],
        practiceSets: [TutorPracticeSet],
        practiceEvaluations: [TutorPracticeEvaluation],
        studyPlans: [TutorStudyPlan]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.learner = learner
        self.sessions = sessions
        self.practiceSets = practiceSets
        self.practiceEvaluations = practiceEvaluations
        self.studyPlans = studyPlans
    }
}

public enum TutorDataArchiveMergePolicy: String, Codable, Sendable {
    case failOnConflict
    case keepExisting
    case replaceExisting
}

public struct TutorDataArchiveImportSummary: Codable, Sendable, Equatable {
    public var learnerSaved: Bool
    public var sessionsSaved: Int
    public var practiceSetsSaved: Int
    public var evaluationsSaved: Int
    public var studyPlansSaved: Int

    public init(
        learnerSaved: Bool,
        sessionsSaved: Int,
        practiceSetsSaved: Int,
        evaluationsSaved: Int,
        studyPlansSaved: Int
    ) {
        self.learnerSaved = learnerSaved
        self.sessionsSaved = sessionsSaved
        self.practiceSetsSaved = practiceSetsSaved
        self.evaluationsSaved = evaluationsSaved
        self.studyPlansSaved = studyPlansSaved
    }
}
