import LanguageModelCore
import Foundation

/// Durable, structured failure information attached to a failed session snapshot.
///
/// The runtime records this value before surfacing the original error so a host can
/// explain and recover the session after process restart without relying on logs.
public struct SessionFailure: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let occurredAt: Date
    public let details: [String: JSONValue]

    public init(
        code: String,
        message: String,
        occurredAt: Date = DeterministicCoreDefaults.timestamp,
        details: [String: JSONValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.occurredAt = occurredAt
        self.details = details
    }
}
