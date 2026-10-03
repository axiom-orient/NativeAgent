import NativeAgentDomain

/// Selects the durable failure transition after tool execution is interrupted.
///
/// A pending call with any durable mutating-effect receipt must remain pending:
/// - `started`/`failed` requires explicit host reconciliation.
/// - `completed` must be replayed from the ledger on continuation.
///
/// Calls without a durable effect receipt can be closed with an interrupted
/// tool result because the runtime has no evidence that an external mutation
/// crossed the effect boundary.
struct InterruptedToolExecutionRecovery: Sendable {
    let registry: ToolRegistry
    let effectLedger: ToolEffectLedger
    let transitions: AgentLoopSnapshotTransitions
    let transcriptRepair: TranscriptRepair

    func failureReduction(
        in snapshot: SessionSnapshot,
        error: any Error
    ) async throws -> SessionReduction {
        for call in try PendingToolCallIndex.calls(in: snapshot) {
            guard let definition = registry.definition(named: call.name),
                  definition.isReadOnly == false else {
                continue
            }
            if try await effectLedger.record(
                for: call,
                definition: definition,
                sessionID: snapshot.sessionID
            ) != nil {
                return try transitions.markingFailed(snapshot, error: error)
            }
        }

        return try transcriptRepair.repairingInterruptedToolCallsAndFailing(
            in: snapshot,
            error: error
        )
    }
}
