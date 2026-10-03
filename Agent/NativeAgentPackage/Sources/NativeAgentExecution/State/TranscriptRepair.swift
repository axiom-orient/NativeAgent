import Foundation
import NativeAgentDomain

struct TranscriptRepair: Sendable {
    static let interruptedToolMessage = "Tool execution was interrupted before producing a result."

    let transitions: AgentLoopSnapshotTransitions
    let registry: ToolRegistry

    func repairingInterruptedToolCallsAndFailing(
        in snapshot: SessionSnapshot,
        error: any Error
    ) throws -> SessionReduction {
        let resolvedCallIDs = Set(
            snapshot.messages
                .filter { $0.role == .tool }
                .compactMap(\.toolCallID)
        )

        var pendingCalls: [(id: String, name: String, definition: ToolDefinition?)] = []
        for message in snapshot.messages where message.role == .assistant {
            for call in message.toolCalls where resolvedCallIDs.contains(call.id) == false {
                pendingCalls.append((call.id, call.name, registry.definition(named: call.name)))
            }
        }

        return try transitions.markingFailed(
            snapshot,
            error: error,
            interruptedToolCalls: pendingCalls
        )
    }
}
