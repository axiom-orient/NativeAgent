import Foundation
import NativeAgentDomain

public protocol GoalTurnRunner: Sendable {
    func run(_ request: GoalTurnRequest) async throws -> GoalRunResult
}

public struct GoalTurnPlanner: Sendable {
    public init() {}

    public func makeTurnRequest(session: GoalSession) throws -> GoalTurnRequest {
        guard !session.objective.trimmedForNativeAgentGoal.isEmpty else { throw GoalError.missingObjective }
        let turn = session.nextTurn
        return GoalTurnRequest(
            goalID: session.goalID,
            turn: turn,
            input: prompt(session: session, turn: turn),
            objective: session.objective,
            successCondition: session.successCondition,
            agentSessionID: session.agentSessionID
        )
    }

    private func prompt(session: GoalSession, turn: Int) -> String {
        let condition = session.successCondition.isEmpty ? session.objective : session.successCondition
        let previousOutput = session.turns.last?.output ?? ""
        let previousBlock = previousOutput.trimmedForNativeAgentGoal.isEmpty ? "(none)" : previousOutput
        return """
        Work on this task now. Use only host-exposed tools and respect permissions, approvals, and sandbox boundaries.
        Verify the result. Never claim completion without concrete evidence; report a blocker if you cannot proceed.
        Keep your answer brief.

        Previous result: \(previousBlock)
        Previous evaluation: \(session.lastReason.isEmpty ? "(none)" : session.lastReason)
        Next instruction: \(session.latestInstruction.isEmpty ? "Perform the task." : session.latestInstruction)
        Turn: \(turn) of \(session.maxTurns)

        Task: \(session.objective)
        Success condition: \(condition)

        Report your actual findings after the label GOAL_EVIDENCE:.
        Then write GOAL_STATUS: and one word: complete, continue, or blocked.
        Finally write GOAL_REASON: and explain your status briefly.
        """
    }
}

public struct GoalLoop: Sendable {
    private enum PersistenceOutcome: Sendable {
        case saved(GoalSession)
        case conflicted(GoalSession)
    }

    private let store: any GoalSessionStore
    private let runner: any GoalTurnRunner
    private let evaluator: any GoalEvaluator
    private let planner: GoalTurnPlanner
    private let executionClaimStore: any GoalExecutionClaimStore
    private let executionState: GoalExecutionState

    public init(
        store: any GoalSessionStore,
        runner: any GoalTurnRunner,
        evaluator: any GoalEvaluator = HeuristicGoalEvaluator(),
        planner: GoalTurnPlanner = GoalTurnPlanner(),
        executionClaimStore: (any GoalExecutionClaimStore)? = nil
    ) {
        self.store = store
        self.runner = runner
        self.evaluator = evaluator
        self.planner = planner
        self.executionClaimStore = executionClaimStore
            ?? (store as? any GoalExecutionClaimStore)
            ?? InMemoryGoalExecutionClaimStore()
        self.executionState = GoalExecutionState()
    }

    public func run(_ request: GoalRunRequest) async throws -> GoalReport {
        try await withGoalExecution(goalID: request.goalID) {
            try await runWithClaim(request)
        }
    }

    /// Retries a claim release that previously failed after a goal operation.
    /// The claim-store contract requires failed release to retain ownership.
    @discardableResult
    public func retryPendingExecutionClaimRelease(goalID: String) async throws -> Bool {
        let clean = GoalPath.sanitized(goalID)
        guard let claim = await executionState.unreleasedClaim(goalID: clean) else {
            return false
        }
        try await executionClaimStore.releaseGoalExecutionClaim(claim)
        await executionState.clearUnreleased(goalID: clean)
        return true
    }

