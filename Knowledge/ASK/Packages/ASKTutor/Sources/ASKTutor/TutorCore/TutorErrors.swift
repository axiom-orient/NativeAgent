import Foundation

public enum ASKTutorError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidInput(String)
    case storage(String)
    case model(String)
    case knowledge(String)
}


/// The requested batch is durably committed, but transaction housekeeping
/// could not be removed. Callers must treat the domain data as committed and
/// must not retry the mutation merely because this error was returned.
public struct TutorStorePostCommitError: Error, Equatable, Sendable, LocalizedError {
    public let transactionID: String
    public let cause: String

    public init(transactionID: String, cause: String) {
        self.transactionID = transactionID
        self.cause = cause
    }

    public var errorDescription: String? {
        "tutor store batch \(transactionID) committed, but transaction cleanup failed: \(cause)"
    }
}
