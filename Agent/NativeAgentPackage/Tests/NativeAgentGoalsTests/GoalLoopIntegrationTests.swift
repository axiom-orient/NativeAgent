import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
@testable import NativeAgentGoals
import NativeAgentTestSupport

@Test
func goalLoopPersistsTurnsAndStopsOnCompletion() async throws {
    struct ScriptedGoalRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            if request.turn == 1 {
                return GoalRunResult(
                    sessionID: "native-agent-session-1",
                    status: .completed,
                    output: "Need one more check. GOAL_STATUS: continue"
                )
            }
            return GoalRunResult(
                sessionID: "native-agent-session-1",
                status: .completed,
                output: "Mobile approval evidence is reported.\nGOAL_EVIDENCE:\n- approval evidence checked\nGOAL_STATUS: complete\nGOAL_REASON: complete"
            )
        }
    }

    let root = tempRoot()
    let store = FileGoalSessionStore(rootURL: root)
    let loop = GoalLoop(
        store: store,
        runner: ScriptedGoalRunner(),
        evaluator: HeuristicGoalEvaluator()
    )

    let report = try await loop.run(
        GoalRunRequest(
            goalID: "approval evidence",
            objective: "report mobile approval evidence",
            successCondition: "approval evidence is reported",
            maxTurns: 3,
            minScore: 0.2
        )
    )

    #expect(report.status == .complete)
    #expect(report.session.turns.count == 2)
    #expect(report.agentSessionID == "native-agent-session-1")
    #expect(FileManager.default.fileExists(atPath: report.storePath))
}

@Test
func goalLoopPropagatesCancellationWithoutPersistingFailure() async throws {
    actor StartSignal {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?

        func markStarted() {
            started = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            guard started == false else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }
    struct CancellationRunner: GoalTurnRunner {
        let signal: StartSignal

        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            await signal.markStarted()
            try await Task.sleep(for: .seconds(30))
            return GoalRunResult(sessionID: "late", status: .completed, output: "late")
        }
    }

    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    let signal = StartSignal()
    let loop = GoalLoop(store: store, runner: CancellationRunner(signal: signal))
    let task = Task {
        try await loop.run(
            GoalRunRequest(goalID: "cancelled", objective: "stop when cancelled")
        )
    }

    await signal.wait()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    let persisted = try #require(try await store.load(goalID: "cancelled"))
    #expect(persisted.status == .active)
    #expect(persisted.turns.isEmpty)
}

@Test
func goalLoopPreservesPauseAppliedDuringRunningTurn() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    let runner = SuspendedGoalRunner()
    let loop = GoalLoop(store: store, runner: runner)
    let task = Task {
        try await loop.run(
            GoalRunRequest(goalID: "pause-in-flight", objective: "preserve host pause")
        )
    }

    await runner.waitUntilStarted()
    _ = try await store.pause(goalID: "pause-in-flight")
    await runner.finish(
        with: GoalRunResult(
            sessionID: "late-session",
            status: .completed,
            output: "late result"
        )
    )

    let report = try await task.value
    #expect(report.status == .paused)
    #expect(report.session.turns.isEmpty)
    #expect(try await store.load(goalID: "pause-in-flight")?.status == .paused)
}

@Test
func goalLoopPreservesPauseAppliedAfterFinalTurnSave() async throws {
    struct IncompleteRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: "incomplete-session",
                status: .completed,
                output: "More work remains. GOAL_STATUS: continue"
            )
        }
    }

    let store = HostPauseAfterTurnStore()
    let report = try await GoalLoop(store: store, runner: IncompleteRunner()).run(
        GoalRunRequest(goalID: "pause-after-save", objective: "preserve final host pause", maxTurns: 1)
    )

    #expect(report.status == .paused)
    #expect(report.session.turns.count == 1)
}

@Test
func goalLoopPersistsAutomaticResumeBeforeRunningNextTurn() async throws {
    struct CompletingRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: "resumed-session",
                status: .completed,
                output: "Resumed successfully.\nGOAL_EVIDENCE:\n- resumed turn completed\nGOAL_STATUS: complete\nGOAL_REASON: done"
            )
        }
    }

    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileGoalSessionStore(rootURL: root)
    try await store.save(
        GoalSession(goalID: "automatic-resume", objective: "resume work", status: .budgetLimited)
    )

    let report = try await GoalLoop(store: store, runner: CompletingRunner()).run(
        GoalRunRequest(goalID: "automatic-resume", objective: "resume work", minScore: 0.2)
    )

    #expect(report.status == .complete)
    #expect(report.session.turns.count == 1)
}

@Test
func goalLoopStopsWhenMobileSessionWaits() async throws {
    struct WaitingGoalRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: "waiting-session",
                status: .waiting,
                output: "Host approval is required. GOAL_STATUS: continue",
                waitState: SessionWaitState.signal(identifier: "host-signal")
            )
        }
    }

    let store = FileGoalSessionStore(rootURL: tempRoot())
    let loop = GoalLoop(store: store, runner: WaitingGoalRunner())
    let report = try await loop.run(
        GoalRunRequest(
            goalID: "wait",
            objective: "finish after host signal",
            maxTurns: 3,
            minScore: 0.1
        )
    )

    #expect(report.status == .waiting)
    #expect(report.session.turns.count == 1)
    #expect(report.session.turns[0].waitKind == .signal)
}

@Test
func sessionCoordinatorGoalRunnerUsesNativeAgentSessionCoordinator() async throws {
    let root = tempRoot()
    let runtimeStore = ApplicationSupportSessionStore(rootURL: root.appendingPathComponent("runtime", isDirectory: true))
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "Collected mobile goal evidence.\nGOAL_EVIDENCE:\n- mobile goal evidence checked\nGOAL_STATUS: complete\nGOAL_REASON: done")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: runtimeStore,
        toolPacks: []
    )
    let goalStore = FileGoalSessionStore(rootURL: root.appendingPathComponent("goals", isDirectory: true))
    let loop = GoalLoop(
        store: goalStore,
        runner: SessionCoordinatorGoalTurnRunner(coordinator: coordinator),
        evaluator: HeuristicGoalEvaluator()
    )

    let report = try await loop.run(
        GoalRunRequest(
            goalID: "coordinator",
            objective: "collect mobile goal evidence",
            successCondition: "mobile goal evidence checked",
            maxTurns: 1,
            minScore: 0.2
        )
    )

    #expect(report.status == .complete)
    #expect(report.agentSessionID != nil)
    #expect(await provider.callCount() == 1)
}