    private func runWithClaim(_ request: GoalRunRequest) async throws -> GoalReport {
        var session = try await startingSession(request)
        if shouldReturnWithoutRunning(session) {
            return report(for: session)
        }

        while session.status == .active && session.turns.count < session.maxTurns {
            try Task.checkCancellation()
            if let latest = try await store.load(goalID: session.goalID), latest != session {
                return report(for: latest)
            }

            let turnRequest = try planner.makeTurnRequest(session: session)
            let record: GoalTurnRecord
            do {
                let result = try await runner.run(turnRequest)
                try Task.checkCancellation()
                try result.validateState()
                let evaluation = try await evaluator.evaluate(session: session, result: result)
                try Task.checkCancellation()
                record = GoalTurnRecord(
                    turn: turnRequest.turn,
                    sessionID: result.sessionID,
                    status: result.status,
                    output: result.output,
                    evaluation: evaluation,
                    errorMessage: result.errorMessage,
                    waitKind: result.waitState?.kind,
                    hostAction: result.waitState?.nativeAgentGoalHostAction(
                        goalID: session.goalID,
                        sessionID: result.sessionID
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                record = GoalTurnRecord(
                    turn: turnRequest.turn,
                    sessionID: turnRequest.agentSessionID ?? "",
                    status: .failed,
                    output: "",
                    evaluation: GoalEvaluation(
                        satisfied: false,
                        blocked: false,
                        score: 0,
                        reason: error.localizedDescription,
                        nextInstruction: "Recover from the failure if possible, otherwise report the blocker.",
                        evaluator: "failure"
                    ),
                    errorMessage: error.localizedDescription,
                    waitKind: nil
                )
            }

            try Task.checkCancellation()
            let reduction = try GoalReducer.reduce(.recordTurn(record), state: session)
            switch try await persist(reduction, replacing: session) {
            case .saved(let saved):
                session = saved
            case .conflicted(let latest):
                return report(for: latest)
            }
        }

        if session.status == .active {
            try Task.checkCancellation()
            let reduction = try GoalReducer.reduce(.exhaustTurnBudget, state: session)
            switch try await persist(reduction, replacing: session) {
            case .saved(let saved):
                session = saved
            case .conflicted(let latest):
                return report(for: latest)
            }
        }
        return report(for: session)
    }

    private func shouldReturnWithoutRunning(_ session: GoalSession) -> Bool {
        session.status != .active
    }

    private func startingSession(_ request: GoalRunRequest) async throws -> GoalSession {
        guard request.objective.trimmedForNativeAgentGoal.isEmpty == false else {
            throw GoalError.missingObjective
        }

        let existing = try await store.load(goalID: request.goalID)
        if request.resumeExisting, let existing {
            guard existing.objective == request.objective,
                  existing.successCondition == request.successCondition else {
                throw GoalError.goalDefinitionMismatch(existing.goalID)
            }

            if existing.status == .budgetLimited || existing.status == .blocked || existing.status == .failed {
                let reduction = try GoalReducer.reduce(
                    .resumeRun(
                        maxAdditionalTurns: request.maxTurns,
                        minScore: request.minScore,
                        maxStaleTurns: request.maxStaleTurns,
                        minProgressDelta: request.minProgressDelta
                    ),
                    state: existing
                )
                switch try await persist(reduction, replacing: existing) {
                case .saved(let saved), .conflicted(let saved):
                    return saved
                }
            }
            return existing
        }

        let session = GoalSession(
            goalID: request.goalID,
            objective: request.objective,
            successCondition: request.successCondition,
            status: .active,
            maxTurns: request.maxTurns,
            minScore: request.minScore,
            maxStaleTurns: request.maxStaleTurns,
            minProgressDelta: request.minProgressDelta
        )
        try GoalReducer.validate(session)

        if let atomicStore = store as? any GoalAtomicSessionStore {
            guard try await atomicStore.save(session, replacing: existing) else {
                guard let latest = try await store.load(goalID: session.goalID) else {
                    throw GoalError.storeFailure(
                        "goal \"\(session.goalID)\" changed while a new run was being created"
                    )
                }
                return latest
            }
        } else {
            if let latest = try await store.load(goalID: session.goalID), latest != existing {
                return latest
            }
            try await store.save(session)
        }
        return session
    }

    private func persist(
        _ reduction: GoalReduction,
        replacing expected: GoalSession
    ) async throws -> PersistenceOutcome {
        guard reduction.effects.isEmpty == false else {
            return .saved(reduction.session)
        }

        if let atomicStore = store as? any GoalAtomicSessionStore {
            if try await atomicStore.save(reduction.session, replacing: expected) {
                return .saved(reduction.session)
            }
        } else {
            if let latest = try await store.load(goalID: expected.goalID), latest == expected {
                try await store.save(reduction.session)
                return .saved(reduction.session)
            }
        }

        guard let latest = try await store.load(goalID: expected.goalID) else {
            throw GoalError.storeFailure(
                "goal \"\(expected.goalID)\" disappeared during an atomic transition"
            )
        }
        return .conflicted(latest)
    }

    private func report(for session: GoalSession) -> GoalReport {
        GoalReport(
            session: session,
            storePath: store.path(goalID: session.goalID)
        )
    }

    private func withGoalExecution<T: Sendable>(
        goalID: String,
        operation: () async throws -> T
    ) async throws -> T {
        let clean = GoalPath.sanitized(goalID)
        try await executionState.begin(goalID: clean)

        let claim: GoalExecutionClaim
        do {
            claim = try await executionClaimStore.acquireGoalExecutionClaim(goalID: clean)
        } catch {
            await executionState.end(goalID: clean)
            throw error
        }

        let result: Result<T, any Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }

        do {
            try await executionClaimStore.releaseGoalExecutionClaim(claim)
            await executionState.clearUnreleased(goalID: clean)
        } catch {
            await executionState.retainUnreleased(claim)
            await executionState.end(goalID: clean)
            throw GoalError.storeFailure(
                "failed to release goal execution claim for \"\(clean)\": \(error.localizedDescription); " +
                "operation result: \(result.failureDescription)"
            )
        }

        await executionState.end(goalID: clean)
        return try result.get()
    }
}

private extension Result where Failure == any Error {
    var failureDescription: String {
        switch self {
        case .success:
            "none"
        case .failure(let error):
            error.localizedDescription
        }
    }
}
