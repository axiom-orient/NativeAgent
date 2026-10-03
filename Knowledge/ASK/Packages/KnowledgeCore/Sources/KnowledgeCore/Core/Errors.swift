
import Foundation

public enum ASKError: Error, Equatable, Sendable {
    case validation(String)
    case database(String)
    case notFound(String)
    case apply(String)
    case journalConflict(String)
    case importIntegrity(String)
    case platformUnavailable(String)
    case unimplemented(String)
}
