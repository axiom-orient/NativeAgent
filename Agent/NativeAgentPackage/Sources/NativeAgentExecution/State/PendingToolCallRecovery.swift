import Foundation
import NativeAgentDomain

struct PendingToolCallRecovery: Sendable {
    let toolProcessor: AgentLoopToolProcessor

    func recoverPendingToolCalls(
        in snapshot: SessionSnapshot,
        context: ToolExecutionContext
    ) async throws -> SessionSnapshot {
        let calls = try PendingToolCallIndex.calls(in: snapshot)
        guard calls.isEmpty == false else {
            return snapshot
        }

        var updatedSnapshot = snapshot
        for call in calls {
            updatedSnapshot = try await toolProcessor.process(
                call,
                snapshot: updatedSnapshot,
                context: context
            )
        }
        return updatedSnapshot
    }

}
