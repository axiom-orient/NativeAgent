enum ASKCommandExecutionState: Equatable, Sendable {
    case planned(ASKCommandPlan)
    case validated(ASKCommandPlan)
    case applying(ASKCommandPlan)
    case completed(ASKApplyOutcome)
    case failed(actionID: String, diagnostic: ASKDiagnostic)
}

enum ASKCommandExecutionEvent: Equatable, Sendable {
    case validate(ASKConfiguration)
    case begin
    case succeed(ASKApplyOutcome)
    case fail(ASKDiagnostic)
}

enum ASKCommandExecutionEffect: Equatable, Sendable {
    case none
    case execute(ASKCommandPlan)
}

struct ASKCommandExecutionTransition: Equatable, Sendable {
    let state: ASKCommandExecutionState
    let effect: ASKCommandExecutionEffect
}

enum ASKCommandExecutionReducer {
    static func reduce(
        state: ASKCommandExecutionState,
        event: ASKCommandExecutionEvent
    ) throws -> ASKCommandExecutionTransition {
        switch (state, event) {
        case (.planned(let plan), .validate(let configuration)):
            try ASKCommandPlanIntegrity.verify(plan, configuration: configuration)
            return ASKCommandExecutionTransition(state: .validated(plan), effect: .none)
        case (.validated(let plan), .begin):
            return ASKCommandExecutionTransition(state: .applying(plan), effect: .execute(plan))
        case (.applying(let plan), .succeed(let outcome)):
            guard outcome.actionID == plan.actionID else {
                throw ASKDiagnostic(
                    code: .integrityViolation,
                    operation: .apply,
                    message: "Execution result integrity mismatch: actionID",
                    context: ["expected": plan.actionID, "actual": outcome.actionID],
                    recovery: .inspectStorage
                )
            }
            return ASKCommandExecutionTransition(state: .completed(outcome), effect: .none)
        case (_, .fail(let diagnostic)):
            return ASKCommandExecutionTransition(
                state: failureState(from: state, diagnostic: diagnostic),
                effect: .none
            )
        default:
            throw ASKDiagnostic(
                code: .conflict,
                operation: .apply,
                message: "Invalid execution transition: \(state.name) + \(event.name)",
                recovery: .correctInput
            )
        }
    }

    static func failureState(
        from state: ASKCommandExecutionState,
        diagnostic: ASKDiagnostic
    ) -> ASKCommandExecutionState {
        switch state {
        case .planned(let plan), .validated(let plan), .applying(let plan):
            .failed(actionID: plan.actionID, diagnostic: diagnostic)
        case .completed, .failed:
            state
        }
    }
}

private extension ASKCommandExecutionState {
    var name: String {
        switch self {
        case .planned: "planned"
        case .validated: "validated"
        case .applying: "applying"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

private extension ASKCommandExecutionEvent {
    var name: String {
        switch self {
        case .validate: "validate"
        case .begin: "begin"
        case .succeed: "succeed"
        case .fail: "fail"
        }
    }
}

private extension ASKApplyOutcome {
    var actionID: String {
        switch self {
        case .sourcesIndexed(let value): value.actionID
        case .workspaceApplied(let value): value.actionID
        case .staged(let value): value.actionID
        case .decided(let value): value.actionID
        case .presentationRepaired(let value): value.actionID
        case .knowledgeRebuilt(let value): value.actionID
        case .decisionMemory(let value): value.actionID
        case .committedWithRepairRequired(let value, _): value.actionID
        case .committedWithRecoveryRequired(let value): value.actionID
        }
    }
}

private extension ASKStagedPatchResult {
    var actionID: String {
        switch self {
        case .report(let value): value.actionID
        case .closeDay(let value): value.actionID
        case .capture(let value): value.actionID
        }
    }
}

private extension ASKCommittedValue {
    var actionID: String {
        switch self {
        case .workspace(let value): value.actionID
        case .decision(let value): value.actionID
        }
    }
}
