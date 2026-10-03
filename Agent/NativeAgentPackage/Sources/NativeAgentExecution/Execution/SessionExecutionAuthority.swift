import Foundation
import NativeAgentDomain

/// In-process admission and claim-release owner shared by one AgentStorage.
///
/// Coordinators and provider-independent recovery use the same reservation. The
/// durable store still owns snapshots/revisions; the claim store owns cross-process
/// exclusion. This actor retains a failed release, never a second session snapshot.
package actor SessionExecutionAuthority {
    private enum Ownership {
        case executing
        case releasePending(SessionExecutionClaim)
    }

    private var ownershipBySessionID: [String: Ownership] = [:]

    package init() {}

    /// The operation keeps its caller's isolation. Only admission/completion access
    /// this actor, atomically, so no mutable assumption crosses an actor hop.
    func withExecution<T: Sendable>(
        sessionID: String,
        safety: SessionExecutionSafety,
        claimStore: (any SessionExecutionClaimStore)?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try await reserve(sessionID: sessionID)

        let claim: SessionExecutionClaim?
        do {
            try Task.checkCancellation()
            switch safety {
            case .coordinatorOnly:
                claim = nil
            case .sharedClaimRequired:
                guard let claimStore else {
                    throw AgentError.invalidConfiguration(
                        "RuntimeSafetyPolicy requires a shared SessionExecutionClaimStore."
                    )
                }
                claim = try await claimStore.acquireExecutionClaim(sessionID: sessionID)
            }
        } catch {
            await finish(sessionID: sessionID, pendingClaim: nil)
            throw error
        }

        let result: Result<T, any Error>
        do {
            try Task.checkCancellation()
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }

        if let claim, let claimStore {
            do {
                try await claimStore.releaseExecutionClaim(claim)
            } catch {
                // A failed release retains the exact token and blocks both normal
                // execution and reconciliation until an explicit retry succeeds.
                await finish(sessionID: sessionID, pendingClaim: claim)
                let operationFailure: String
                switch result {
                case .success: operationFailure = "none"
                case .failure(let error): operationFailure = error.localizedDescription
                }
                throw AgentError.persistenceFailure(
                    "Failed to release session execution claim for \(sessionID): \(error.localizedDescription). " +
                    "Operation result: \(operationFailure). The claim remains owned and can be retried."
                )
            }
        }
        await finish(sessionID: sessionID, pendingClaim: nil)
        return try result.get()
    }

    @discardableResult
    func retryPendingRelease(
        sessionID: String,
        claimStore: (any SessionExecutionClaimStore)?
    ) async throws -> Bool {
        let claim: SessionExecutionClaim
        switch ownershipBySessionID[sessionID] {
        case nil:
            return false
        case .executing:
            throw AgentError.sessionBusy(sessionID)
        case .releasePending(let pending):
            claim = pending
        }
        guard let claimStore else {
            throw AgentError.invalidConfiguration(
                "No SessionExecutionClaimStore is configured for pending claim recovery."
            )
        }
        // Reserve before release I/O. A second retry cannot release the same token
        // or race a newer execution while this call is suspended.
        ownershipBySessionID[sessionID] = .executing
        do {
            try await claimStore.releaseExecutionClaim(claim)
            finish(sessionID: sessionID, pendingClaim: nil)
            return true
        } catch {
            finish(sessionID: sessionID, pendingClaim: claim)
            throw error
        }
    }

    private func reserve(sessionID: String) throws {
        switch ownershipBySessionID[sessionID] {
        case nil:
            ownershipBySessionID[sessionID] = .executing
        case .executing:
            throw AgentError.sessionBusy(sessionID)
        case .releasePending:
            throw AgentError.persistenceFailure(
                "Session execution claim release is pending for \(sessionID). " +
                "Call retryPendingExecutionClaimRelease(sessionID:) before advancing the session."
            )
        }
    }

    private func finish(sessionID: String, pendingClaim: SessionExecutionClaim?) {
        if let pendingClaim {
            ownershipBySessionID[sessionID] = .releasePending(pendingClaim)
        } else {
            ownershipBySessionID.removeValue(forKey: sessionID)
        }
    }
}
