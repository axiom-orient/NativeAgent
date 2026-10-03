import Foundation
import NativeAgentDomain

extension AgentLoopToolProcessor {
    func appendToolErrorAndSave(
        callID: String,
        toolName: String,
        content: String,
        metadata: [String: JSONValue] = [:],
        definition: ToolDefinition? = nil,
        effects: [EffectRecord] = [],
        to snapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        try await RuntimeToolErrorAppender(writer: snapshotWriter, transitions: transitions)
            .append(
                callID: callID,
                toolName: toolName,
                content: content,
                metadata: metadata,
                definition: definition,
                effects: effects,
                to: snapshot
            )
    }
}
