import Foundation
import Testing
@testable import NativeAgentGoals
@testable import NativeAgentDomain

private func goalExecutionTempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-goal-execution-\(UUID().uuidString)", isDirectory: true)
}

private actor BlockingGoalRunner: GoalTurnRunner {
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<GoalRunResult, any Error>?

    func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard started == false else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finish() {
        resultContinuation?.resume(returning: GoalRunResult(
            sessionID: "blocking-session",
            status: .completed,
            output: """
            Goal completed.
            GOAL_EVIDENCE:
            - exclusive goal execution verified
            GOAL_STATUS: complete
            GOAL_REASON: done
            """
        ))
        resultContinuation = nil
    }
}

private actor CountingGoalRunner: GoalTurnRunner {
    private var count = 0

    func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
        count += 1
        return GoalRunResult(
            sessionID: "counting-\(count)",
            status: .completed,
            output: """
            Goal completed.
            GOAL_EVIDENCE:
            - counting runner completed
            GOAL_STATUS: complete
            GOAL_REASON: done
            """
        )
    }

    func callCount() -> Int { count }
}

private actor FailOnceGoalExecutionClaimStore: GoalExecutionClaimStore {
    private let base = InMemoryGoalExecutionClaimStore()
    private var failNextRelease = true

    func acquireGoalExecutionClaim(goalID: String) async throws -> GoalExecutionClaim {
        try await base.acquireGoalExecutionClaim(goalID: goalID)
    }

    func releaseGoalExecutionClaim(_ claim: GoalExecutionClaim) async throws {
        if failNextRelease {
            failNextRelease = false
            throw GoalError.storeFailure("injected release failure")
        }
        try await base.releaseGoalExecutionClaim(claim)
    }
}

@Test
func goalReducerOwnsTurnAndStatusTransitionAsOnePureReduction() throws {
    let initial = GoalSession(
        goalID: "reducer",
        objective: "verify pure transition",
        minScore: 0.2
    )
    let record = GoalTurnRecord(
        turn: 1,
        sessionID: "agent-1",
        status: .completed,
        output: "verified",
        evaluation: GoalEvaluation(
            satisfied: true,
            score: 1,
            reason: "evidence verified"
        )
    )

    let reduction = try GoalReducer.reduce(.recordTurn(record), state: initial)

    #expect(initial.status == .active)
    #expect(initial.turns.isEmpty)
    #expect(reduction.session.status == .complete)
    #expect(reduction.session.turns == [record])
    #expect(reduction.effects == [.persist(.turnRecorded)])
}

@Test
func goalReducerRejectsIllegalAndOutOfOrderTransitions() throws {
    let initial = GoalSession(goalID: "invalid", objective: "reject invalid transitions")
    let outOfOrder = GoalTurnRecord(
        turn: 2,
        sessionID: "agent-2",
        status: .completed,
        output: "invalid",
        evaluation: GoalEvaluation(satisfied: false)
    )

    #expect(throws: GoalError.self) {
        _ = try GoalReducer.reduce(.recordTurn(outOfOrder), state: initial)
    }
    #expect(throws: GoalError.self) {
        _ = try GoalReducer.reduce(.setStatus(.complete), state: initial)
    }
    #expect(throws: GoalError.self) {
        _ = try GoalReducer.reduce(.exhaustTurnBudget, state: initial)
    }
}

@Test
func fileGoalExecutionClaimIsSharedAcrossStoreInstancesForSameRoot() async throws {
    let root = goalExecutionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = FileGoalSessionStore(rootURL: root)
    let second = FileGoalSessionStore(rootURL: root)

    let claim = try await first.acquireGoalExecutionClaim(goalID: "shared")
    await #expect(throws: GoalError.self) {
        _ = try await second.acquireGoalExecutionClaim(goalID: "shared")
    }
    try await first.releaseGoalExecutionClaim(claim)

    let next = try await second.acquireGoalExecutionClaim(goalID: "shared")
    try await second.releaseGoalExecutionClaim(next)
}

@Test
func separateGoalLoopsCannotAdvanceSameFileBackedGoalConcurrently() async throws {
    let root = goalExecutionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blockingRunner = BlockingGoalRunner()
    let firstLoop = GoalLoop(
        store: FileGoalSessionStore(rootURL: root),
        runner: blockingRunner,
        evaluator: HeuristicGoalEvaluator()
    )
    let secondRunner = CountingGoalRunner()
    let secondLoop = GoalLoop(
        store: FileGoalSessionStore(rootURL: root),
        runner: secondRunner,
        evaluator: HeuristicGoalEvaluator()
    )
    let request = GoalRunRequest(
        goalID: "exclusive",
        objective: "prove exclusive execution",
        minScore: 0.2
    )

    let firstTask = Task { try await firstLoop.run(request) }
    await blockingRunner.waitUntilStarted()

    await #expect(throws: GoalError.self) {
        _ = try await secondLoop.run(request)
    }
    #expect(await secondRunner.callCount() == 0)

    await blockingRunner.finish()
    let report = try await firstTask.value
    #expect(report.status == .complete)
    #expect(report.session.turns.count == 1)
}

