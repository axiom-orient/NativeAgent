import Foundation
import NativeAgentDomain

/// Explicit process-local execution ownership for custom stores that do not
/// share durable session state with another process.
///
/// Share one instance between every coordinator that advances that custom
/// store. Application-support storage uses kernel-backed file claims by default.
public actor InMemorySessionExecutionClaimStore: SessionExecutionClaimStore {
    private var owners: [String: String] = [:]
    private let claimIDGenerator: @Sendable () -> String

    public init(
        claimIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.claimIDGenerator = claimIDGenerator
    }

    public func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        guard owners[sessionID] == nil else {
            throw AgentError.sessionBusy(sessionID)
        }

        let claim = SessionExecutionClaim(
            sessionID: sessionID,
            claimID: claimIDGenerator()
        )
        owners[sessionID] = claim.claimID
        return claim
    }

    public func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        guard owners[claim.sessionID] == claim.claimID else {
            throw AgentError.persistenceFailure(
                "Session execution claim is no longer owned: \(claim.sessionID)"
            )
        }
        owners.removeValue(forKey: claim.sessionID)
    }
}
