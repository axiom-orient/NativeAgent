import NativeAgentDomain
import Foundation

/// Semantic reason for the persistence effect emitted by the pure goal reducer.
package enum GoalMutationReason: String, Sendable, Equatable {
    case turnRecorded = "turn_recorded"
    case statusChanged = "status_changed"
    case runResumed = "run_resumed"
    case turnBudgetExhausted = "turn_budget_exhausted"
}

/// Explicit input to the durable goal state machine.
package enum GoalAction: Sendable {
    case recordTurn(GoalTurnRecord)
    case setStatus(GoalStatus)
    case resumeRun(
        maxAdditionalTurns: Int,
        minScore: Double,
        maxStaleTurns: Int,
        minProgressDelta: Double
    )
    case exhaustTurnBudget
}

/// Work that must occur outside the pure reducer.
package enum GoalEffect: Sendable, Equatable {
    case persist(GoalMutationReason)
}

package struct GoalReduction: Sendable, Equatable {
    package let session: GoalSession
    package let effects: [GoalEffect]
}

/// Pure, deterministic transition function for the goal lifecycle.
package enum GoalReducer {
    package static func reduce(
        _ action: GoalAction,
        state current: GoalSession
    ) throws -> GoalReduction {
        try validate(current)

        let reduced: GoalSession
        let reason: GoalMutationReason?

        switch action {
        case .recordTurn(let record):
            try require(current.status == .active, current, "turn recording requires an active goal")
            try require(current.turns.count < current.maxTurns, current, "turn budget is already exhausted")
            try require(record.turn == current.nextTurn, current, "turn number must be \(current.nextTurn), got \(record.turn)")
            try validate(record, in: current)

            let recorded = current.applying(.appended(record))
            reduced = recorded.applying(.statusChanged(nextStatus(after: record, in: recorded)))
            reason = .turnRecorded

        case .setStatus(let status):
            try validateTransition(from: current.status, to: status)
            if status == current.status {
                reduced = current
                reason = nil
            } else {
                reduced = current.applying(.statusChanged(status))
                reason = .statusChanged
            }

        case let .resumeRun(maxAdditionalTurns, minScore, maxStaleTurns, minProgressDelta):
            try require(
                current.status == .budgetLimited || current.status == .blocked || current.status == .failed,
                current,
                "automatic run resume requires a budget-limited, blocked, or failed goal"
            )
            try require(
                (1...GoalResourceLimits.maximumTurns).contains(maxAdditionalTurns),
                current,
                "additional turn budget must be between 1 and \(GoalResourceLimits.maximumTurns)"
            )
            try require(
                current.turns.count <= GoalResourceLimits.maximumTurns - maxAdditionalTurns,
                current,
                "resumed turn budget exceeds \(GoalResourceLimits.maximumTurns)"
            )
            reduced = current.applying(.resumed(
                maxAdditionalTurns: maxAdditionalTurns,
                minScore: minScore,
                maxStaleTurns: maxStaleTurns,
                minProgressDelta: minProgressDelta
            ))
            reason = .runResumed

        case .exhaustTurnBudget:
            try require(current.status == .active, current, "budget exhaustion requires an active goal")
            try require(
                current.turns.count >= current.maxTurns,
                current,
                "budget cannot be exhausted before maxTurns is reached"
            )
            reduced = current.applying(.turnBudgetExhausted)
            reason = .turnBudgetExhausted
        }

        try validate(reduced)
        return GoalReduction(
            session: reduced,
            effects: reason.map { [.persist($0)] } ?? []
        )
    }

    package static func validate(_ session: GoalSession) throws {
        guard session.goalID == GoalPath.sanitized(session.goalID) else {
            throw GoalError.storeFailure("goal id is not canonical: \(session.goalID)")
        }
        guard session.objective.trimmedForNativeAgentGoal.isEmpty == false else {
            throw GoalError.missingObjective
        }
        guard (1...GoalResourceLimits.maximumTurns).contains(session.maxTurns),
              (1...GoalResourceLimits.maximumTurns).contains(session.maxStaleTurns),
              session.minScore.isFinite,
              (0...1).contains(session.minScore),
              session.minProgressDelta.isFinite,
              (0...1).contains(session.minProgressDelta) else {
            throw GoalError.storeFailure("goal \"\(session.goalID)\" contains invalid limits")
        }
        guard session.turns.count <= session.maxTurns else {
            throw GoalError.storeFailure(
                "goal \"\(session.goalID)\" contains \(session.turns.count) turns but maxTurns is \(session.maxTurns)"
            )
        }
        try requireUTF8(
            session.goalID,
            maximum: GoalResourceLimits.maximumIdentifierUTF8Bytes,
            field: "goal id",
            session: session
        )
        try requireUTF8(
            session.objective,
            maximum: GoalResourceLimits.maximumObjectiveUTF8Bytes,
            field: "objective",
            session: session
        )
        try requireUTF8(
            session.successCondition,
            maximum: GoalResourceLimits.maximumSuccessConditionUTF8Bytes,
            field: "success condition",
            session: session
        )
        try requireUTF8(
            session.lastReason,
            maximum: GoalResourceLimits.maximumReasonUTF8Bytes,
            field: "last reason",
            session: session
        )

        for (index, record) in session.turns.enumerated() {
            let expectedTurn = index + 1
            guard record.turn == expectedTurn else {
                throw GoalError.storeFailure(
                    "goal \"\(session.goalID)\" has turn \(record.turn) at index \(index); expected \(expectedTurn)"
                )
            }
            try validate(record, in: session)
        }
    }

    package static func validateTransition(
        from current: GoalStatus,
        to next: GoalStatus
    ) throws {
        if current == next { return }
        switch (current, next) {
        case (_, .cleared),
             (.active, .paused),
             (.paused, .active),
             (.waiting, .active),
             (.budgetLimited, .active),
             (.blocked, .active),
             (.failed, .active),
             (.complete, .active):
            return
        default:
            throw GoalError.invalidStatusTransition(from: current, to: next)
        }
    }

    private static func validate(
        _ record: GoalTurnRecord,
        in session: GoalSession
    ) throws {
        guard record.turn >= 1 else {
            throw GoalError.storeFailure("goal \"\(session.goalID)\" contains a non-positive turn")
        }
        guard record.score.isFinite, (0...1).contains(record.score) else {
            throw GoalError.storeFailure(
                "goal \"\(session.goalID)\" turn \(record.turn) contains an invalid score"
            )
        }
        guard record.satisfied == false || record.blocked == false else {
            throw GoalError.storeFailure(
                "goal \"\(session.goalID)\" turn \(record.turn) cannot be both satisfied and blocked"
            )
        }
        try requireUTF8(
            record.sessionID,
            maximum: GoalResourceLimits.maximumIdentifierUTF8Bytes,
            field: "turn session id",
            session: session
        )
        try requireUTF8(
            record.output,
            maximum: GoalResourceLimits.maximumTurnOutputUTF8Bytes,
            field: "turn output",
            session: session
        )
        try requireUTF8(
            record.reason,
            maximum: GoalResourceLimits.maximumReasonUTF8Bytes,
            field: "turn reason",
            session: session
        )
        try requireUTF8(
            record.nextInstruction,
            maximum: GoalResourceLimits.maximumInstructionUTF8Bytes,
            field: "next instruction",
            session: session
        )
        if let errorMessage = record.errorMessage {
            try requireUTF8(
                errorMessage,
                maximum: GoalResourceLimits.maximumErrorUTF8Bytes,
                field: "turn error",
                session: session
            )
        }
        if record.status == .waiting, record.waitKind == nil {
            throw GoalError.storeFailure(
                "goal \"\(session.goalID)\" turn \(record.turn) is waiting without a wait kind"
            )
        }
        if record.status != .waiting, record.waitKind != nil {
            throw GoalError.storeFailure(
                "goal \"\(session.goalID)\" turn \(record.turn) has a wait kind while status is \(record.status.rawValue)"
            )
        }
    }

    private static func nextStatus(
        after record: GoalTurnRecord,
        in session: GoalSession
    ) -> GoalStatus {
        if record.satisfied { return .complete }
        if record.blocked { return record.status == .waiting ? .waiting : .blocked }
        if record.status == .waiting { return .waiting }
        if record.status == .failed && noProgress(in: session) { return .failed }
        if noProgress(in: session) { return .blocked }
        return .active
    }

    private static func noProgress(in session: GoalSession) -> Bool {
        let tail = session.turns.suffix(session.maxStaleTurns)
        guard tail.count >= session.maxStaleTurns else { return false }
        guard let first = tail.first?.score, let last = tail.last?.score else { return false }
        return last <= first + session.minProgressDelta && tail.allSatisfy { !$0.satisfied && !$0.blocked }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ session: GoalSession,
        _ message: String
    ) throws {
        guard condition() else {
            throw GoalError.storeFailure(
                "invalid goal transition for \"\(session.goalID)\" from \(session.status.rawValue): \(message)"
            )
        }
    }

    private static func requireUTF8(
        _ value: String,
        maximum: Int,
        field: String,
        session: GoalSession
    ) throws {
        guard value.utf8.count <= maximum else {
            throw GoalError.storeFailure(
                "goal \"\(session.goalID)\" \(field) exceeds \(maximum) UTF-8 bytes"
            )
        }
    }
}
