import Foundation
import NativeAgentDomain

/// Owns the only production path from a tool artifact request to durable storage.
/// Tool executors return data; the runtime validates and persists it before the
/// resulting records are attached to the session snapshot.
struct AgentLoopToolResultHandler: Sendable {
    let store: any SessionRuntimePersistence
    let transitions: AgentLoopSnapshotTransitions
    let resourceValidator: RuntimeResourceValidator
    let now: @Sendable () -> Date

    func applySuccessfulResult(
        _ result: ToolResult,
        for call: ToolCall,
        definition: ToolDefinition,
        to snapshot: SessionSnapshot,
        resumingFailedSession: Bool = false
    ) async throws -> SessionReduction {
        guard result.callID == call.id, result.toolName == call.name else {
            throw AgentError.invariantViolation(
                "Tool result identity does not match invocation \(call.id)/\(call.name)."
            )
        }
        try resourceValidator.validate(result: result)

        var persistedArtifacts: [ArtifactRecord] = []
        persistedArtifacts.reserveCapacity(result.artifacts.count)

        do {
            for request in result.artifacts {
                try resourceValidator.validate(artifact: request)
                let artifact = try await store.persistArtifact(
                    sessionID: snapshot.sessionID,
                    artifact: request,
                    createdAt: now()
                )
                persistedArtifacts.append(artifact)
            }

            return try transitions.appendingToolResult(
                result,
                definition: definition,
                persistedArtifacts: persistedArtifacts,
                resumingFailedSession: resumingFailedSession,
                to: snapshot
            )
        } catch {
            try await discardUnreferencedArtifacts(
                persistedArtifacts,
                after: error
            )
        }
    }

    func discardUnreferencedArtifacts(
        _ artifacts: [ArtifactRecord],
        after primaryError: any Error
    ) async throws -> Never {
        do {
            for artifact in artifacts.reversed() {
                try await store.discardUnreferencedArtifact(artifact)
            }
        } catch {
            throw AgentError.persistenceFailure(
                "Artifact persistence failed [\(primaryError.localizedDescription)] " +
                "and cleanup also failed [\(error.localizedDescription)]."
            )
        }
        throw primaryError
    }
}
