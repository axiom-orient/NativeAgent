import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
@testable import NativeAgentGoals
import NativeAgentTestSupport

@Test
func goalStoreResumeHelperMovesWaitingGoalBackToActive() async throws {
    let store = FileGoalSessionStore(rootURL: tempRoot())
    let session = GoalSession(
        goalID: "resume",
        objective: "resume after host signal",
        status: .waiting,
        turns: [
            GoalTurnRecord(
                turn: 1,
                sessionID: "session-resume",
                status: .waiting,
                output: "Need host signal. GOAL_STATUS: continue",
                evaluation: GoalEvaluation(
                    satisfied: false,
                    blocked: true,
                    score: 0.2,
                    reason: "waiting for host signal",
                    nextInstruction: "resume after signal"
                ),
                waitKind: .signal
            )
        ]
    )
    try await store.save(session)

    let resumed = try await store.resume(goalID: "resume")

    #expect(resumed.status == .active)
    #expect(resumed.turns.count == 1)
    #expect(resumed.turns[0].waitKind == .signal)
}

@Test
func goalLoopPersistsSignalHostActionMetadata() async throws {
    struct WaitingGoalRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: "host-action-session",
                status: .waiting,
                output: "Need user confirmation. GOAL_STATUS: continue",
                waitState: .signal(
                    identifier: "confirm-sync",
                    details: ["prompt": .string("Confirm sync")]
                )
            )
        }
    }

    let store = FileGoalSessionStore(rootURL: tempRoot())
    let loop = GoalLoop(store: store, runner: WaitingGoalRunner())
    let report = try await loop.run(
        GoalRunRequest(
            goalID: "host-action",
            objective: "sync after host confirmation",
            maxTurns: 2,
            minScore: 0.1
        )
    )

    let action = try #require(report.pendingHostAction)
    #expect(action.kind == .provideSignal)
    #expect(action.waitKind == .signal)
    #expect(action.waitIdentifier == "confirm-sync")
    #expect(action.recommendedCoordinatorMethod.contains("resumeSignalWait"))
    #expect(action.recommendedGoalStoreMethod == "resume(goalID:)")
}

@Test
func goalContinuationPlannerClassifiesRelaunchStates() async throws {
    let planner = GoalContinuationPlanner(
        policy: GoalContinuationPolicy(
            resumeActiveGoals: true,
            resumeInterruptedFailedGoals: true,
            resumeBudgetLimitedGoals: false,
            resumeBlockedGoals: false
        )
    )
    let waitingAction = SessionWaitState.signal(identifier: "host-signal")
        .nativeAgentGoalHostAction(goalID: "waiting", sessionID: "session-waiting")
    let active = GoalSession(goalID: "active", objective: "continue work", status: .active)
    let waiting = GoalSession(
        goalID: "waiting",
        objective: "wait for signal",
        status: .waiting,
        turns: [
            GoalTurnRecord(
                turn: 1,
                sessionID: "session-waiting",
                status: .waiting,
                output: "waiting",
                evaluation: GoalEvaluation(satisfied: false, blocked: true, reason: "waiting"),
                waitKind: .signal,
                hostAction: waitingAction
            )
        ]
    )
    let interrupted = GoalSession(
        goalID: "interrupted",
        objective: "retry after relaunch",
        status: .failed,
        turns: [
            GoalTurnRecord(
                turn: 1,
                sessionID: "session-interrupted",
                status: .failed,
                output: "",
                evaluation: GoalEvaluation(satisfied: false, reason: "background cancellation"),
                errorMessage: "CancellationError: background interruption"
            )
        ],
        lastReason: "background cancellation"
    )
    let failed = GoalSession(goalID: "failed", objective: "do not retry", status: .failed, lastReason: "logic error")

    let plan = planner.plan(for: [waiting, active, failed, interrupted])
    let decisions = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.goalID, $0.decision) })

    #expect(decisions["active"] == .resume)
    #expect(decisions["waiting"] == .keepWaiting)
    #expect(decisions["interrupted"] == .resume)
    #expect(decisions["failed"] == .skipFailed)
    #expect(plan.items.first { $0.goalID == "waiting" }?.hostAction?.kind == .provideSignal)
}

