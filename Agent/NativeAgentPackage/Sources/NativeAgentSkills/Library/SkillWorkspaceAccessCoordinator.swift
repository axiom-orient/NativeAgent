import Foundation
import NativeAgentDomain

/// Process-local authority for mutable access to one skill workspace root.
///
/// Multiple `SkillLibrary` handles can legitimately point at the same workspace.
/// Serializing only inside each actor leaves their shared state and transaction
/// journal vulnerable to stale read/modify/write races. This coordinator keys the
/// existing pure access reducer by standardized workspace root so every handle in
/// the process observes one owner and one FIFO queue for that material state.
actor SkillWorkspaceAccessCoordinator {
    static let shared = SkillWorkspaceAccessCoordinator()

    private typealias Continuation =
        AsyncThrowingStream<SkillLibraryAccessClaim, any Error>.Continuation

    private var states: [String: SkillLibraryAccessState] = [:]
    private var waiters: [String: [UUID: Continuation]] = [:]

    func state(for rootKey: String) -> SkillLibraryAccessState {
        states[rootKey] ?? .idle
    }

    func acquire(
        rootKey: String,
        kind: SkillLibraryAccessKind
    ) async throws -> SkillLibraryAccessClaim {
        let claim = SkillLibraryAccessClaim(id: UUID(), kind: kind)
        let channel = AsyncThrowingStream<SkillLibraryAccessClaim, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let granted: SkillLibraryAccessClaim
        do {
            granted = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                waiters[rootKey, default: [:]][claim.id] = channel.continuation
                do {
                    try apply(.request(claim), rootKey: rootKey)
                } catch {
                    removeWaiter(claim.id, rootKey: rootKey)
                    channel.continuation.finish(throwing: error)
                    throw error
                }

                let granted = try await Self.waitForGrant(from: channel.stream)
                removeWaiter(claim.id, rootKey: rootKey)
                return granted
            } onCancel: {
                channel.continuation.finish(throwing: CancellationError())
            }
        } catch {
            let acquisitionFailure = error
            let cleanupError: (any Error)?
            do {
                try apply(.cancel(claim.id), rootKey: rootKey)
                removeWaiter(claim.id, rootKey: rootKey)
                cleanupError = nil
            } catch {
                removeWaiter(claim.id, rootKey: rootKey)
                cleanupError = error
            }
            return try SkillLibraryAccessCompletionPolicy().resolve(
                outcome: .failure(acquisitionFailure),
                releaseError: cleanupError
            )
        }

        do {
            try Task.checkCancellation()
            return granted
        } catch {
            let cancellationFailure = error
            let releaseError: (any Error)?
            do {
                try release(rootKey: rootKey, claim: granted)
                releaseError = nil
            } catch {
                releaseError = error
            }
            return try SkillLibraryAccessCompletionPolicy().resolve(
                outcome: .failure(cancellationFailure),
                releaseError: releaseError
            )
        }
    }

    func release(
        rootKey: String,
        claim: SkillLibraryAccessClaim
    ) throws {
        try apply(.release(claim.id), rootKey: rootKey)
        pruneIdleRoot(rootKey)
    }

    private nonisolated static func waitForGrant(
        from stream: AsyncThrowingStream<SkillLibraryAccessClaim, any Error>
    ) async throws -> SkillLibraryAccessClaim {
        var iterator = stream.makeAsyncIterator()
        guard let granted = try await iterator.next() else {
            throw CancellationError()
        }
        return granted
    }

    private func apply(
        _ action: SkillLibraryAccessAction,
        rootKey: String
    ) throws {
        let currentState = states[rootKey] ?? .idle
        let transition = try SkillLibraryAccessReducer().reduce(
            state: currentState,
            action: action
        )

        var deliveries: [(
            claimID: UUID,
            continuation: Continuation,
            result: Result<SkillLibraryAccessClaim, any Error>,
            removeAfterDelivery: Bool
        )] = []

        for effect in transition.effects {
            switch effect {
            case .suspend:
                break
            case .grant(let claim):
                guard let continuation = waiters[rootKey]?[claim.id] else {
                    throw AgentError.invariantViolation(
                        "Skill workspace access reducer granted a claim without a continuation"
                    )
                }
                deliveries.append((claim.id, continuation, .success(claim), false))
            case .cancel(let claimID):
                guard let continuation = waiters[rootKey]?[claimID] else {
                    throw AgentError.invariantViolation(
                        "Skill workspace access reducer cancelled a claim without a continuation"
                    )
                }
                deliveries.append((claimID, continuation, .failure(CancellationError()), true))
            }
        }

        states[rootKey] = transition.state
        for delivery in deliveries {
            if delivery.removeAfterDelivery {
                removeWaiter(delivery.claimID, rootKey: rootKey)
            }
            switch delivery.result {
            case .success(let claim):
                delivery.continuation.yield(claim)
                delivery.continuation.finish()
            case .failure(let error):
                delivery.continuation.finish(throwing: error)
            }
        }
        pruneIdleRoot(rootKey)
    }

    private func removeWaiter(_ claimID: UUID, rootKey: String) {
        waiters[rootKey]?.removeValue(forKey: claimID)
        if waiters[rootKey]?.isEmpty == true {
            waiters.removeValue(forKey: rootKey)
        }
        pruneIdleRoot(rootKey)
    }

    private func pruneIdleRoot(_ rootKey: String) {
        guard waiters[rootKey] == nil else { return }
        guard states[rootKey] == .idle else { return }
        states.removeValue(forKey: rootKey)
    }
}
