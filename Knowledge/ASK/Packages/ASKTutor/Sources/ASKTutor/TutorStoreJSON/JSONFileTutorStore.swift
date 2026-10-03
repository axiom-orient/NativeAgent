import Foundation

package struct JSONFileTutorStoreHooks: Sendable {
    package var beforeCommit: @Sendable (_ target: URL, _ index: Int) throws -> Void
    package var afterCommit: @Sendable (_ target: URL, _ index: Int) throws -> Void

    package init(
        beforeCommit: @escaping @Sendable (_ target: URL, _ index: Int) throws -> Void = { _, _ in },
        afterCommit: @escaping @Sendable (_ target: URL, _ index: Int) throws -> Void = { _, _ in }
    ) {
        self.beforeCommit = beforeCommit
        self.afterCommit = afterCommit
    }

    package static let live = JSONFileTutorStoreHooks()
}

public actor JSONFileTutorStore: TutorBatchStore {
    private let layout: TutorStoreLayout
    private let fileIO: JSONFileTutorStoreIO
    private var isPrepared = false

    public init(rootURL: URL) {
        self.init(rootURL: rootURL, hooks: .live)
    }

    package init(rootURL: URL, hooks: JSONFileTutorStoreHooks) {
        let layout = TutorStoreLayout(rootURL: rootURL)
        self.layout = layout
        self.fileIO = JSONFileTutorStoreIO(layout: layout, hooks: hooks)
    }

    public func ensureRoot() async throws {
        try prepareStoreIfNeeded()
    }

    private func prepareStoreIfNeeded() throws {
        guard !isPrepared else { return }
        try fileIO.ensureRoot()
        isPrepared = true
    }

    public func loadLearner(learnerID: String) async throws -> LearnerProfile? {
        try prepareStoreIfNeeded()
        return try fileIO.load(LearnerProfile.self, at: layout.learnerURL(learnerID))
    }

    public func listLearners() async throws -> [LearnerProfile] {
        try await ensureRoot()
        return try fileIO.jsonFiles(in: layout.profilesDirectoryURL)
            .compactMap { try fileIO.load(LearnerProfile.self, at: $0) }
            .sorted(by: TutorLearnerRecency.isMoreRecent)
    }

    public func saveLearner(_ learner: LearnerProfile) async throws {
        try prepareStoreIfNeeded()
        try TutorStorePathValidation.ensurePathSafeID(learner.learnerID, field: "learnerID")
        try fileIO.save(learner, to: layout.learnerURL(learner.learnerID))
    }

    public func loadSession(sessionID: String) async throws -> TutorSession? {
        try prepareStoreIfNeeded()
        return try fileIO.load(TutorSession.self, at: layout.sessionURL(sessionID))
    }

    public func saveSession(_ session: TutorSession) async throws {
        try prepareStoreIfNeeded()
        try TutorStorePathValidation.ensurePathSafeID(session.sessionID, field: "sessionID")
        try TutorStorePathValidation.ensurePathSafeID(session.learnerID, field: "learnerID")
        try fileIO.save(session, to: layout.sessionURL(session.sessionID))
    }

    public func listSessions(learnerID: String) async throws -> [TutorSession] {
        try await ensureRoot()
        let sessions = try fileIO.jsonFiles(in: layout.sessionsDirectoryURL)
            .compactMap { try fileIO.load(TutorSession.self, at: $0) }
        return sessions
            .filter { $0.learnerID == learnerID }
            .sorted(by: TutorSessionRecency.isMoreRecent)
    }

    public func loadPracticeSet(practiceSetID: String) async throws -> TutorPracticeSet? {
        try prepareStoreIfNeeded()
        return try fileIO.load(TutorPracticeSet.self, at: layout.practiceSetURL(practiceSetID))
    }

    public func savePracticeSet(_ practiceSet: TutorPracticeSet) async throws {
        try prepareStoreIfNeeded()
        try TutorStorePathValidation.ensurePathSafeID(practiceSet.practiceSetID, field: "practiceSetID")
        try TutorStorePathValidation.ensurePathSafeID(practiceSet.sessionID, field: "sessionID")
        try fileIO.save(practiceSet, to: layout.practiceSetURL(practiceSet.practiceSetID))
    }

    public func loadPracticeEvaluation(sessionID: String, practiceSetID: String) async throws -> TutorPracticeEvaluation? {
        try prepareStoreIfNeeded()
        return try fileIO.load(
            TutorPracticeEvaluation.self,
            at: layout.practiceEvaluationURL(sessionID: sessionID, practiceSetID: practiceSetID)
        )
    }

    public func savePracticeEvaluation(_ evaluation: TutorPracticeEvaluation) async throws {
        try prepareStoreIfNeeded()
        try TutorStorePathValidation.ensurePathSafeID(evaluation.sessionID, field: "sessionID")
        try TutorStorePathValidation.ensurePathSafeID(evaluation.practiceSetID, field: "practiceSetID")
        try fileIO.save(
            evaluation,
            to: layout.practiceEvaluationURL(sessionID: evaluation.sessionID, practiceSetID: evaluation.practiceSetID)
        )
    }

    public func listPracticeEvaluations(learnerID: String, limit: Int) async throws -> [TutorPracticeEvaluation] {
        try await ensureRoot()
        let cappedLimit = max(0, limit)
        guard cappedLimit > 0 else { return [] }
        let sessions = try await listSessions(learnerID: learnerID)
        var evaluations: [TutorPracticeEvaluation] = []
        for session in sessions {
            let directory = try layout.sessionEvaluationsDirectoryURL(session.sessionID)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            let files = try fileIO.jsonFiles(in: directory)
            for file in files {
                if let evaluation = try fileIO.load(TutorPracticeEvaluation.self, at: file) {
                    appendTopK(evaluation, to: &evaluations, limit: cappedLimit, by: TutorPracticeEvaluationRecency.isMoreRecent)
                }
            }
        }
        return evaluations.sorted(by: TutorPracticeEvaluationRecency.isMoreRecent)
    }

    public func loadStudyPlan(learnerID: String, generatedAt: String) async throws -> TutorStudyPlan? {
        try prepareStoreIfNeeded()
        return try fileIO.load(
            TutorStudyPlan.self,
            at: layout.studyPlanURL(learnerID: learnerID, generatedAt: generatedAt)
        )
    }

    public func saveStudyPlan(_ plan: TutorStudyPlan) async throws {
        try prepareStoreIfNeeded()
        try TutorStorePathValidation.ensurePathSafeID(plan.learnerID, field: "learnerID")
        try TutorStorePathValidation.ensureRFC3339(plan.generatedAt, field: "generatedAt")
        try fileIO.save(plan, to: layout.studyPlanURL(learnerID: plan.learnerID, generatedAt: plan.generatedAt))
    }

    public func saveBatch(_ batch: TutorStoreBatch) async throws {
        guard batch.isEmpty == false else {
            return
        }
        try await ensureRoot()
        let writes = try TutorStoreBatchWritePlanner.plan(batch: batch, layout: layout, fileIO: fileIO)
        try fileIO.ensureUniqueTargets(writes)
        try fileIO.commitBatch(writes)
    }

    public func listStudyPlans(learnerID: String, limit: Int) async throws -> [TutorStudyPlan] {
        try await ensureRoot()
        let cappedLimit = max(0, limit)
        guard cappedLimit > 0 else { return [] }
        let directory = try layout.learnerPlansDirectoryURL(learnerID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        var plans: [TutorStudyPlan] = []
        for file in try fileIO.jsonFiles(in: directory) {
            if let plan = try fileIO.load(TutorStudyPlan.self, at: file) {
                appendTopK(plan, to: &plans, limit: cappedLimit, by: TutorStudyPlanRecency.isMoreRecent)
            }
        }
        return plans.sorted(by: TutorStudyPlanRecency.isMoreRecent)
    }

    public func exportArchive(learnerID: String, exportedAt: String) async throws -> TutorDataArchive {
        guard let learner = try await loadLearner(learnerID: learnerID) else {
            throw ASKTutorError.notFound("unknown learner `\(learnerID)`")
        }
        let sessions = try await listSessions(learnerID: learnerID)
        let sessionIDs = Set(sessions.map(\.sessionID))
        let practiceSets = try await listPracticeSets(sessionIDs: sessionIDs)
        let practiceEvaluations = try await listPracticeEvaluations(learnerID: learnerID, limit: .max)
        let studyPlans = try await listStudyPlans(learnerID: learnerID, limit: .max)
        return TutorDataArchive(
            exportedAt: exportedAt,
            learner: learner,
            sessions: sessions,
            practiceSets: practiceSets,
            practiceEvaluations: practiceEvaluations,
            studyPlans: studyPlans
        )
    }

    public func writeArchive(_ archive: TutorDataArchive, to url: URL) async throws {
        try fileIO.writeArchive(archive, to: url)
    }

    public func readArchive(from url: URL) async throws -> TutorDataArchive {
        try fileIO.readArchive(from: url)
    }

    public func importArchive(
        _ archive: TutorDataArchive,
        mergePolicy: TutorDataArchiveMergePolicy = .failOnConflict
    ) async throws -> TutorDataArchiveImportSummary {
        try await ensureRoot()

        let learner = try valueToSave(
            existing: try await loadLearner(learnerID: archive.learner.learnerID),
            incoming: archive.learner,
            identity: archive.learner.learnerID,
            mergePolicy: mergePolicy
        )
        var sessions: [TutorSession] = []
        for session in archive.sessions {
            if let value = try valueToSave(
                existing: try await loadSession(sessionID: session.sessionID),
                incoming: session,
                identity: session.sessionID,
                mergePolicy: mergePolicy
            ) {
                sessions.append(value)
            }
        }
        var practiceSets: [TutorPracticeSet] = []
        for practiceSet in archive.practiceSets {
            if let value = try valueToSave(
                existing: try await loadPracticeSet(practiceSetID: practiceSet.practiceSetID),
                incoming: practiceSet,
                identity: practiceSet.practiceSetID,
                mergePolicy: mergePolicy
            ) {
                practiceSets.append(value)
            }
        }
        var evaluations: [TutorPracticeEvaluation] = []
        for evaluation in archive.practiceEvaluations {
            if let value = try valueToSave(
                existing: try await loadPracticeEvaluation(
                    sessionID: evaluation.sessionID,
                    practiceSetID: evaluation.practiceSetID
                ),
                incoming: evaluation,
                identity: "\(evaluation.sessionID):\(evaluation.practiceSetID)",
                mergePolicy: mergePolicy
            ) {
                evaluations.append(value)
            }
        }
        var studyPlans: [TutorStudyPlan] = []
        for plan in archive.studyPlans {
            if let value = try valueToSave(
                existing: try await loadStudyPlan(
                    learnerID: plan.learnerID,
                    generatedAt: plan.generatedAt
                ),
                incoming: plan,
                identity: "\(plan.learnerID):\(plan.generatedAt)",
                mergePolicy: mergePolicy
            ) {
                studyPlans.append(value)
            }
        }

        let batch = TutorStoreBatch(
            learners: learner.map { [$0] } ?? [],
            sessions: sessions,
            practiceSets: practiceSets,
            practiceEvaluations: evaluations,
            studyPlans: studyPlans
        )
        try await saveBatch(batch)

        return TutorDataArchiveImportSummary(
            learnerSaved: learner != nil,
            sessionsSaved: sessions.count,
            practiceSetsSaved: practiceSets.count,
            evaluationsSaved: evaluations.count,
            studyPlansSaved: studyPlans.count
        )
    }

    private func listPracticeSets(sessionIDs: Set<String>) async throws -> [TutorPracticeSet] {
        try await ensureRoot()
        return try fileIO.jsonFiles(in: layout.practiceDirectoryURL)
            .compactMap { try fileIO.load(TutorPracticeSet.self, at: $0) }
            .filter { sessionIDs.contains($0.sessionID) }
            .sorted(by: TutorPracticeSetRecency.isMoreRecent)
    }

    private func valueToSave<Value: Equatable & Sendable>(
        existing: Value?,
        incoming: Value,
        identity: String,
        mergePolicy: TutorDataArchiveMergePolicy
    ) throws -> Value? {
        switch try TutorStoreMergePolicies.decision(
            existing: existing,
            incoming: incoming,
            identity: identity,
            mergePolicy: mergePolicy
        ) {
        case .keepExisting:
            return nil
        case .saveIncoming(let value):
            return value
        }
    }

}

private enum TutorSessionRecency {
    static func isMoreRecent(_ lhs: TutorSession, _ rhs: TutorSession) -> Bool {
        TutorStoreRecencyPolicies.isMoreRecent(
            lhs,
            rhs,
            timestamp: \.updatedAt,
            tieBreaker: \.sessionID
        )
    }
}

private enum TutorPracticeEvaluationRecency {
    static func isMoreRecent(_ lhs: TutorPracticeEvaluation, _ rhs: TutorPracticeEvaluation) -> Bool {
        TutorStoreRecencyPolicies.isMoreRecent(
            lhs,
            rhs,
            timestamp: \.createdAt,
            tieBreaker: \.practiceSetID
        )
    }
}

private enum TutorStudyPlanRecency {
    static func isMoreRecent(_ lhs: TutorStudyPlan, _ rhs: TutorStudyPlan) -> Bool {
        TutorStoreRecencyPolicies.isMoreRecent(
            lhs,
            rhs,
            timestamp: \.generatedAt,
            tieBreaker: \.headline
        )
    }
}

private func appendTopK<T>(_ value: T, to values: inout [T], limit: Int, by areInIncreasingOrder: (T, T) -> Bool) {
    values.append(value)
    if values.count > limit {
        values.sort(by: areInIncreasingOrder)
        values.removeSubrange(limit ..< values.count)
    }
}

private enum TutorLearnerRecency {
    static func isMoreRecent(_ lhs: LearnerProfile, _ rhs: LearnerProfile) -> Bool {
        TutorStoreRecencyPolicies.isMoreRecent(
            lhs,
            rhs,
            timestamp: \.updatedAt,
            tieBreaker: \.learnerID
        )
    }
}

private enum TutorPracticeSetRecency {
    static func isMoreRecent(_ lhs: TutorPracticeSet, _ rhs: TutorPracticeSet) -> Bool {
        TutorStoreRecencyPolicies.isMoreRecent(
            lhs,
            rhs,
            timestamp: \.createdAt,
            tieBreaker: \.practiceSetID
        )
    }
}
