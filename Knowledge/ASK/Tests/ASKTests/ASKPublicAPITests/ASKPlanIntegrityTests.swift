import Foundation
import XCTest
@testable import ASK

final class ASKExecutionReducerTests: XCTestCase {
    private let configuration = ASKConfiguration(
        workspaceURL: URL(fileURLWithPath: "/tmp/ask-plan-integrity", isDirectory: true)
    )

    func testExecutionReducerProducesEffectOnlyAfterValidation() throws {
        let client = ASKClient(configuration: configuration)
        let plan = try client.plan(.quickStart(ASKQuickStartCommand(requestedAt: "2026-04-20T10:00:00Z")))

        let validated = try ASKCommandExecutionReducer.reduce(state: .planned(plan), event: .validate(configuration))
        XCTAssertEqual(validated.state, .validated(plan))
        XCTAssertEqual(validated.effect, .none)

        let applying = try ASKCommandExecutionReducer.reduce(state: validated.state, event: .begin)
        XCTAssertEqual(applying.state, .applying(plan))
        XCTAssertEqual(applying.effect, .execute(plan))
    }

    func testExecutionReducerRejectsInvalidTransition() throws {
        let client = ASKClient(configuration: configuration)
        let plan = try client.plan(.quickStart(ASKQuickStartCommand(requestedAt: "2026-04-20T10:00:00Z")))

        XCTAssertThrowsError(try ASKCommandExecutionReducer.reduce(state: .planned(plan), event: .begin)) { error in
            XCTAssertEqual((error as? ASKDiagnostic)?.code, .conflict)
        }
    }

    func testExecutionReducerRejectsMismatchedResultActionID() throws {
        let client = ASKClient(configuration: configuration)
        let plan = try client.plan(.quickStart(ASKQuickStartCommand(requestedAt: "2026-04-20T10:00:00Z")))
        let outcome = ASKApplyOutcome.staged(.report(ASKReportStagedResult(
            actionID: "ask-other", patchID: "patch", projectionSlug: "projection", evidenceHitCount: 0
        )))

        XCTAssertThrowsError(try ASKCommandExecutionReducer.reduce(state: .applying(plan), event: .succeed(outcome))) { error in
            let diagnostic = error as? ASKDiagnostic
            XCTAssertEqual(diagnostic?.code, .integrityViolation)
            XCTAssertEqual(diagnostic?.context["expected"], plan.actionID)
        }
    }

    func testExecutionReducerRecordsFailureThroughFailureEvent() throws {
        let client = ASKClient(configuration: configuration)
        let plan = try client.plan(.quickStart(ASKQuickStartCommand(requestedAt: "2026-04-20T10:00:00Z")))
        let diagnostic = ASKDiagnostic(code: .conflict, operation: .apply, message: "failed", recovery: .retry)

        let transition = try ASKCommandExecutionReducer.reduce(state: .applying(plan), event: .fail(diagnostic))
        XCTAssertEqual(transition.state, .failed(actionID: plan.actionID, diagnostic: diagnostic))
        XCTAssertEqual(transition.effect, .none)
    }
}
