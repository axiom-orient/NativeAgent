import Foundation
import Testing
import ASKTutor
@testable import ASKTutor

struct TutorStoreTests {
    @Test
    func storeRoundTripsLearnerAndSession() async throws {
        let root = makeStoreRoot(name: "roundtrip-learner-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let learner = LearnerProfile(learnerID: "learner-1", displayName: "AX", updatedAt: "2026-04-10T00:00:00Z")
        try await store.saveLearner(learner)
        #expect(try await store.loadLearner(learnerID: learner.learnerID) == learner)

        let session = TutorSession(
            sessionID: "session-1",
            learnerID: learner.learnerID,
            title: "Session",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        try await store.saveSession(session)
        #expect(try await store.loadSession(sessionID: session.sessionID) == session)
    }

    @Test
    func storeRoundTripsPracticeSetAndEvaluation() async throws {
        let root = makeStoreRoot(name: "roundtrip-practice-evaluation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let learner = LearnerProfile(learnerID: "learner-1", displayName: "AX", updatedAt: "2026-04-10T00:00:00Z")
        try await store.saveLearner(learner)
        let session = TutorSession(
            sessionID: "session-1",
            learnerID: learner.learnerID,
            title: "Session",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        try await store.saveSession(session)

        let practice = TutorPracticeSet(
            practiceSetID: "practice-1",
            sessionID: session.sessionID,
            topic: "Topic",
            createdAt: "2026-04-10T00:00:00Z",
            recap: ["recap"],
            questions: [],
            evidence: []
        )
        try await store.savePracticeSet(practice)
        #expect(try await store.loadPracticeSet(practiceSetID: practice.practiceSetID) == practice)

        let evaluation = TutorPracticeEvaluation(
            sessionID: session.sessionID,
            practiceSetID: practice.practiceSetID,
            createdAt: "2026-04-10T00:01:00Z",
            summary: "good",
            overallScore: 0.9,
            itemResults: [],
            updatedConceptStates: [],
            recommendedFocusTopics: ["Topic"]
        )
        try await store.savePracticeEvaluation(evaluation)
        #expect(
            try await store.loadPracticeEvaluation(
                sessionID: session.sessionID,
                practiceSetID: practice.practiceSetID
            ) == evaluation
        )
        #expect(try await store.listPracticeEvaluations(learnerID: learner.learnerID, limit: 10) == [evaluation])
    }

    @Test
    func storeRoundTripsStudyPlan() async throws {
        let root = makeStoreRoot(name: "roundtrip-study-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let learner = LearnerProfile(learnerID: "learner-1", displayName: "AX", updatedAt: "2026-04-10T00:00:00Z")
        try await store.saveLearner(learner)

        let plan = TutorStudyPlan(
            learnerID: learner.learnerID,
            generatedAt: "2026-04-10T00:02:00Z",
            headline: "Plan",
            focusTopics: ["Topic"],
            actions: ["Review"],
            rationale: ["Due"],
            dueConceptIDs: ["c1"],
            knowledgeMaintenance: []
        )
        try await store.saveStudyPlan(plan)
        #expect(try await store.loadStudyPlan(learnerID: learner.learnerID, generatedAt: plan.generatedAt) == plan)
        #expect(try await store.listStudyPlans(learnerID: learner.learnerID, limit: 10) == [plan])
    }

    @Test
    func applicationSupportRootCreatesRequestedTutorDirectory() throws {
        let base = makeStoreRoot(name: "app-support-root")
        defer { try? FileManager.default.removeItem(at: base) }

        let fileManager = FileManager.default
        let resolved = try ASKTutorStoreRootPolicy.resolvedApplicationSupportRoot(
            fileManager: fileManager,
            baseURL: base,
            subdirectory: "ASKTutor"
        )

        #expect(resolved.lastPathComponent == "ASKTutor")
        #expect(fileManager.fileExists(atPath: resolved.path(percentEncoded: false)))
    }

    @Test
    func storeBatchRoundTripsUnderApplicationSupportStylePath() async throws {
        let base = makeStoreRoot(name: "app-support-batch")
        let root = base.appendingPathComponent("Application Support/ASKTutor/Store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = JSONFileTutorStore(rootURL: root)
        let learner = LearnerProfile(
            learnerID: "learner-1",
            displayName: "AX",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let session = TutorSession(
            sessionID: "session-1",
            learnerID: learner.learnerID,
            title: "Session",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )

        try await store.saveBatch(
            TutorStoreBatch(
                learners: [learner],
                sessions: [session]
            )
        )

        #expect(try await store.loadLearner(learnerID: learner.learnerID) == learner)
        #expect(try await store.loadSession(sessionID: session.sessionID) == session)
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test
    func sessionListingSortsNewestFirst() async throws {
        let root = makeStoreRoot(name: "list")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        try await store.saveSession(TutorSession(sessionID: "s1", learnerID: "learner", title: "Old", scope: .global, createdAt: "2026-04-10T00:00:00Z", updatedAt: "2026-04-10T00:00:00Z"))
        try await store.saveSession(TutorSession(sessionID: "s2", learnerID: "learner", title: "New", scope: .global, createdAt: "2026-04-11T00:00:00Z", updatedAt: "2026-04-11T00:00:00Z"))

        let sessions = try await store.listSessions(learnerID: "learner")
        #expect(sessions.map(\.sessionID) == ["s2", "s1"])
    }

    @Test
    func sessionListingSortsByParsedTimestampBeforeLexicalFallback() async throws {
        let root = makeStoreRoot(name: "parsed-sort")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        try await store.saveSession(TutorSession(sessionID: "s1", learnerID: "learner", title: "No fractional", scope: .global, createdAt: "2026-04-10T00:00:00Z", updatedAt: "2026-04-10T00:00:00Z"))
        try await store.saveSession(TutorSession(sessionID: "s2", learnerID: "learner", title: "Fractional", scope: .global, createdAt: "2026-04-10T00:00:00.100Z", updatedAt: "2026-04-10T00:00:00.100Z"))

        let sessions = try await store.listSessions(learnerID: "learner")
        #expect(sessions.map(\.sessionID) == ["s2", "s1"])
    }

    @Test
    func importArchiveKeepExistingLeavesStoredValuesUntouched() async throws {
        let root = makeStoreRoot(name: "import-keep-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let archive = makeArchive(sessionTitle: "Incoming", planHeadline: "Incoming plan")
        try await store.saveLearner(LearnerProfile(
            learnerID: archive.learner.learnerID,
            displayName: "Existing",
            updatedAt: "2026-04-12T00:00:00Z"
        ))
        try await store.saveSession(TutorSession(
            sessionID: archive.sessions[0].sessionID,
            learnerID: archive.learner.learnerID,
            title: "Existing session",
            scope: .global,
            createdAt: archive.sessions[0].createdAt,
            updatedAt: "2026-04-12T00:00:00Z"
        ))
        try await store.savePracticeSet(TutorPracticeSet(
            practiceSetID: archive.practiceSets[0].practiceSetID,
            sessionID: archive.sessions[0].sessionID,
            topic: "Existing topic",
            createdAt: archive.practiceSets[0].createdAt,
            recap: ["existing"],
            questions: [],
            evidence: []
        ))
        try await store.savePracticeEvaluation(TutorPracticeEvaluation(
            sessionID: archive.practiceEvaluations[0].sessionID,
            practiceSetID: archive.practiceEvaluations[0].practiceSetID,
            createdAt: archive.practiceEvaluations[0].createdAt,
            summary: "existing",
            overallScore: 0.2,
            itemResults: [],
            updatedConceptStates: [],
            recommendedFocusTopics: ["existing"]
        ))
        try await store.saveStudyPlan(TutorStudyPlan(
            learnerID: archive.studyPlans[0].learnerID,
            generatedAt: archive.studyPlans[0].generatedAt,
            headline: "Existing plan",
            focusTopics: ["existing"],
            actions: ["existing"],
            rationale: ["existing"],
            dueConceptIDs: [],
            knowledgeMaintenance: []
        ))

        let summary = try await store.importArchive(archive, mergePolicy: .keepExisting)
        #expect(summary == TutorDataArchiveImportSummary(
            learnerSaved: false,
            sessionsSaved: 0,
            practiceSetsSaved: 0,
            evaluationsSaved: 0,
            studyPlansSaved: 0
        ))
        #expect(try await store.loadLearner(learnerID: archive.learner.learnerID)?.displayName == "Existing")
        #expect(try await store.loadSession(sessionID: archive.sessions[0].sessionID)?.title == "Existing session")
        #expect(try await store.loadPracticeSet(practiceSetID: archive.practiceSets[0].practiceSetID)?.topic == "Existing topic")
        #expect(try await store.loadPracticeEvaluation(
            sessionID: archive.practiceEvaluations[0].sessionID,
            practiceSetID: archive.practiceEvaluations[0].practiceSetID
        )?.summary == "existing")
        #expect(try await store.loadStudyPlan(
            learnerID: archive.studyPlans[0].learnerID,
            generatedAt: archive.studyPlans[0].generatedAt
        )?.headline == "Existing plan")
    }

    @Test
    func importArchiveReplaceExistingOverwritesStoredValues() async throws {
        let root = makeStoreRoot(name: "import-replace-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let archive = makeArchive(sessionTitle: "Incoming", planHeadline: "Incoming plan")
        try await store.saveLearner(LearnerProfile(
            learnerID: archive.learner.learnerID,
            displayName: "Existing",
            updatedAt: "2026-04-12T00:00:00Z"
        ))
        try await store.saveSession(TutorSession(
            sessionID: archive.sessions[0].sessionID,
            learnerID: archive.learner.learnerID,
            title: "Existing session",
            scope: .global,
            createdAt: archive.sessions[0].createdAt,
            updatedAt: "2026-04-12T00:00:00Z"
        ))
        try await store.savePracticeSet(TutorPracticeSet(
            practiceSetID: archive.practiceSets[0].practiceSetID,
            sessionID: archive.sessions[0].sessionID,
            topic: "Existing topic",
            createdAt: archive.practiceSets[0].createdAt,
            recap: ["existing"],
            questions: [],
            evidence: []
        ))
        try await store.savePracticeEvaluation(TutorPracticeEvaluation(
            sessionID: archive.practiceEvaluations[0].sessionID,
            practiceSetID: archive.practiceEvaluations[0].practiceSetID,
            createdAt: archive.practiceEvaluations[0].createdAt,
            summary: "existing",
            overallScore: 0.2,
            itemResults: [],
            updatedConceptStates: [],
            recommendedFocusTopics: ["existing"]
        ))
        try await store.saveStudyPlan(TutorStudyPlan(
            learnerID: archive.studyPlans[0].learnerID,
            generatedAt: archive.studyPlans[0].generatedAt,
            headline: "Existing plan",
            focusTopics: ["existing"],
            actions: ["existing"],
            rationale: ["existing"],
            dueConceptIDs: [],
            knowledgeMaintenance: []
        ))

        let summary = try await store.importArchive(archive, mergePolicy: .replaceExisting)
        #expect(summary == TutorDataArchiveImportSummary(
            learnerSaved: true,
            sessionsSaved: 1,
            practiceSetsSaved: 1,
            evaluationsSaved: 1,
            studyPlansSaved: 1
        ))
        #expect(try await store.loadLearner(learnerID: archive.learner.learnerID) == archive.learner)
        #expect(try await store.loadSession(sessionID: archive.sessions[0].sessionID) == archive.sessions[0])
        #expect(try await store.loadPracticeSet(practiceSetID: archive.practiceSets[0].practiceSetID) == archive.practiceSets[0])
        #expect(try await store.loadPracticeEvaluation(
            sessionID: archive.practiceEvaluations[0].sessionID,
            practiceSetID: archive.practiceEvaluations[0].practiceSetID
        ) == archive.practiceEvaluations[0])
        #expect(try await store.loadStudyPlan(
            learnerID: archive.studyPlans[0].learnerID,
            generatedAt: archive.studyPlans[0].generatedAt
        ) == archive.studyPlans[0])
    }


    @Test
    func learnerListingSortsNewestFirst() async throws {
        let root = makeStoreRoot(name: "learner-list")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        try await store.saveLearner(LearnerProfile(learnerID: "learner-old", displayName: "Old", updatedAt: "2026-04-10T00:00:00Z"))
        try await store.saveLearner(LearnerProfile(learnerID: "learner-new", displayName: "New", updatedAt: "2026-04-11T00:00:00Z"))

        let learners = try await store.listLearners()
        #expect(learners.map(\.learnerID) == ["learner-new", "learner-old"])
    }

    @Test
    func importArchiveFailOnConflictThrowsStorageError() async throws {
        let root = makeStoreRoot(name: "import-fail-on-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let archive = makeArchive(sessionTitle: "Incoming", planHeadline: "Incoming plan")
        try await store.saveLearner(LearnerProfile(
            learnerID: archive.learner.learnerID,
            displayName: "Existing",
            updatedAt: "2026-04-12T00:00:00Z"
        ))

        do {
            _ = try await store.importArchive(archive, mergePolicy: .failOnConflict)
            Issue.record("Expected archive conflict")
        } catch let error as ASKTutorError {
            guard case .storage(let message) = error else {
                Issue.record("Unexpected ASKTutorError: \(error)")
                return
            }
            #expect(message == "archive conflict for `\(archive.learner.learnerID)`")
        }
    }

    @Test
    func importArchivePreflightsAllConflictsBeforeWriting() async throws {
        let root = makeStoreRoot(name: "import-preflight-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        let archive = makeArchive(sessionTitle: "Incoming", planHeadline: "Incoming plan")
        let existingSession = TutorSession(
            sessionID: archive.sessions[0].sessionID,
            learnerID: archive.learner.learnerID,
            title: "Existing session",
            scope: .global,
            createdAt: archive.sessions[0].createdAt,
            updatedAt: "2026-04-12T00:00:00Z"
        )
        try await store.saveSession(existingSession)

        await #expect(throws: ASKTutorError.self) {
            _ = try await store.importArchive(archive, mergePolicy: .failOnConflict)
        }

        #expect(try await store.loadLearner(learnerID: archive.learner.learnerID) == nil)
        #expect(try await store.loadSession(sessionID: existingSession.sessionID) == existingSession)
        #expect(try await store.loadPracticeSet(practiceSetID: archive.practiceSets[0].practiceSetID) == nil)
        #expect(try await store.loadPracticeEvaluation(
            sessionID: archive.practiceEvaluations[0].sessionID,
            practiceSetID: archive.practiceEvaluations[0].practiceSetID
        ) == nil)
        #expect(try await store.loadStudyPlan(
            learnerID: archive.studyPlans[0].learnerID,
            generatedAt: archive.studyPlans[0].generatedAt
        ) == nil)
    }

    @Test
    func batchPreflightFailureWritesNoRecords() async throws {
        let root = makeStoreRoot(name: "batch-preflight-no-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        let valid = LearnerProfile(
            learnerID: "valid-learner",
            displayName: "Valid",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let invalid = LearnerProfile(
            learnerID: "invalid/id",
            displayName: "Invalid",
            updatedAt: "2026-04-10T00:00:00Z"
        )

        await #expect(throws: ASKTutorError.self) {
            try await store.saveBatch(TutorStoreBatch(learners: [valid, invalid]))
        }

        #expect(try await store.loadLearner(learnerID: valid.learnerID) == nil)
    }

    @Test
    func storeRejectsUnsafePathBackedIdentifiers() async throws {
        let root = makeStoreRoot(name: "reject-unsafe-identifiers")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        await #expect(throws: ASKTutorError.self) {
            try await store.saveLearner(
                LearnerProfile(
                    learnerID: "bad/id",
                    displayName: "Bad",
                    updatedAt: "2026-04-10T00:00:00Z"
                )
            )
        }

        await #expect(throws: ASKTutorError.self) {
            _ = try await store.loadSession(sessionID: "bad/id")
        }

        await #expect(throws: ASKTutorError.self) {
            try await store.savePracticeSet(
                TutorPracticeSet(
                    practiceSetID: "bad/id",
                    sessionID: "session-1",
                    topic: "Topic",
                    createdAt: "2026-04-10T00:00:00Z",
                    recap: ["recap"],
                    questions: [],
                    evidence: []
                )
            )
        }

        await #expect(throws: ASKTutorError.self) {
            _ = try await store.loadStudyPlan(
                learnerID: "learner-1",
                generatedAt: "../bad"
            )
        }
    }

    @Test
    func importArchiveRejectsUnsafeIdentifiers() async throws {
        let root = makeStoreRoot(name: "import-reject-unsafe")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        try await store.ensureRoot()

        var archive = makeArchive(sessionTitle: "Incoming", planHeadline: "Incoming plan")
        archive.learner.learnerID = "bad/id"

        await #expect(throws: ASKTutorError.self) {
            _ = try await store.importArchive(archive, mergePolicy: .replaceExisting)
        }
    }

    @Test
    func batchSaveRetainsRecoveryManifestWhenRollbackCannotFinish() async throws {
        let root = makeStoreRoot(name: "batch-rollback-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let stashedBackup = root.appendingPathComponent("stashed-backup.json", isDirectory: false)

        let store = JSONFileTutorStore(
            rootURL: root,
            hooks: JSONFileTutorStoreHooks(
                afterCommit: { target, index in
                    guard index == 0 else { return }
                    let directory = target.deletingLastPathComponent()
                    let backupSuffix = "-\(target.lastPathComponent).bak"
                    let backup = try FileManager.default
                        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .first { url in
                            url.lastPathComponent.hasPrefix(".txn-")
                                && url.lastPathComponent.hasSuffix(backupSuffix)
                        }
                    guard let backup else {
                        throw ASKTutorError.storage("test backup was not created")
                    }
                    try FileManager.default.moveItem(at: backup, to: stashedBackup)
                    throw ASKTutorError.storage("injected batch failure")
                }
            )
        )
        try await store.ensureRoot()

        let originalSession = TutorSession(
            sessionID: "session-rollback-retry",
            learnerID: "learner-rollback-retry",
            title: "Original",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        try await store.saveSession(originalSession)

        let updatedSession = TutorSession(
            sessionID: originalSession.sessionID,
            learnerID: originalSession.learnerID,
            title: "Updated",
            scope: .global,
            createdAt: originalSession.createdAt,
            updatedAt: "2026-04-11T00:00:00Z"
        )

        do {
            try await store.saveBatch(TutorStoreBatch(sessions: [updatedSession]))
            Issue.record("Expected rollback failure")
        } catch let ASKTutorError.storage(message) {
            #expect(message.contains("batch commit failed"))
            #expect(message.contains("recovery pending"))
            #expect(message.contains("rollback"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let transactionRoot = root.appendingPathComponent(".transactions", isDirectory: true)
        let transactions = try FileManager.default.contentsOfDirectory(
            at: transactionRoot,
            includingPropertiesForKeys: nil
        )
        #expect(transactions.count == 1)
        guard let transactionDirectory = transactions.first else {
            Issue.record("Expected retained recovery transaction")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: transactionDirectory.appendingPathComponent("manifest.json").path
        ))

        let transactionID = String(transactionDirectory.lastPathComponent.dropFirst("v1-".count))
        let backup = root.appendingPathComponent(
            "sessions/.txn-\(transactionID)-0-\(originalSession.sessionID).json.bak",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: stashedBackup, to: backup)

        let reopened = JSONFileTutorStore(rootURL: root)
        #expect(try await reopened.loadSession(sessionID: originalSession.sessionID) == originalSession)
        #expect(try FileManager.default.contentsOfDirectory(
            at: transactionRoot,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test
    func batchSaveRollsBackIfCommitFailsMidFlight() async throws {
        let root = makeStoreRoot(name: "batch-rollback")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = JSONFileTutorStore(
            rootURL: root,
            hooks: JSONFileTutorStoreHooks(
                afterCommit: { _, index in
                    if index == 0 {
                        throw ASKTutorError.storage("injected batch failure")
                    }
                }
            )
        )
        try await store.ensureRoot()

        let originalSession = TutorSession(
            sessionID: "session-rollback",
            learnerID: "learner-rollback",
            title: "Original",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        try await store.saveSession(originalSession)

        let updatedSession = TutorSession(
            sessionID: "session-rollback",
            learnerID: "learner-rollback",
            title: "Updated",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-11T00:00:00Z"
        )
        let practiceSet = TutorPracticeSet(
            practiceSetID: "practice-rollback",
            sessionID: originalSession.sessionID,
            topic: "Topic",
            createdAt: "2026-04-11T00:00:00Z",
            recap: ["recap"],
            questions: [],
            evidence: []
        )

        await #expect(throws: ASKTutorError.self) {
            try await store.saveBatch(
                TutorStoreBatch(
                    sessions: [updatedSession],
                    practiceSets: [practiceSet]
                )
            )
        }

        #expect(try await store.loadSession(sessionID: originalSession.sessionID) == originalSession)
        #expect(try await store.loadPracticeSet(practiceSetID: practiceSet.practiceSetID) == nil)
    }


    @Test
    func archiveCanBeWrittenOutsideStoreRoot() async throws {
        let root = makeStoreRoot(name: "archive-store-root")
        let exportRoot = makeStoreRoot(name: "archive-export-root")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let store = JSONFileTutorStore(rootURL: root)
        let archive = makeArchive(sessionTitle: "Exported", planHeadline: "Exported plan")
        let archiveURL = exportRoot
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("tutor-archive.json", isDirectory: false)

        try await store.writeArchive(archive, to: archiveURL)
        let loaded = try await store.readArchive(from: archiveURL)

        #expect(loaded == archive)
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    @Test
    func reopenRemovesVersionedPreManifestStagingDirectory() async throws {
        let root = makeStoreRoot(name: "recover-pre-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = JSONFileTutorStore(rootURL: root)
        try await bootstrap.ensureRoot()

        let transactionDirectory = root
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent("v1-interrupted-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try Data("staged".utf8).write(
            to: transactionDirectory.appendingPathComponent("write-0.json", isDirectory: false)
        )

        let reopened = JSONFileTutorStore(rootURL: root)
        try await reopened.ensureRoot()

        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test
    func reopenRejectsUnversionedTransactionWithoutManifest() async throws {
        let root = makeStoreRoot(name: "recover-unknown-transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = JSONFileTutorStore(rootURL: root)
        try await bootstrap.ensureRoot()

        let transactionDirectory = root
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent("unknown-transaction", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)

        let reopened = JSONFileTutorStore(rootURL: root)
        await #expect(throws: ASKTutorError.self) {
            try await reopened.ensureRoot()
        }
        #expect(FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test
    func reopenRollsBackInterruptedReplacementTransaction() async throws {
        let root = makeStoreRoot(name: "recover-replacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        let original = TutorSession(
            sessionID: "session-recover",
            learnerID: "learner-recover",
            title: "Original",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let replacement = TutorSession(
            sessionID: original.sessionID,
            learnerID: original.learnerID,
            title: "Replacement",
            scope: .global,
            createdAt: original.createdAt,
            updatedAt: "2026-04-11T00:00:00Z"
        )
        try await store.saveSession(original)

        let transactionID = "interrupted-replacement"
        let transactionDirectory = root
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(transactionID, isDirectory: true)
        let target = root.appendingPathComponent("sessions/\(original.sessionID).json", isDirectory: false)
        let backup = root.appendingPathComponent(
            "sessions/.txn-\(transactionID)-0-\(target.lastPathComponent).bak",
            isDirectory: false
        )
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: target, to: backup)
        try JSONEncoder().encode(replacement).write(to: target, options: .atomic)
        try writeRecoveryManifest(
            transactionID: transactionID,
            phase: "committing",
            targetRelativePath: "sessions/\(original.sessionID).json",
            stagedFilename: "write-0.json",
            backupRelativePath: "sessions/\(backup.lastPathComponent)",
            hadExistingFile: true,
            transactionDirectory: transactionDirectory
        )

        let reopened = JSONFileTutorStore(rootURL: root)
        #expect(try await reopened.loadSession(sessionID: original.sessionID) == original)
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test
    func reopenAcceptsAlreadyRolledBackReplacementTransaction() async throws {
        let root = makeStoreRoot(name: "recover-already-rolled-back")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        let original = TutorSession(
            sessionID: "session-already-rolled-back",
            learnerID: "learner-already-rolled-back",
            title: "Original",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        try await store.saveSession(original)

        // This is the on-disk state left when every replacement was rolled
        // back after finalization failed, but the transaction directory itself
        // could not be removed. The backup and staged file have both been
        // consumed; the original target is already restored.
        let transactionID = "already-rolled-back-replacement"
        let transactionDirectory = root
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(transactionID, isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try writeRecoveryManifest(
            transactionID: transactionID,
            phase: "committing",
            targetRelativePath: "sessions/\(original.sessionID).json",
            stagedFilename: "write-0.json",
            backupRelativePath: "sessions/.txn-\(transactionID)-0-\(original.sessionID).json.bak",
            hadExistingFile: true,
            transactionDirectory: transactionDirectory
        )

        let reopened = JSONFileTutorStore(rootURL: root)
        #expect(try await reopened.loadSession(sessionID: original.sessionID) == original)
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test
    func reopenRemovesInterruptedNewTargetTransaction() async throws {
        let root = makeStoreRoot(name: "recover-new-target")
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = JSONFileTutorStore(rootURL: root)
        try await bootstrap.ensureRoot()

        let inserted = TutorSession(
            sessionID: "session-new-target",
            learnerID: "learner-new-target",
            title: "Inserted",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let transactionID = "interrupted-new-target"
        let transactionDirectory = root
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(transactionID, isDirectory: true)
        let target = root.appendingPathComponent("sessions/\(inserted.sessionID).json", isDirectory: false)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(inserted).write(to: target, options: .atomic)
        try writeRecoveryManifest(
            transactionID: transactionID,
            phase: "committing",
            targetRelativePath: "sessions/\(inserted.sessionID).json",
            stagedFilename: "write-0.json",
            backupRelativePath: nil,
            hadExistingFile: false,
            transactionDirectory: transactionDirectory
        )

        let reopened = JSONFileTutorStore(rootURL: root)
        #expect(try await reopened.loadSession(sessionID: inserted.sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func reopenKeepsCommittedTargetAndCleansTransactionArtifacts() async throws {
        let root = makeStoreRoot(name: "recover-committed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileTutorStore(rootURL: root)
        let original = TutorSession(
            sessionID: "session-committed",
            learnerID: "learner-committed",
            title: "Original",
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let committed = TutorSession(
            sessionID: original.sessionID,
            learnerID: original.learnerID,
            title: "Committed",
            scope: .global,
            createdAt: original.createdAt,
            updatedAt: "2026-04-11T00:00:00Z"
        )
        try await store.saveSession(original)

        let transactionID = "committed-cleanup"
        let transactionDirectory = root
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(transactionID, isDirectory: true)
        let target = root.appendingPathComponent("sessions/\(original.sessionID).json", isDirectory: false)
        let backup = root.appendingPathComponent(
            "sessions/.txn-\(transactionID)-0-\(target.lastPathComponent).bak",
            isDirectory: false
        )
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: target, to: backup)
        try JSONEncoder().encode(committed).write(to: target, options: .atomic)
        try writeRecoveryManifest(
            transactionID: transactionID,
            phase: "committed",
            targetRelativePath: "sessions/\(original.sessionID).json",
            stagedFilename: "write-0.json",
            backupRelativePath: "sessions/\(backup.lastPathComponent)",
            hadExistingFile: true,
            transactionDirectory: transactionDirectory
        )

        let reopened = JSONFileTutorStore(rootURL: root)
        #expect(try await reopened.loadSession(sessionID: original.sessionID) == committed)
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    private func writeRecoveryManifest(
        transactionID: String,
        phase: String,
        targetRelativePath: String,
        stagedFilename: String,
        backupRelativePath: String?,
        hadExistingFile: Bool,
        transactionDirectory: URL
    ) throws {
        var plan: [String: Any] = [
            "targetRelativePath": targetRelativePath,
            "stagedFilename": stagedFilename,
            "hadExistingFile": hadExistingFile,
        ]
        if let backupRelativePath {
            plan["backupRelativePath"] = backupRelativePath
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "transactionID": transactionID,
            "phase": phase,
            "plans": [plan],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(
            to: transactionDirectory.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic
        )
    }

    private func makeArchive(sessionTitle: String, planHeadline: String) -> TutorDataArchive {
        let learner = LearnerProfile(
            learnerID: "learner-import",
            displayName: "Incoming learner",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let session = TutorSession(
            sessionID: "session-import",
            learnerID: learner.learnerID,
            title: sessionTitle,
            scope: .global,
            createdAt: "2026-04-10T00:00:00Z",
            updatedAt: "2026-04-10T00:00:00Z"
        )
        let practiceSet = TutorPracticeSet(
            practiceSetID: "practice-import",
            sessionID: session.sessionID,
            topic: "Incoming topic",
            createdAt: "2026-04-10T00:10:00Z",
            recap: ["incoming"],
            questions: [],
            evidence: []
        )
        let evaluation = TutorPracticeEvaluation(
            sessionID: session.sessionID,
            practiceSetID: practiceSet.practiceSetID,
            createdAt: "2026-04-10T00:11:00Z",
            summary: "incoming",
            overallScore: 0.9,
            itemResults: [],
            updatedConceptStates: [],
            recommendedFocusTopics: ["incoming"]
        )
        let plan = TutorStudyPlan(
            learnerID: learner.learnerID,
            generatedAt: "2026-04-10T00:12:00Z",
            headline: planHeadline,
            focusTopics: ["incoming"],
            actions: ["incoming"],
            rationale: ["incoming"],
            dueConceptIDs: ["c1"],
            knowledgeMaintenance: []
        )
        return TutorDataArchive(
            exportedAt: "2026-04-10T00:20:00Z",
            learner: learner,
            sessions: [session],
            practiceSets: [practiceSet],
            practiceEvaluations: [evaluation],
            studyPlans: [plan]
        )
    }
}