@Test
func goalContinuationPlannerResumesDueTimeWaitAfterRelaunch() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let dueWait = SessionWaitState.time(
        identifier: "timer",
        resumeAt: now.addingTimeInterval(-1),
        createdAt: now.addingTimeInterval(-60)
    )
    let futureWait = SessionWaitState.time(
        identifier: "future-timer",
        resumeAt: now.addingTimeInterval(60),
        createdAt: now.addingTimeInterval(-60)
    )
    let dueAction = dueWait.nativeAgentGoalHostAction(goalID: "due", sessionID: "session-due")
    let futureAction = futureWait.nativeAgentGoalHostAction(goalID: "future", sessionID: "session-future")
    let due = GoalSession(
        goalID: "due",
        objective: "continue when timer is due",
        status: .waiting,
        turns: [
            GoalTurnRecord(
                turn: 1,
                sessionID: "session-due",
                status: .waiting,
                output: "waiting for timer",
                evaluation: GoalEvaluation(satisfied: false, blocked: true, reason: "timer"),
                waitKind: .time,
                hostAction: dueAction
            )
        ]
    )
    let future = GoalSession(
        goalID: "future",
        objective: "continue later",
        status: .waiting,
        turns: [
            GoalTurnRecord(
                turn: 1,
                sessionID: "session-future",
                status: .waiting,
                output: "waiting for future timer",
                evaluation: GoalEvaluation(satisfied: false, blocked: true, reason: "timer"),
                waitKind: .time,
                hostAction: futureAction
            )
        ]
    )
    let planner = GoalContinuationPlanner(
        policy: GoalContinuationPolicy(resumeDueTimeWaits: true),
        now: { now }
    )

    let plan = planner.plan(for: [due, future])
    let decisions = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.goalID, $0.decision) })

    #expect(decisions["due"] == .resume)
    #expect(decisions["future"] == .keepWaiting)
}

@Test
func goalContinuationControllerResumesEligibleGoals() async throws {
    struct CompletingGoalRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: "resumed-session",
                status: .completed,
                output: "Resumed evidence checked.\nGOAL_EVIDENCE:\n- relaunch continuation verified\nGOAL_STATUS: complete\nGOAL_REASON: done"
            )
        }
    }

    let store = FileGoalSessionStore(rootURL: tempRoot())
    try await store.save(GoalSession(
        goalID: "resume-me",
        objective: "finish after relaunch",
        status: .budgetLimited,
        minScore: 0.2,
        minProgressDelta: 0.37
    ))
    try await store.save(GoalSession(goalID: "pause-me", objective: "remain paused", status: .paused))

    let loop = GoalLoop(
        store: store,
        runner: CompletingGoalRunner(),
        evaluator: HeuristicGoalEvaluator()
    )
    let controller = GoalContinuationController(
        store: store,
        loop: loop,
        planner: GoalContinuationPlanner(
            policy: GoalContinuationPolicy(
                resumeBudgetLimitedGoals: true,
                maxAutomaticResumes: 2,
                additionalTurnsPerResume: 1
            )
        )
    )

    let reports = try await controller.resumeEligible()

    #expect(reports.count == 1)
    #expect(reports.first?.session.goalID == "resume-me")
    #expect(reports.first?.status == .complete)
    #expect(reports.first?.session.minProgressDelta == 0.37)
    #expect(try await store.load(goalID: "resume-me")?.minProgressDelta == 0.37)
    #expect(try await store.load(goalID: "pause-me")?.status == .paused)
}