@Test
func fileGoalAtomicSaveRejectsStaleTurnAfterHostPause() async throws {
    let root = goalExecutionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    let initial = GoalSession(
        goalID: "cas-pause",
        objective: "preserve host pause",
        minScore: 0.2
    )
    try await store.save(initial)

    let record = GoalTurnRecord(
        turn: 1,
        sessionID: "agent-cas",
        status: .completed,
        output: "late completion",
        evaluation: GoalEvaluation(satisfied: true, score: 1, reason: "late")
    )
    let staleReduction = try GoalReducer.reduce(.recordTurn(record), state: initial)
    _ = try await store.pause(goalID: initial.goalID)

    let saved = try await store.save(staleReduction.session, replacing: initial)
    let persisted = try #require(try await store.load(goalID: initial.goalID))

    #expect(saved == false)
    #expect(persisted.status == .paused)
    #expect(persisted.turns.isEmpty)
}

@Test
func goalLoopRejectsDefinitionMismatchWithoutOverwritingPersistedGoal() async throws {
    let root = goalExecutionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    let original = GoalSession(
        goalID: "stable-definition",
        objective: "original objective",
        successCondition: "original evidence"
    )
    try await store.save(original)
    let loop = GoalLoop(store: store, runner: CountingGoalRunner())

    await #expect(throws: GoalError.self) {
        _ = try await loop.run(GoalRunRequest(
            goalID: original.goalID,
            objective: "different objective",
            successCondition: "different evidence",
            resumeExisting: true
        ))
    }

    #expect(try await store.load(goalID: original.goalID) == original)
}

@Test
func goalLoopRetainsAndRetriesFailedExecutionClaimRelease() async throws {
    let root = goalExecutionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    let claims = FailOnceGoalExecutionClaimStore()
    let runner = CountingGoalRunner()
    let loop = GoalLoop(
        store: store,
        runner: runner,
        evaluator: HeuristicGoalEvaluator(),
        executionClaimStore: claims
    )
    let request = GoalRunRequest(
        goalID: "release-retry",
        objective: "retry failed claim release",
        minScore: 0.2
    )

    await #expect(throws: GoalError.self) {
        _ = try await loop.run(request)
    }
    #expect(try await store.load(goalID: request.goalID)?.status == .complete)

    await #expect(throws: GoalError.self) {
        _ = try await loop.run(request)
    }
    #expect(try await loop.retryPendingExecutionClaimRelease(goalID: request.goalID))

    let report = try await loop.run(request)
    #expect(report.status == .complete)
    #expect(await runner.callCount() == 1)
}

@Test
func goalReducerRejectsUnboundedTurnBudgetsAndTurnPayloads() {
    let oversizedBudget = GoalSession(
        goalID: "oversized-budget",
        objective: "reject unbounded work",
        maxTurns: GoalResourceLimits.maximumTurns + 1
    )
    #expect(throws: GoalError.self) {
        try GoalReducer.validate(oversizedBudget)
    }

    let initial = GoalSession(
        goalID: "oversized-output",
        objective: "reject unbounded output"
    )
    let oversizedRecord = GoalTurnRecord(
        turn: 1,
        sessionID: "agent",
        status: .completed,
        output: String(
            repeating: "x",
            count: GoalResourceLimits.maximumTurnOutputUTF8Bytes + 1
        ),
        evaluation: GoalEvaluation(satisfied: false)
    )
    #expect(throws: GoalError.self) {
        _ = try GoalReducer.reduce(.recordTurn(oversizedRecord), state: initial)
    }
}

@Test
func fileGoalStoreRejectsOversizedPersistedValueBeforeDecoding() async throws {
    let root = goalExecutionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("oversized.goal.json")
    try Data(
        repeating: 0x20,
        count: GoalResourceLimits.maximumGoalFileBytes + 1
    ).write(to: url)

    let store = FileGoalSessionStore(rootURL: root)
    await #expect(throws: GoalError.self) {
        _ = try await store.load(goalID: "oversized")
    }
}

@Test
func fileGoalClaimKeepsIdentityAcrossFirstDirectoryCreationThroughAlias() async throws {
    let root = goalExecutionTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let first = FileGoalSessionStore(rootURL: alias.appendingPathComponent("new/nested/goals"))
    let second = FileGoalSessionStore(rootURL: real.appendingPathComponent("new/nested/goals"))
    let claim = try await first.acquireGoalExecutionClaim(goalID: "new-goal")
    #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("new/nested/goals").path))
    await #expect(throws: GoalError.self) { _ = try await second.acquireGoalExecutionClaim(goalID: "new-goal") }
    await #expect(throws: GoalError.self) { try await first.releaseGoalExecutionClaim(GoalExecutionClaim(goalID: "new-goal")) }
    try await first.releaseGoalExecutionClaim(claim)
    let next = try await second.acquireGoalExecutionClaim(goalID: "new-goal")
    try await second.releaseGoalExecutionClaim(next)
}

@Test
func fileGoalClaimRejectsFileAsRoot() async throws {
    let root = goalExecutionTempRoot()
    try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("file".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    await #expect(throws: GoalError.self) { _ = try await store.acquireGoalExecutionClaim(goalID: "goal") }
}
