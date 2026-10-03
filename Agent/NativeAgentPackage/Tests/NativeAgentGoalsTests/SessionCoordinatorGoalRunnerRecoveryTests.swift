import Foundation
import Testing
import NativeAgentDomain
import NativeAgentExecution
import NativeAgentTestSupport
@testable import NativeAgentGoals

private enum GoalRunnerRecoveryFixtureError: String, Error, LocalizedError, Sendable {
    case run = "run-load-failed"
    case recovery = "recovery-load-failed"

    var errorDescription: String? { rawValue }
}

private actor FailingGoalRunnerSessionStore:
    SessionRuntimeStore,
    EffectLedgerStore,
    SessionExecutionClaimStore
{
    private var loadCount = 0

    func prepare() async throws {}

    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? {
        SessionRuntimeAdmission(
            schemaVersion: SessionSnapshot.currentSchemaVersion,
            revision: 0,
            messageCount: 0,
            hydrationPayloadBytes: 0,
            artifactCount: 0
        )
    }

    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? {
        loadCount += 1
        if loadCount == 1 {
            throw GoalRunnerRecoveryFixtureError.run
        }
        throw GoalRunnerRecoveryFixtureError.recovery
    }

    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {}
    func commit(_ transaction: SessionPersistenceTransaction) async throws {}

    func persistArtifact(
        sessionID: String,
        artifact: ArtifactWriteRequest,
        createdAt: Date
    ) async throws -> ArtifactRecord {
        throw GoalRunnerRecoveryFixtureError.run
    }

    func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws {
        throw GoalRunnerRecoveryFixtureError.run
    }

    func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        throw GoalRunnerRecoveryFixtureError.run
    }

    func sandboxRootURL() async throws -> URL {
        FileManager.default.temporaryDirectory
    }

    func sessionDirectoryURL(sessionID: String) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    func loadEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) async throws -> EffectRecord? { nil }
    func saveEffect(_ effect: EffectRecord) async throws {}
    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        SessionExecutionClaim(sessionID: sessionID, claimID: "goal-runner-test")
    }
    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {}
}

@Test
func goalRunnerPreservesRunAndRecoveryFailures() async throws {
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: []),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: FailingGoalRunnerSessionStore(),
        toolPacks: []
    )
    let runner = SessionCoordinatorGoalTurnRunner(coordinator: coordinator)
    let request = GoalTurnRequest(
        goalID: "recovery",
        turn: 2,
        input: "continue",
        objective: "preserve both failures",
        agentSessionID: "session-recovery"
    )

    do {
        _ = try await runner.run(request)
        Issue.record("Expected the goal runner to preserve both failures")
    } catch let error as SessionCoordinatorGoalRecoveryError {
        #expect(error.sessionID == "session-recovery")
        #expect(error.runFailure.contains("run-load-failed"))
        #expect(error.recoveryFailure.contains("recovery-load-failed"))
        #expect(error.localizedDescription.contains("loading its durable recovery snapshot also failed"))
    }
}
