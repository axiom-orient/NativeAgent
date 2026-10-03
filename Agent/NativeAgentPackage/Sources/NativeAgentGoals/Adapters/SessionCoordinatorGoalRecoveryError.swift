import Foundation

/// Preserves both failures when a goal turn fails and the persisted session
/// cannot be loaded to recover the latest durable state.
struct SessionCoordinatorGoalRecoveryError: Error, LocalizedError, Sendable, Equatable {
    let sessionID: String
    let runFailure: String
    let recoveryFailure: String

    var errorDescription: String? {
        "Goal session \(sessionID) failed to advance (\(runFailure)); " +
        "loading its durable recovery snapshot also failed (\(recoveryFailure))."
    }
}
