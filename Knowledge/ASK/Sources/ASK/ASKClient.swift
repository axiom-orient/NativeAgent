import ASKApplication
import Foundation
import KnowledgeRuntime

/// Public facade for ASK package workflows.
public struct ASKClient: Sendable {
    public let configuration: ASKConfiguration
    let application: ASKApplicationRuntime

    public init(configuration: ASKConfiguration) {
        self.configuration = configuration
        self.application = ASKApplicationRuntime()
    }

    /// Full capture input scope for host authorization; no mutation is performed.
    public static func captureStagingRoot(for inputURL: URL) throws -> URL {
        do { return try ASKRuntime.captureStagingRoot(for: inputURL) }
        catch { throw mapASKDiagnostic(error, operation: .plan) }
    }

    // MARK: Canonical typed boundary

    /// Creates a deterministic command plan without performing I/O.
    public func plan(_ command: ASKCommand) throws -> ASKCommandPlan {
        do {
            return try ASKCommandPlanner.makePlan(command, configuration: configuration)
        } catch {
            throw mapASKDiagnostic(error, operation: .plan)
        }
    }

    /// Verifies a command plan without applying effects.
    public func dryRun(_ plan: ASKCommandPlan) throws -> ASKDryRunResult {
        do {
            try ASKCommandPlanIntegrity.verify(plan, configuration: configuration)
            return ASKDryRunResult(actionID: plan.actionID, context: plan.context, summary: plan.summary)
        } catch {
            throw mapASKDiagnostic(error, operation: .dryRun)
        }
    }

    /// Applies a command plan through an explicit state transition and effect boundary.
    public func apply(_ plan: ASKCommandPlan) async throws -> ASKApplyOutcome {
        try await apply(plan, maintenanceLease: nil)
    }

    func apply(_ plan: ASKCommandPlan, maintenanceLease: ASKApplicationMutationLease?) async throws -> ASKApplyOutcome {
        var state = ASKCommandExecutionState.planned(plan)
        do {
            state = try ASKCommandExecutionReducer.reduce(
                state: state,
                event: .validate(configuration)
            ).state
            let transition = try ASKCommandExecutionReducer.reduce(state: state, event: .begin)
            state = transition.state
            guard case .execute(let validated) = transition.effect else {
                throw ASKDiagnostic(
                    code: .integrityViolation,
                    operation: .apply,
                    message: "Execution reducer did not produce an apply effect",
                    recovery: .inspectStorage
                )
            }
            let outcome = try await applyTypedValidated(validated, maintenanceLease: maintenanceLease)
            state = try ASKCommandExecutionReducer.reduce(state: state, event: .succeed(outcome)).state
            guard case .completed = state else {
                throw ASKDiagnostic(
                    code: .integrityViolation,
                    operation: .apply,
                    message: "Execution reducer did not reach a completed state",
                    recovery: .inspectStorage
                )
            }
            return outcome
        } catch {
            let operation: ASKOperation
            if case .repairPresentation = plan.command {
                operation = .repair
            } else {
                operation = .apply
            }
            let mapped = mapASKDiagnostic(error, operation: operation)
            var context = mapped.context
            context["actionID"] = plan.actionID
            context["replayPolicy"] = plan.command.replayPolicy.rawValue
            let diagnostic = ASKDiagnostic(code: mapped.code, operation: operation,
                message: mapped.message, context: context, recovery: mapped.recovery)
            state = (try? ASKCommandExecutionReducer.reduce(
                state: state,
                event: .fail(diagnostic)
            ).state) ?? ASKCommandExecutionReducer.failureState(from: state, diagnostic: diagnostic)
            throw diagnostic
        }
    }

    /// Executes a typed read query without creating missing workspaces.
    public func query(_ query: ASKQuery) async throws -> ASKQueryResult {
        do {
            try Task.checkCancellation()
            return try await queryValidated(query)
        } catch {
            throw mapASKDiagnostic(error, operation: .query)
        }
    }

}
