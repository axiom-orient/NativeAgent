
package enum TutorStoreBatchWritePlanner {
    package static func plan(
        batch: TutorStoreBatch,
        layout: TutorStoreLayout,
        fileIO: JSONFileTutorStoreIO
    ) throws -> [JSONFileTutorStoreStagedWrite] {
        var writes: [JSONFileTutorStoreStagedWrite] = []
        writes.reserveCapacity(
            batch.learners.count
            + batch.sessions.count
            + batch.practiceSets.count
            + batch.practiceEvaluations.count
            + batch.studyPlans.count
        )

        try appendLearnerWrites(from: batch.learners, layout: layout, fileIO: fileIO, writes: &writes)
        try appendSessionWrites(from: batch.sessions, layout: layout, fileIO: fileIO, writes: &writes)
        try appendPracticeSetWrites(from: batch.practiceSets, layout: layout, fileIO: fileIO, writes: &writes)
        try appendPracticeEvaluationWrites(from: batch.practiceEvaluations, layout: layout, fileIO: fileIO, writes: &writes)
        try appendStudyPlanWrites(from: batch.studyPlans, layout: layout, fileIO: fileIO, writes: &writes)

        return writes
    }

    private static func appendLearnerWrites(
        from learners: [LearnerProfile],
        layout: TutorStoreLayout,
        fileIO: JSONFileTutorStoreIO,
        writes: inout [JSONFileTutorStoreStagedWrite]
    ) throws {
        for learner in learners {
            try TutorStorePathValidation.ensurePathSafeID(learner.learnerID, field: "learnerID")
            writes.append(try fileIO.makeWrite(learner, to: layout.learnerURL(learner.learnerID)))
        }
    }

    private static func appendSessionWrites(
        from sessions: [TutorSession],
        layout: TutorStoreLayout,
        fileIO: JSONFileTutorStoreIO,
        writes: inout [JSONFileTutorStoreStagedWrite]
    ) throws {
        for session in sessions {
            try TutorStorePathValidation.ensurePathSafeID(session.sessionID, field: "sessionID")
            try TutorStorePathValidation.ensurePathSafeID(session.learnerID, field: "learnerID")
            writes.append(try fileIO.makeWrite(session, to: layout.sessionURL(session.sessionID)))
        }
    }

    private static func appendPracticeSetWrites(
        from practiceSets: [TutorPracticeSet],
        layout: TutorStoreLayout,
        fileIO: JSONFileTutorStoreIO,
        writes: inout [JSONFileTutorStoreStagedWrite]
    ) throws {
        for practiceSet in practiceSets {
            try TutorStorePathValidation.ensurePathSafeID(practiceSet.practiceSetID, field: "practiceSetID")
            try TutorStorePathValidation.ensurePathSafeID(practiceSet.sessionID, field: "sessionID")
            writes.append(try fileIO.makeWrite(practiceSet, to: layout.practiceSetURL(practiceSet.practiceSetID)))
        }
    }

    private static func appendPracticeEvaluationWrites(
        from evaluations: [TutorPracticeEvaluation],
        layout: TutorStoreLayout,
        fileIO: JSONFileTutorStoreIO,
        writes: inout [JSONFileTutorStoreStagedWrite]
    ) throws {
        for evaluation in evaluations {
            try TutorStorePathValidation.ensurePathSafeID(evaluation.sessionID, field: "sessionID")
            try TutorStorePathValidation.ensurePathSafeID(evaluation.practiceSetID, field: "practiceSetID")
            writes.append(
                try fileIO.makeWrite(
                    evaluation,
                    to: layout.practiceEvaluationURL(
                        sessionID: evaluation.sessionID,
                        practiceSetID: evaluation.practiceSetID
                    )
                )
            )
        }
    }

    private static func appendStudyPlanWrites(
        from studyPlans: [TutorStudyPlan],
        layout: TutorStoreLayout,
        fileIO: JSONFileTutorStoreIO,
        writes: inout [JSONFileTutorStoreStagedWrite]
    ) throws {
        for plan in studyPlans {
            try TutorStorePathValidation.ensurePathSafeID(plan.learnerID, field: "learnerID")
            try TutorStorePathValidation.ensureRFC3339(plan.generatedAt, field: "generatedAt")
            writes.append(
                try fileIO.makeWrite(
                    plan,
                    to: layout.studyPlanURL(
                        learnerID: plan.learnerID,
                        generatedAt: plan.generatedAt
                    )
                )
            )
        }
    }
}