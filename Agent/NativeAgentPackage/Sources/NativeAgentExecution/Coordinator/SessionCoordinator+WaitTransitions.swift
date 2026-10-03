import Foundation
import NativeAgentDomain

extension SessionCoordinator {
    func enterWait(
        _ waitState: SessionWaitState,
        snapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        let reduction = try SessionSnapshotTransitions.enteringWait(
            waitState,
            in: snapshot,
            timestamp: now()
        )
        return try await snapshotWriter.persist(
            reduction,
            journalEntries: [.waitEntered(waitState)]
        )
    }

    func clearWait(_ snapshot: SessionSnapshot) async throws -> SessionSnapshot {
        let priorWaitState = snapshot.waitState
        let reduction = try SessionSnapshotTransitions.clearingWait(
            snapshot,
            timestamp: now()
        )
        return try await snapshotWriter.persist(
            reduction,
            journalEntries: [.waitCleared(priorWaitState)]
        )
    }

    func resumeWaitedSession(
        from snapshot: SessionSnapshot,
        signal: SessionSignal? = nil,
        userPrompt: String?,
        requestMetadata: [String: JSONValue],
        responseContinuation: ResponseContinuationPolicy?
    ) async throws -> SessionSnapshot {
        let resolutionTimestamp: Date
        let journalEntries: [SessionJournal.Entry]
        if let signal {
            resolutionTimestamp = signal.receivedAt
            journalEntries = [.signalReceived(signal)]
        } else {
            resolutionTimestamp = now()
            journalEntries = [.waitCleared(snapshot.waitState)]
        }
        let resolutionReduction = try SessionSnapshotTransitions.resolvingWait(
            snapshot,
            signal: signal,
            responseContinuation: responseContinuation,
            timestamp: resolutionTimestamp
        )
        let resumedSnapshot = try await snapshotWriter.persist(
            resolutionReduction,
            journalEntries: journalEntries
        )

        guard let userPrompt, userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return try await advanceLoadedSnapshot(resumedSnapshot)
        }

        try resourceValidator.validateUserPrompt(userPrompt)
        let promptReduction = try SessionSnapshotTransitions.appendingUserPrompt(
            userPrompt,
            requestMetadata: requestMetadata,
            to: resumedSnapshot,
            messageID: idGenerator(),
            timestamp: now()
        )
        let persistedSnapshot = try await snapshotWriter.persist(promptReduction)
        return try await advanceLoadedSnapshot(persistedSnapshot)
    }
}