@Test
func goalContinuationControllerResumesDueTimeWaitBeforeRunningLoop() async throws {
    struct CompletingGoalRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: request.agentSessionID ?? "resumed-time-session",
                status: .completed,
                output: """
                Due time wait resumed.
                GOAL_EVIDENCE:
                - due time wait was resumed before goal loop execution
                GOAL_STATUS: complete
                GOAL_REASON: done
                """
            )
        }
    }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let waitState = SessionWaitState.time(
        identifier: "due-timer",
        resumeAt: now.addingTimeInterval(-10),
        createdAt: now.addingTimeInterval(-60)
    )
    let action = waitState.nativeAgentGoalHostAction(goalID: "due-time", sessionID: "due-agent")
    let waitingRecord = GoalTurnRecord(
        turn: 1,
        sessionID: "due-agent",
        status: .waiting,
        output: "waiting for due time",
        evaluation: GoalEvaluation(satisfied: false, blocked: true, score: 0.2, reason: "waiting", nextInstruction: "resume after time", evaluator: "test"),
        waitKind: .time,
        hostAction: action
    )
    let store = FileGoalSessionStore(rootURL: tempRoot())
    try await store.save(GoalSession(
        goalID: "due-time",
        objective: "complete after due time",
        successCondition: "due wait resumed",
        status: .waiting,
        maxTurns: 3,
        minScore: 0.1,
        turns: [waitingRecord]
    ))

    let loop = GoalLoop(store: store, runner: CompletingGoalRunner(), evaluator: HeuristicGoalEvaluator())
    let controller = GoalContinuationController(
        store: store,
        loop: loop,
        planner: GoalContinuationPlanner(
            policy: GoalContinuationPolicy(maxAutomaticResumes: 1, additionalTurnsPerResume: 1),
            now: { now }
        )
    )

    let reports = try await controller.resumeEligible()

    #expect(reports.count == 1)
    #expect(reports[0].status == .complete)
    #expect(reports[0].pendingHostAction == nil)
    #expect(try await store.load(goalID: "due-time")?.status == .complete)
}

@Test
func completedGoalDoesNotExposeStaleHostActionAfterWaitResume() async throws {
    struct CompletingGoalRunner: GoalTurnRunner {
        func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
            GoalRunResult(
                sessionID: request.agentSessionID ?? "stale-host-action-session",
                status: .completed,
                output: """
                Resumed and completed.
                GOAL_EVIDENCE:
                - resumed wait completed without pending host action
                GOAL_STATUS: complete
                GOAL_REASON: done
                """
            )
        }
    }

    let waitState = SessionWaitState.signal(identifier: "continue-goal")
    let action = waitState.nativeAgentGoalHostAction(goalID: "stale-action", sessionID: "agent-stale")
    let waitingRecord = GoalTurnRecord(
        turn: 1,
        sessionID: "agent-stale",
        status: .waiting,
        output: "waiting for host signal",
        evaluation: GoalEvaluation(satisfied: false, blocked: true, score: 0.2, reason: "waiting", nextInstruction: "resume after signal", evaluator: "test"),
        waitKind: .signal,
        hostAction: action
    )
    let store = FileGoalSessionStore(rootURL: tempRoot())
    try await store.save(GoalSession(
        goalID: "stale-action",
        objective: "complete after signal",
        successCondition: "completed after signal",
        status: .waiting,
        maxTurns: 3,
        minScore: 0.1,
        turns: [waitingRecord]
    ))
    try await store.resume(goalID: "stale-action")

    let loop = GoalLoop(store: store, runner: CompletingGoalRunner(), evaluator: HeuristicGoalEvaluator())
    let report = try await loop.run(GoalRunRequest(
        goalID: "stale-action",
        objective: "complete after signal",
        successCondition: "completed after signal",
        maxTurns: 1,
        minScore: 0.1,
        resumeExisting: true
    ))

    #expect(report.status == .complete)
    #expect(report.pendingHostAction == nil)
    #expect(report.session.pendingHostAction == nil)
}
