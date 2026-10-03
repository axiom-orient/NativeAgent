import LanguageModelCore
import Foundation

/// Durable external input used to resume a signal wait.
public struct SessionSignal: Codable, Sendable, Equatable {
    public let identifier: String
    public let payload: JSONValue
    public let receivedAt: Date

    public init(
        identifier: String,
        payload: JSONValue = .null,
        receivedAt: Date = DeterministicCoreDefaults.timestamp
    ) {
        self.identifier = identifier
        self.payload = payload
        self.receivedAt = receivedAt
    }
}
