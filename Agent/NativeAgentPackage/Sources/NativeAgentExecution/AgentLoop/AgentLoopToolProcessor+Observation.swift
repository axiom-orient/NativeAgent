import Foundation
import NativeAgentDomain

extension AgentLoopToolProcessor {
    func recordEffectDecision(
        _ decision: ToolEffectDecisionKind,
        reason: String? = nil,
        call: ToolCall,
        definition: ToolDefinition,
        snapshot: SessionSnapshot
    ) async {
        await observer?.record(
            effectDecision: ToolEffectDecisionEvent(
                sessionID: snapshot.sessionID,
                callID: call.id,
                toolName: call.name,
                capabilityID: definition.capabilityID,
                decision: decision,
                reason: reason,
                createdAt: now()
            )
        )
    }
}
