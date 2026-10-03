import Foundation

public struct TutorStoreBatch: Sendable {
    public var learners: [LearnerProfile]
    public var sessions: [TutorSession]
    public var practiceSets: [TutorPracticeSet]
    public var practiceEvaluations: [TutorPracticeEvaluation]
    public var studyPlans: [TutorStudyPlan]

    public init(
        learners: [LearnerProfile] = [],
        sessions: [TutorSession] = [],
        practiceSets: [TutorPracticeSet] = [],
        practiceEvaluations: [TutorPracticeEvaluation] = [],
        studyPlans: [TutorStudyPlan] = []
    ) {
        self.learners = learners
        self.sessions = sessions
        self.practiceSets = practiceSets
        self.practiceEvaluations = practiceEvaluations
        self.studyPlans = studyPlans
    }

    public var isEmpty: Bool {
        learners.isEmpty
            && sessions.isEmpty
            && practiceSets.isEmpty
            && practiceEvaluations.isEmpty
            && studyPlans.isEmpty
    }
}

public protocol TutorStore: Sendable {
    func ensureRoot() async throws

    func loadLearner(learnerID: String) async throws -> LearnerProfile?
    func listLearners() async throws -> [LearnerProfile]
    func saveLearner(_ learner: LearnerProfile) async throws

    func loadSession(sessionID: String) async throws -> TutorSession?
    func saveSession(_ session: TutorSession) async throws
    func listSessions(learnerID: String) async throws -> [TutorSession]

    func loadPracticeSet(practiceSetID: String) async throws -> TutorPracticeSet?
    func savePracticeSet(_ practiceSet: TutorPracticeSet) async throws

    func loadPracticeEvaluation(sessionID: String, practiceSetID: String) async throws -> TutorPracticeEvaluation?
    func savePracticeEvaluation(_ evaluation: TutorPracticeEvaluation) async throws
    func listPracticeEvaluations(learnerID: String, limit: Int) async throws -> [TutorPracticeEvaluation]

    func loadStudyPlan(learnerID: String, generatedAt: String) async throws -> TutorStudyPlan?
    func saveStudyPlan(_ plan: TutorStudyPlan) async throws
    func listStudyPlans(learnerID: String, limit: Int) async throws -> [TutorStudyPlan]
}

public protocol TutorBatchStore: TutorStore {
    func saveBatch(_ batch: TutorStoreBatch) async throws
}
