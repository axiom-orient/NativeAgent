import Foundation

public struct GoalContinuationController: Sendable {
    private let store: any GoalSessionListingStore
    private let loop: GoalLoop
    private let planner: GoalContinuationPlanner

    public init(
        store: any GoalSessionListingStore,
        loop: GoalLoop,
        planner: GoalContinuationPlanner = GoalContinuationPlanner()
    ) {
        self.store = store
        self.loop = loop
        self.planner = planner
    }

    public func plan() async throws -> GoalContinuationPlan {
        try await planner.plan(for: store.list())
    }

    public func resumeEligible() async throws -> [GoalReport] {
        let plan = try await plan()
        var reports: [GoalReport] = []
        for item in plan.resumableItems.prefix(plan.policy.maxAutomaticResumes) {
            let session = try await sessionForResume(item)
            let report = try await loop.run(
                GoalRunRequest(
                    goalID: session.goalID,
                    objective: session.objective,
                    successCondition: session.successCondition,
                    maxTurns: plan.policy.additionalTurnsPerResume,
                    minScore: session.minScore,
                    maxStaleTurns: session.maxStaleTurns,
                    minProgressDelta: session.minProgressDelta,
                    resumeExisting: true
                )
            )
            reports.append(report)
        }
        return reports
    }

    private func sessionForResume(_ item: GoalContinuationItem) async throws -> GoalSession {
        if item.status == .waiting, item.hostAction?.kind == .waitUntilTime {
            return try await store.resume(goalID: item.goalID)
        }
        return item.session
    }
}
