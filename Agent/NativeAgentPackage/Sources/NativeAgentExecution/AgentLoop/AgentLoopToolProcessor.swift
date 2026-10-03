import Foundation
import NativeAgentDomain

struct AgentLoopToolProcessor: Sendable {
    let approvalRouter: any ApprovalRouter
    let store: any SessionRuntimeStore
    let registry: ToolRegistry
    let validator: ToolCallValidator
    let transitions: AgentLoopSnapshotTransitions
    let toolResultHandler: AgentLoopToolResultHandler
    let snapshotWriter: RuntimeSnapshotWriter
    let effectLedger: ToolEffectLedger
    let approvalLedger: ApprovalEffectLedger
    let observer: (any RuntimeObserver)?
    let now: @Sendable () -> Date

    func process(
        _ call: ToolCall,
        snapshot: SessionSnapshot,
        context: ToolExecutionContext
    ) async throws -> SessionSnapshot {
        guard let definition = registry.definition(named: call.name),
              let executor = registry.executor(named: call.name) else {
            return try await appendToolErrorAndSave(
                callID: call.id,
                toolName: call.name,
                content: "Tool not found: \(call.name)",
                metadata: toolFailureMetadata(.unsupported),
                to: snapshot
            )
        }

        do {
            try validator.validate(call: call, against: definition)
        } catch {
            return try await appendToolErrorAndSave(
                callID: call.id,
                toolName: call.name,
                content: error.localizedDescription,
                metadata: toolFailureMetadata(.invalidInput),
                definition: definition,
                to: snapshot
            )
        }

        let approval = try await resolveApproval(
            definition: definition,
            call: call,
            snapshot: snapshot
        )
        let approvedSnapshot = approval.snapshot
        if let approvalError = approval.errorMessage {
            return try await appendToolErrorAndSave(
                callID: call.id,
                toolName: call.name,
                content: approvalError,
                metadata: toolFailureMetadata(.permissionDenied),
                definition: definition,
                to: approvedSnapshot
            )
        }

        switch try await effectLedger.decision(
            for: call,
            definition: definition,
            sessionID: approvedSnapshot.sessionID
        ) {
        case .execute:
            await recordEffectDecision(.execute, call: call, definition: definition, snapshot: approvedSnapshot)
        case .block(let code, let message):
            await recordEffectDecision(.block, reason: message, call: call, definition: definition, snapshot: approvedSnapshot)
            return try await appendToolErrorAndSave(
                callID: call.id,
                toolName: call.name,
                content: message,
                metadata: toolFailureMetadata(code),
                definition: definition,
                to: approvedSnapshot
            )
        case .replay(let message, let artifacts):
            await recordEffectDecision(.replay, reason: "completed effect replayed", call: call, definition: definition, snapshot: approvedSnapshot)
            let replayedReduction = try transitions.appendingReplayedToolResult(
                message: message,
                definition: definition,
                artifacts: artifacts,
                to: approvedSnapshot
            )
            let entries = replayedReduction.snapshot.messages.last.map {
                [SessionJournal.Entry.toolResult($0)]
            } ?? []
            return try await snapshotWriter.persist(
                replayedReduction,
                journalEntries: entries
            )
        }

        let startedRecord = try await effectLedger.markStarted(
            call: call,
            definition: definition,
            sessionID: approvedSnapshot.sessionID
        )

        let startedUptime = ProcessInfo.processInfo.systemUptime
        let updatedReduction: SessionReduction
        var executorReturned = false
        do {
            try Task.checkCancellation()
            let result = try await executor.execute(call: call, context: context)
            executorReturned = true
            // Cancellation stops future work, not observation of an effect that already returned.
            // Persist its result/artifacts/receipt before propagating the cancellation below.
            await observer?.record(
                toolExecutionDuration: ToolExecutionDurationEvent(
                    sessionID: approvedSnapshot.sessionID,
                    callID: call.id,
                    toolName: call.name,
                    capabilityID: definition.capabilityID,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - startedUptime,
                    succeeded: true,
                    createdAt: now()
                )
            )
            updatedReduction = try await toolResultHandler.applySuccessfulResult(
                result,
                for: call,
                definition: definition,
                to: approvedSnapshot
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failureCertainty = EffectFailureClassifier.certainty(for: error)
            let boundedError = RuntimeSessionFailure.boundedMessage(
                error.localizedDescription,
                maximumUTF8Bytes: transitions.maximumFailureMessageUTF8Bytes
            ).message

            // Once the executor has returned, the external effect may already exist.
            // Result validation/publication failure cannot prove that effect failed.
            if executorReturned {
                throw error
            }

            await observer?.record(
                toolExecutionDuration: ToolExecutionDurationEvent(
                    sessionID: approvedSnapshot.sessionID,
                    callID: call.id,
                    toolName: call.name,
                    capabilityID: definition.capabilityID,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - startedUptime,
                    succeeded: false,
                    createdAt: now()
                )
            )
            if startedRecord != nil, failureCertainty == .outcomeUnknown {
                throw error
            }
            let failedEffect = try await effectLedger.failedRecord(
                call: call,
                definition: definition,
                sessionID: approvedSnapshot.sessionID,
                error: boundedError,
                startedRecord: startedRecord
            )
            return try await appendToolErrorAndSave(
                callID: call.id,
                toolName: call.name,
                content: boundedError,
                metadata: toolFailureMetadata(for: error),
                definition: definition,
                effects: [failedEffect].compactMap { $0 },
                to: approvedSnapshot
            )
        }

        let updatedSnapshot = updatedReduction.snapshot
        let persistedArtifacts = Array(updatedSnapshot.artifacts.dropFirst(approvedSnapshot.artifacts.count))
        let committedSnapshot: SessionSnapshot
        do {
            var completedEffects: [EffectRecord] = []
            if let message = updatedSnapshot.messages.last {
                let completedEffect = try await effectLedger.completedRecord(
                    call: call,
                    definition: definition,
                    sessionID: updatedSnapshot.sessionID,
                    message: message,
                    artifacts: persistedArtifacts,
                    startedRecord: startedRecord
                )
                completedEffects = [completedEffect].compactMap { $0 }
            }

            let entries = updatedReduction.snapshot.messages.last.map {
                [SessionJournal.Entry.toolResult($0)]
            } ?? []
            committedSnapshot = try await snapshotWriter.persist(
                updatedReduction,
                effects: completedEffects,
                journalEntries: entries
            )
        } catch {
            try await toolResultHandler.discardUnreferencedArtifacts(
                persistedArtifacts,
                after: error
            )
        }
        // Keep this outside publication cleanup: these artifacts now have durable references.
        try Task.checkCancellation()
        return committedSnapshot
    }


    func reject(
        _ call: ToolCall,
        content: String,
        snapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        try await appendToolErrorAndSave(
            callID: call.id,
            toolName: call.name,
            content: content,
            metadata: toolFailureMetadata(.conflict),
            definition: registry.definition(named: call.name),
            to: snapshot
        )
    }
}
