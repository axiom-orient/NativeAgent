import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
@testable import NativeAgentGoals
import NativeAgentTestSupport

func tempRoot(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
}

actor SuspendedGoalRunner: GoalTurnRunner {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<GoalRunResult, any Error>?

    func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard started == false else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish(with result: GoalRunResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

actor HostPauseAfterTurnStore: GoalSessionStore {
    private var session: GoalSession?

    func load(goalID: String) -> GoalSession? { session }

    func save(_ session: GoalSession) {
        self.session = session
        if session.status == .active, session.turns.count == 1 {
            self.session = session.applying(.statusChanged(.paused))
        }
    }

    nonisolated func path(goalID: String) -> String { "memory://\(goalID)" }

    func updateStatus(goalID: String, to status: GoalStatus) throws -> GoalSession {
        guard let session else { throw GoalError.goalNotFound(goalID) }
        let updated = session.applying(.statusChanged(status))
        self.session = updated
        return updated
    }
}
