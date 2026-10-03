import LanguageModelCore
import Foundation

/// Opaque ownership token for exclusive advancement of one durable session.
public struct SessionExecutionClaim: Hashable, Sendable {
    public let sessionID: String
    public let claimID: String

    public init(sessionID: String, claimID: String) {
        self.sessionID = sessionID
        self.claimID = claimID
    }
}

/// External boundary that serializes session advancement across coordinator actors
/// that share the same claim store.
///
/// A cross-process implementation must bind ownership to process lifetime (for
/// example, an OS file lock) or recover abandoned ownership internally. Process
/// termination must never require the dead process's opaque claim token before a
/// later process can acquire the same session.
public protocol SessionExecutionClaimStore: Sendable {
    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim

    /// Releases ownership. If this operation throws, the claim must remain owned
    /// and the same token must be safe to retry.
    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws
}
